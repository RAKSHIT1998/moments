// MOMENT reference relay — a tiny WebSocket server anyone can run.
// It stores signed events and hands them to whoever asks with a matching filter.
// It verifies every signature, never modifies anything, and cannot read non-public Moments
// (their content is AES-GCM ciphertext under a key that only travels inside the invite link).
//
//   npm install ws
//   node server.js            # ws://localhost:7447
//   PORT=8080 DATA=./events.jsonl node server.js
//
// Protocol (JSON arrays, one per message):
//   client → relay   ["EVENT", <event>]              publish
//                    ["EPHEMERAL", <event>]          forward to subscribers, don't store (typing)
//                    ["REQ", <id>, <filter>]          subscribe; filter = {kinds, authors, moments, geo, tags, since}
//                    ["CLOSE", <id>]
//   relay  → client  ["EVENT", <event>]              matching stored + live events
//                    ["EOSE", <id>]                   end of stored events for <id>
//                    ["OK", <eventId>, <bool>, <msg>]
const { WebSocketServer } = require('ws');
const { createHash, verify, createPublicKey, timingSafeEqual } = require('crypto');
const http = require('http');
const path = require('path');
const fs = require('fs');

const PORT = Number(process.env.PORT || 7447);
const DATA = process.env.DATA || './events.jsonl';
const MAX_EVENT_BYTES = 2 * 1024 * 1024;   // sides carry base64 media ≤1280px
const RETAIN_DAYS = Number(process.env.RETAIN_DAYS || 365);

// Operator console. Off unless you set a token, and bound to localhost unless you say otherwise —
// put it behind your own TLS/SSH rather than opening it to the internet.
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || '';
const ADMIN_PORT = Number(process.env.ADMIN_PORT || 7448);
const ADMIN_HOST = process.env.ADMIN_HOST || '127.0.0.1';
const REFUSED = process.env.REFUSED || path.join(path.dirname(DATA), 'refused.json');

const events = new Map();        // id → event
const deleted = new Set();
// Authors and events this relay declines to carry. Local to this relay: the content still exists on
// every other relay and on the phones that hold it. A relay can stop being a party to something;
// it cannot delete it from the world, and this console never pretends otherwise.
const refusedAuthors = new Set();
const refusedEvents = new Set();
function loadRefusals() {
  try {
    const r = JSON.parse(fs.readFileSync(REFUSED, 'utf8'));
    (r.authors || []).forEach(a => refusedAuthors.add(a));
    (r.events || []).forEach(e => refusedEvents.add(e));
  } catch {}
}
function saveRefusals() {
  try { fs.writeFileSync(REFUSED, JSON.stringify({ authors: [...refusedAuthors], events: [...refusedEvents] }, null, 2)); }
  catch (e) { console.error('could not save refusals:', e.message); }
}
const isRefused = (e) => refusedAuthors.has(e.author) || refusedEvents.has(e.id);

function canonical(e) {
  const tags = Object.keys(e.tags || {}).sort().map(k => `${k}=${e.tags[k]}`).join('&');
  return Buffer.from(`v1|${e.kind}|${e.author}|${Math.floor(e.createdAt)}|${tags}|${e.content}`, 'utf8');
}
function isValid(e) {
  try {
    if (!e || typeof e.id !== 'string' || typeof e.sig !== 'string' || typeof e.author !== 'string') return false;
    const canon = canonical(e);
    if (createHash('sha256').update(canon).digest('hex') !== e.id) return false;
    // Ed25519 raw 32-byte public key → SPKI DER
    const raw = Buffer.from(e.author, 'base64');
    if (raw.length !== 32) return false;
    const spki = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), raw]);
    const key = createPublicKey({ key: spki, format: 'der', type: 'spki' });
    return verify(null, canon, key, Buffer.from(e.sig, 'base64'));
  } catch { return false; }
}
function matches(f, e) {
  if (!f || typeof f !== 'object') return false;
  if (f.kinds && !f.kinds.includes(e.kind)) return false;
  if (f.authors && !f.authors.includes(e.author)) return false;
  if (f.moments && !f.moments.includes(e.tags?.moment) && !f.moments.includes(e.id)) return false;
  if (f.geo && !f.geo.includes(e.tags?.geo)) return false;
  if (f.since && e.createdAt < f.since) return false;
  if (f.tags && !Object.entries(f.tags).some(([k, v]) => e.tags?.[k] === v)) return false;
  return true;
}
function ingest(e) {
  if (events.has(e.id)) return 'duplicate';
  if (!isValid(e)) return 'invalid signature';
  if (isRefused(e)) return 'refused by this relay';
  if (e.kind === 'delete' && e.tags?.target) {
    const t = events.get(e.tags.target);
    if (!t || t.author === e.author) deleted.add(e.tags.target);
  }
  events.set(e.id, e);
  fs.appendFileSync(DATA, JSON.stringify(e) + '\n');
  return null;
}

