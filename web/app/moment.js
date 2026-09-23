// MOMENT Web — a client of the same decentralised protocol the iPhone app speaks.
// Identity is an Ed25519 key in this browser. Everything you do is a signed event sent to relays
// you choose; nothing here talks to a MOMENT server, because there isn't one.
// Crypto: tweetnacl (Ed25519) + WebCrypto (SHA-256, AES-GCM, X25519 where available).

const enc = new TextEncoder(), dec = new TextDecoder();
const b64 = { enc: (u8) => btoa(String.fromCharCode(...u8)), dec: (s) => Uint8Array.from(atob(s), c => c.charCodeAt(0)) };
const hex = (u8) => [...u8].map(b => b.toString(16).padStart(2, '0')).join('');
const sha256 = async (u8) => new Uint8Array(await crypto.subtle.digest('SHA-256', u8));

// ---- Identity -------------------------------------------------------------
export const Identity = {
  key: null,
  async load() {
    let seed = localStorage.getItem('moment.identity.seed');
    if (!seed) { const s = nacl.randomBytes(32); seed = b64.enc(s); localStorage.setItem('moment.identity.seed', seed); }
    this.key = nacl.sign.keyPair.fromSeed(b64.dec(seed));
    let agree = localStorage.getItem('moment.identity.agree');
    if (!agree) { const k = nacl.box.keyPair(); agree = b64.enc(k.secretKey); localStorage.setItem('moment.identity.agree', agree); }
    this.agree = nacl.box.keyPair.fromSecretKey(b64.dec(agree));
    return this;
  },
  get author() { return b64.enc(this.key.publicKey); },
  get agreePK() { return b64.enc(this.agree.publicKey); },
  /// Same fingerprint the app shows: SHA-256 of the raw public key, first 8 bytes, base32 (no 0/O/1/I), MMT-XXXX-XXXX-XXXX.
  async momentID() {
    const d = await sha256(this.key.publicKey);
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    let bits = 0, acc = 0, out = '';
    for (const b of d.slice(0, 8)) { acc = ((acc << 8) | b) >>> 0; bits += 8; while (bits >= 5) { bits -= 5; out += alphabet[(acc >>> bits) & 31]; } }
    const s = out.slice(0, 12);
    return 'MMT-' + [s.slice(0, 4), s.slice(4, 8), s.slice(8, 12)].join('-');
  },
  exportSeed() { return localStorage.getItem('moment.identity.seed'); },
  importSeed(seed) { localStorage.setItem('moment.identity.seed', seed); return this.load(); }
};

// ---- Signed events (byte-identical canonical form to the app) --------------
export const Events = {
  canonical(kind, author, createdAt, tags, content) {
    const t = Object.keys(tags).sort().map(k => `${k}=${tags[k]}`).join('&');
    return enc.encode(`v1|${kind}|${author}|${Math.floor(createdAt)}|${t}|${content}`);
  },
  async make(kind, tags, content) {
    const createdAt = Math.floor(Date.now() / 1000);
    const author = Identity.author;
    const canon = this.canonical(kind, author, createdAt, tags, content);
    const id = hex(await sha256(canon));
    const sig = b64.enc(nacl.sign.detached(canon, Identity.key.secretKey));
    return { id, kind, author, createdAt, tags, content, sig };
  },
  async verify(e) {
    try {
      const canon = this.canonical(e.kind, e.author, e.createdAt, e.tags || {}, e.content);
      if (hex(await sha256(canon)) !== e.id) return false;
      return nacl.sign.detached.verify(canon, b64.dec(e.sig), b64.dec(e.author));
    } catch { return false; }
  },
  payload(e) { try { return JSON.parse(e.content); } catch { return null; } }
};

// ---- Per-Moment keys (AES-GCM, CryptoKit "combined" = nonce(12) | ciphertext | tag(16)) ----
export const Keys = {
  async importRaw(b64key) { return crypto.subtle.importKey('raw', b64.dec(b64key), 'AES-GCM', true, ['encrypt', 'decrypt']); },
  async open(key, combinedB64) {
    const all = b64.dec(combinedB64); const iv = all.slice(0, 12), body = all.slice(12);
    return dec.decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, body));
  },
  async seal(key, text) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(text)));
    const out = new Uint8Array(12 + ct.length); out.set(iv); out.set(ct, 12); return b64.enc(out);
  },
  save(momentID, b64key) { localStorage.setItem('moment.key.' + momentID, b64key); },
  load(momentID) { return localStorage.getItem('moment.key.' + momentID); }
};

