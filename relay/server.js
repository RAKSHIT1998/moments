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
const { createHash, verify, createPublicKey } = require('crypto');
const fs = require('fs');

const PORT = Number(process.env.PORT || 7447);
const DATA = process.env.DATA || './events.jsonl';
const MAX_EVENT_BYTES = 2 * 1024 * 1024;   // sides carry base64 media ≤1280px
const RETAIN_DAYS = Number(process.env.RETAIN_DAYS || 365);

const events = new Map();        // id → event
const deleted = new Set();

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
  if (e.kind === 'delete' && e.tags?.target) {
    const t = events.get(e.tags.target);
    if (!t || t.author === e.author) deleted.add(e.tags.target);
  }
  events.set(e.id, e);
  fs.appendFileSync(DATA, JSON.stringify(e) + '\n');
  return null;
}

// Load
if (fs.existsSync(DATA)) {
  for (const line of fs.readFileSync(DATA, 'utf8').split('\n')) {
    if (!line) continue;
    try { const e = JSON.parse(line); if (isValid(e)) { events.set(e.id, e); if (e.kind === 'delete' && e.tags?.target) deleted.add(e.tags.target); } } catch {}
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
      for (const e of events.values()) { if (!deleted.has(e.id) && matches(b, e)) ws.send(JSON.stringify(['EVENT', e])); }
      ws.send(JSON.stringify(['EOSE', a]));
    } else if (type === 'CLOSE') {
      subs.get(ws).delete(a);
    }
  });
  ws.on('close', () => subs.delete(ws));
});
console.log(`MOMENT relay on ws://0.0.0.0:${PORT} — ${events.size} events`);