loadRefusals();
// Load
if (fs.existsSync(DATA)) {
  for (const line of fs.readFileSync(DATA, 'utf8').split('\n')) {
    if (!line) continue;
    // Refusals are loaded first, so anything this relay has declined never comes back into memory on
    // a restart. Without this the console would say "dropped" and the next restart would undo it.
    try { const e = JSON.parse(line); if (isValid(e) && !isRefused(e)) { events.set(e.id, e); if (e.kind === 'delete' && e.tags?.target) deleted.add(e.tags.target); } } catch {}
  }
}
// Retention: drop expired NOW posts and anything older than RETAIN_DAYS
setInterval(() => {
  const now = Date.now() / 1000;
  for (const [id, e] of events) {
    const exp = Number(e.tags?.exp || 0);
    if ((exp && exp < now) || now - e.createdAt > RETAIN_DAYS * 86400) events.delete(id);
  }
}, 3600 * 1000);

const wss = new WebSocketServer({ port: PORT, maxPayload: MAX_EVENT_BYTES });
const subs = new Map();  // ws → Map(id → filter)
wss.on('connection', ws => {
  subs.set(ws, new Map());
  ws.on('message', raw => {
    let msg; try { msg = JSON.parse(raw); } catch { return; }
    if (!Array.isArray(msg)) return;
    const [type, a, b] = msg;
    if (type === 'EVENT') {
      const err = ingest(a);
      ws.send(JSON.stringify(['OK', a?.id, !err, err || '']));
      if (err) return;
      for (const [peer, filters] of subs) {
        if (peer === ws || peer.readyState !== 1) continue;
        for (const f of filters.values()) { if (matches(f, a)) { peer.send(JSON.stringify(['EVENT', a])); break; } }
      }
    } else if (type === 'EPHEMERAL') {
      // Typing indicators and the like: verified, forwarded to matching subscribers, never written down.
      if (!isValid(a)) return;
      for (const [peer, filters] of subs) {
        if (peer === ws || peer.readyState !== 1) continue;
        for (const f of filters.values()) { if (matches(f, a)) { peer.send(JSON.stringify(['EPHEMERAL', a])); break; } }
      }
    } else if (type === 'REQ' && typeof a === 'string') {
      subs.get(ws).set(a, b);
      for (const e of events.values()) { if (!deleted.has(e.id) && !isRefused(e) && matches(b, e)) ws.send(JSON.stringify(['EVENT', e])); }
      ws.send(JSON.stringify(['EOSE', a]));
    } else if (type === 'CLOSE') {
      subs.get(ws).delete(a);
    }
  });
  ws.on('close', () => subs.delete(ws));
});
console.log(`MOMENT relay on ws://0.0.0.0:${PORT} — ${events.size} events`);