// ---- Geo cells (0.1°), same as GeoCell in the app -------------------------
export const Geo = {
  cell: (lat, lon) => `${Math.floor(lat * 10)}_${Math.floor(lon * 10)}`,
  cells(lat, lon, radiusKm) {
    const dLat = radiusKm / 111, dLon = radiusKm / (111 * Math.max(0.2, Math.cos(lat * Math.PI / 180)));
    const out = new Set();
    for (let a = lat - dLat; a <= lat + dLat + 1e-9; a += 0.1) for (let o = lon - dLon; o <= lon + dLon + 1e-9; o += 0.1) out.add(this.cell(a, o));
    out.add(this.cell(lat, lon));
    return [...out].slice(0, 400);
  }
};

// ---- Relay client -----------------------------------------------------------
export class Relay {
  constructor(urls, onEvent) { this.urls = urls; this.onEvent = onEvent; this.sockets = new Map(); this.subs = new Map(); this.seen = new Set(); this.status = new Map(); }
  connect() { for (const u of this.urls) this.open(u); }
  open(u) {
    const ws = new WebSocket(u); this.sockets.set(u, ws); this.status.set(u, 'connecting'); this.onStatus?.();
    ws.onopen = () => { this.status.set(u, 'open'); this.onStatus?.(); for (const [id, f] of this.subs) ws.send(JSON.stringify(['REQ', id, f])); };
    ws.onmessage = async (m) => {
      let arr; try { arr = JSON.parse(m.data); } catch { return; }
      if (arr[0] === 'EVENT' && arr[1]?.id && !this.seen.has(arr[1].id) && await Events.verify(arr[1])) { this.seen.add(arr[1].id); this.onEvent(arr[1]); }
    };
    ws.onclose = () => { this.status.set(u, 'closed'); this.onStatus?.(); setTimeout(() => this.open(u), 5000); };
  }
  subscribe(id, filter) { this.subs.set(id, filter); for (const ws of this.sockets.values()) if (ws.readyState === 1) ws.send(JSON.stringify(['REQ', id, filter])); }
  publish(e) { for (const ws of this.sockets.values()) if (ws.readyState === 1) ws.send(JSON.stringify(['EVENT', e])); }
  get connected() { return [...this.status.values()].filter(s => s === 'open').length; }
}

// ---- State: fold events into creators, posts and what you've unlocked ----------
// The same events the iPhone app writes, read the same way. A set's window (title, price, cover) is
// public; its contents are sealed under a per-set key the creator hands to buyers only — so this
// browser can show you every locked post on the network and open exactly the ones you paid for.
export class Store {
  constructor() { this.events = new Map(); this.listeners = []; }
  ingest(e) {
    if (this.events.has(e.id)) return; this.events.set(e.id, e);
    for (const l of this.listeners) l(e);
  }
  kind(k) { return [...this.events.values()].filter(e => e.kind === k).sort((a, b) => a.createdAt - b.createdAt); }
  profile(author) { const p = this.kind('profile').filter(e => e.author === author).pop(); return p ? Events.payload(p) : null; }
  name(author) { return this.profile(author)?.displayName || 'Creator'; }

  /// Everyone this browser has heard of who has published anything sellable.
  creators() {
    const ids = new Set();
    for (const e of this.kind('vaultSet')) ids.add(e.author);
    for (const e of this.kind('plan')) ids.add(e.author);
    return [...ids];
  }

  /// One creator's subscription, or null. `tier: "none"` is how the app cancels one.
  plan(author) {
    const e = this.kind('plan').filter(x => x.author === author).pop();
    const p = e && Events.payload(e);
    if (!p || p.tier === 'none') return null;
    return { creatorID: author, creatorName: p.creatorName, title: p.title, pitch: p.pitch,
             perks: p.perks || [], priceMinor: p.priceMinor ?? 0, currency: p.currency || 'INR' };
  }

