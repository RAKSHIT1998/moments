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

// ---- State: fold events into Moments / NOW / profiles --------------------------
export class Store {
  constructor() { this.events = new Map(); this.byMoment = new Map(); this.listeners = []; }
  ingest(e) {
    if (this.events.has(e.id)) return; this.events.set(e.id, e);
    const m = e.tags?.moment; if (m) { if (!this.byMoment.has(m)) this.byMoment.set(m, []); this.byMoment.get(m).push(e); }
    for (const l of this.listeners) l(e);
  }
  kind(k) { return [...this.events.values()].filter(e => e.kind === k).sort((a, b) => a.createdAt - b.createdAt); }
  profile(author) { const p = this.kind('profile').filter(e => e.author === author).pop(); return p ? Events.payload(p) : null; }
  /// A public Moment, or a private one when this browser holds its key.
  async moment(id) {
    const root = this.events.get(id); if (!root || root.kind !== 'moment') return null;
    let p, locked = false, key = null;
    if (root.tags.sub) { const env = Events.payload(root); p = env?.preview; locked = true; }
    else if (root.tags.enc === '1') {
      const k = Keys.load(id); if (!k) return { id, locked: true, title: 'Private Moment', createdAt: root.createdAt, creator: root.author, sides: [] };
      key = await Keys.importRaw(k); try { p = JSON.parse(await Keys.open(key, root.content)); } catch { return null; }
    } else p = Events.payload(root);
    if (!p) return null;
    const members = new Map([[root.author, p.creatorName]]); const sides = [];
    for (const e of (this.byMoment.get(id) || [])) {
      let body = null;
      if (e.tags.enc === '1') { if (!key) continue; try { body = JSON.parse(await Keys.open(key, e.content)); } catch { continue; } } else body = Events.payload(e);
      if (!body) continue;
      if (e.kind === 'join') members.set(e.author, body.name);
      if (e.kind === 'contribution') { members.set(e.author, body.authorName); sides.push({ id: e.id, author: body.authorName, caption: body.caption, media: body.media, kind: body.kind, at: (body.originalTimestamp || e.createdAt) }); }
    }
    sides.sort((a, b) => a.at - b.at);
    return { id, locked, title: p.title, description: p.description || '', cover: p.cover, place: p.place, creator: root.author, creatorName: p.creatorName, createdAt: root.createdAt, members: [...members.values()], sides, isLive: p.isLive, visibility: p.visibility, key };
  }
  nows() { const now = Date.now() / 1000; return this.kind('now').map(e => ({ e, p: Events.payload(e) })).filter(x => x.p && x.p.expiresAt > now).reverse(); }
}