// ---- Operator console -------------------------------------------------------------
// What an operator can honestly do on a network with no centre:
//   * read the reports that reached this relay — somebody has to, and nothing else could
//   * see what this relay is carrying and what it is earning the platform
//   * refuse to carry an author or an event *here*
// What no console can do, and this one never claims: delete something from the network, ban a person
// globally, or read a paid set. The media is sealed under keys that never touch a relay.
function adminJSON(res, code, body) {
  const s = JSON.stringify(body);
  res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store', 'content-length': Buffer.byteLength(s) });
  res.end(s);
}
function authorised(req) {
  const given = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!ADMIN_TOKEN || !given) return false;
  const a = Buffer.from(given), b = Buffer.from(ADMIN_TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
}
const payload = (e) => { try { return JSON.parse(e.content); } catch { return null; } };
/// Newest profile per author, for putting a name next to a key.
function profiles() {
  const out = new Map();
  for (const e of events.values()) {
    if (e.kind !== 'profile') continue;
    const prev = out.get(e.author);
    if (!prev || prev.createdAt < e.createdAt) out.set(e.author, { createdAt: e.createdAt, ...(payload(e) || {}) });
  }
  return out;
}
function summary() {
  const byKind = {};
  let bytes = 0, oldest = Infinity, newest = 0;
  for (const e of events.values()) {
    byKind[e.kind] = (byKind[e.kind] || 0) + 1;
    bytes += Buffer.byteLength(e.content || '');
    oldest = Math.min(oldest, e.createdAt); newest = Math.max(newest, e.createdAt);
  }
  return {
    events: events.size, bytes, byKind,
    oldest: Number.isFinite(oldest) ? oldest : null, newest: newest || null,
    deleted: deleted.size, peers: subs.size,
    refusedAuthors: refusedAuthors.size, refusedEvents: refusedEvents.size,
    retainDays: RETAIN_DAYS, uptimeSeconds: Math.round(process.uptime()), port: PORT
  };
}
/// Reports, newest first, with whatever this relay knows about the target.
function reports() {
  const who = profiles();
  const name = (id) => (id && who.get(id)?.displayName) || null;
  return [...events.values()]
    .filter(e => e.kind === 'report' && !isRefused(e))
    .sort((a, b) => b.createdAt - a.createdAt)
    .map(e => {
      const p = payload(e) || {};
      return {
        id: e.id, at: e.createdAt,
        reporter: e.author, reporterName: name(e.author),
        targetUserID: p.targetUserID || null, targetName: name(p.targetUserID),
        targetMomentID: p.targetMomentID || null,
        reason: p.reason || 'unspecified', details: p.details || '',
        targetRefused: p.targetUserID ? refusedAuthors.has(p.targetUserID) : false,
        // Reports against the same target, so a pattern is visible rather than one row at a time.
        alsoReported: [...events.values()].filter(x => x.kind === 'report' && (payload(x) || {}).targetUserID === p.targetUserID).length
      };
    });
}
/// Money that crossed this relay. Purchase and subscription events carry their amounts in the clear —
/// that is how a platform fee can be computed at all without a server holding the content.
function revenue(sinceDays = 30) {
  const since = Date.now() / 1000 - sinceDays * 86400;
  let salesMinor = 0, sales = 0, subs_ = 0, tips = 0, currency = null;
  for (const e of events.values()) {
    if (e.createdAt < since || isRefused(e)) continue;
    const p = payload(e) || {};
    if (e.kind === 'vaultBuy') { sales++; salesMinor += Number(p.amountMinor || 0); currency ||= p.currency; }
    if (e.kind === 'subscribe') subs_++;
    if (e.kind === 'tip') tips++;
  }
  return {
    sinceDays, sales, salesMinor, subscriptions: subs_, tips, currency: currency || 'INR',
    platformFeeMinor: Math.round(salesMinor * 0.10),
    note: 'Sales seen by this relay only, and only on the web rail. App Store purchases never pass through here, and a phone that synced over the mesh may never have told this relay anything.'
  };
}

if (ADMIN_TOKEN) {
  const consoleFile = path.join(__dirname, 'console', 'index.html');
  http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/' || url.pathname === '/index.html') {
      // The page itself is not secret; every call it makes needs the token.
      fs.readFile(consoleFile, (err, data) => {
        if (err) return adminJSON(res, 404, { error: 'console not installed' });
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        res.end(data);
      });
      return;
    }
    if (!url.pathname.startsWith('/api/')) return adminJSON(res, 404, { error: 'not found' });
    if (!authorised(req)) return adminJSON(res, 401, { error: 'bad or missing token' });

    if (req.method === 'GET' && url.pathname === '/api/summary') return adminJSON(res, 200, summary());
    if (req.method === 'GET' && url.pathname === '/api/reports') return adminJSON(res, 200, { reports: reports() });
    if (req.method === 'GET' && url.pathname === '/api/revenue') {
      return adminJSON(res, 200, revenue(Number(url.searchParams.get('days') || 30)));
    }
    if (req.method === 'GET' && url.pathname === '/api/refusals') {
      return adminJSON(res, 200, { authors: [...refusedAuthors], events: [...refusedEvents] });
    }
    if (req.method === 'POST' && url.pathname === '/api/refuse') {
      let body = '';
      req.on('data', c => { body += c; if (body.length > 64_000) req.destroy(); });
      req.on('end', () => {
        let b; try { b = JSON.parse(body); } catch { return adminJSON(res, 400, { error: 'bad json' }); }
        const { author, event: eventID, undo } = b;
        if (!author && !eventID) return adminJSON(res, 400, { error: 'pass an author or an event' });
        if (undo) {
          if (author) refusedAuthors.delete(author);
          if (eventID) refusedEvents.delete(eventID);
        } else {
          if (author) refusedAuthors.add(author);
          if (eventID) refusedEvents.add(eventID);
        }
        // Stop serving it now, not just from the next restart.
        let dropped = 0;
        if (!undo) for (const [id, e] of events) if (isRefused(e)) { events.delete(id); dropped++; }
        saveRefusals();
        adminJSON(res, 200, { ok: true, dropped, authors: refusedAuthors.size, events: refusedEvents.size });
      });
      return;
    }
    adminJSON(res, 404, { error: 'not found' });
  }).listen(ADMIN_PORT, ADMIN_HOST, () => {
    console.log(`operator console on http://${ADMIN_HOST}:${ADMIN_PORT} — token required`);
  });
} else {
  console.log('operator console disabled (set ADMIN_TOKEN to enable)');
}