  links(author) { const e = this.kind('links').filter(x => x.author === author).pop(); return (e && Events.payload(e)?.links) || null; }

  /// Sets, newest first. A later event for the same set id replaces the earlier one; one with a null
  /// `set` is a delete.
  sets(author) {
    const latest = new Map();
    for (const e of this.kind('vaultSet')) {
      if (author && e.author !== author) continue;
      const v = Events.payload(e); if (!v) continue;
      const id = e.tags?.set || v.set?.id;
      if (!v.set) { latest.delete(id); continue; }
      latest.set(id, { ...v.set, creatorID: e.author, itemCount: v.itemCount,
                       cover: v.cover ? 'data:image/jpeg;base64,' + v.cover : null,
                       sealedItems: v.sealedItems, eventID: e.id });
    }
    return [...latest.values()].filter(s => s.visible !== false).sort((a, b) => b.createdAt - a.createdAt);
  }

  /// Sets I've paid for, by id.
  purchases() {
    const out = new Set();
    for (const e of this.kind('vaultBuy')) if (e.author === Identity.author && e.tags?.set) out.add(e.tags.set);
    return out;
  }
  /// Creators I'm subscribed to, with the 30 days the app grants.
  subscriptions() {
    const out = new Map();
    for (const e of this.kind('subscribe')) {
      if (e.author !== Identity.author) continue;
      const p = Events.payload(e); const to = e.tags?.to; if (!to) continue;
      const days = p?.days ?? 30;
      out.set(to, { creatorID: to, expiresAt: e.createdAt + days * 86400 });
    }
    return out;
  }
  following() {
    const out = new Map();
    for (const e of [...this.kind('follow'), ...this.kind('unfollow')].sort((a, b) => a.createdAt - b.createdAt)) {
      if (e.author !== Identity.author || !e.tags?.to) continue;
      out.set(e.tags.to, e.kind === 'follow');
    }
    return new Set([...out].filter(([, on]) => on).map(([id]) => id));
  }

  /// What a viewer has to do to see a post — the same three gates as `CreatorFeedBuilder`.
  /// A subscribers-only set whose creator has no published plan is left out entirely, because a lock
  /// we can't put a price on isn't worth showing.
  gate(set, purchases, subs) {
    if (set.creatorID === Identity.author) return { kind: 'open' };
    if (set.subscribersOnly) {
      const active = subs.get(set.creatorID);
      if (active && active.expiresAt > Date.now() / 1000) return { kind: 'open' };
      const plan = this.plan(set.creatorID);
      return plan ? { kind: 'subscribe', priceMinor: plan.priceMinor, currency: plan.currency, title: plan.title } : null;
    }
    if (purchases.has(set.id)) return { kind: 'open' };
    if (!set.priceMinor) return { kind: 'open' };
    return { kind: 'buy', priceMinor: set.priceMinor, currency: set.currency };
  }

  /// The feed: every post from every creator this browser knows, newest first, each with its gate.
  feed() {
    const purchases = this.purchases(), subs = this.subscriptions();
    const out = [];
    for (const s of this.sets(null)) {
      const gate = this.gate(s, purchases, subs);
      if (!gate) continue;
      out.push({ ...s, gate, creatorName: s.creatorName || this.name(s.creatorID) });
    }
    return out.sort((a, b) => b.createdAt - a.createdAt);
  }

  /// The photos inside a set, if this browser holds the key. Returns null when it doesn't —
  /// which is the honest answer, not an error.
  async items(set) {
    const raw = Keys.load('set.' + set.id);
    if (!raw || !set.sealedItems) return null;
    try {
      const key = await Keys.importRaw(raw);
      const items = JSON.parse(await Keys.open(key, set.sealedItems));
      return items.map(i => ({ ...i, url: i.media ? 'data:' + (i.kind === 'video' ? 'video/mp4' : 'image/jpeg') + ';base64,' + i.media : null }));
    } catch { return null; }
  }
}

/// Prices, one place. Minor units in, the creator's currency out.
export const Money = {
  label(minor, currency = 'INR') {
    try { return new Intl.NumberFormat(navigator.language, { style: 'currency', currency, maximumFractionDigits: 0 }).format((minor || 0) / 100); }
    catch { return ((minor || 0) / 100).toFixed(0); }
  }
};
