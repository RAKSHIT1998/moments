// Does MOMENT Web read what the iPhone app writes?
//
// These fixtures are the exact event shapes `DecentralizedBackend.emit(...)` puts on the wire —
// `Payloads.Vault`, `Payloads.Plan`, `Payloads.Buy`, `Payloads.Subscribe` — encoded the way
// `JSONEncoder.event` encodes them (sorted keys, dates as seconds since 1970). If the app changes a
// payload and this file isn't updated, these fail, which is the point.
//
//   node web/app/test/store.test.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));

// --- the browser bits the module expects -------------------------------------
const mem = new Map();
globalThis.localStorage = {
  getItem: (k) => (mem.has(k) ? mem.get(k) : null),
  setItem: (k, v) => mem.set(k, String(v)),
  removeItem: (k) => mem.delete(k)
};
const ME = 'me_public_key_base64';
globalThis.nacl = {
  randomBytes: (n) => new Uint8Array(n),
  sign: { keyPair: { fromSeed: () => ({ publicKey: new Uint8Array(32), secretKey: new Uint8Array(64) }) } },
  box: { keyPair: Object.assign(() => ({ publicKey: new Uint8Array(32), secretKey: new Uint8Array(32) }),
                                { fromSecretKey: () => ({ publicKey: new Uint8Array(32), secretKey: new Uint8Array(32) }) }) }
};

const src = readFileSync(join(here, '..', 'moment.js'), 'utf8');
const { Store, Identity, Money } = await import('data:text/javascript;base64,' + Buffer.from(src).toString('base64'));
Object.defineProperty(Identity, 'author', { get: () => ME, configurable: true });

// --- fixtures ------------------------------------------------------------------
let seq = 0;
const ev = (kind, author, tags, payload, at) => ({
  id: 'e' + (++seq), kind, author, createdAt: at ?? 1_700_000_000 + seq, tags, content: JSON.stringify(payload), sig: 'x'
});

/// `Payloads.Vault` — the set as everyone sees it; the items are sealed under the set key.
const setEvent = (author, over = {}, at) => {
  const set = {
    id: over.id || 's1', creatorID: author, creatorName: over.creatorName || 'Sarah Kim',
    title: over.title || 'Kitchen, close up', blurb: over.blurb || '', priceMinor: over.priceMinor ?? 0,
    currency: 'INR', cover: null, itemCount: 3, isVideo: !!over.isVideo,
    createdAt: at ?? 1_700_000_000, visible: over.visible !== false, subscribersOnly: !!over.subscribersOnly
  };
  return ev('vaultSet', author, { set: set.id, price: String(set.priceMinor) },
            { set, cover: null, sealedItems: 'sealed', itemCount: 3 }, at);
};
/// `Payloads.Plan` — a creator's one subscription. `tier: "none"` is a cancellation.
const planEvent = (author, priceMinor = 14900, tier = 't1') =>
  ev('plan', author, {}, { title: "Sarah's kitchen", pitch: 'The recipes behind the photos.', tier,
                           perks: ['Weekly recipe'], payoutHint: '', creatorName: 'Sarah Kim', priceMinor, currency: 'INR' });
const profileEvent = (author, name) =>
  ev('profile', author, {}, { displayName: name, handle: name.toLowerCase(), bio: '', avatar: null,
                              privateAccount: false, momentID: 'MMT-TEST-TEST-TEST', agreePK: 'pk' });
/// `Payloads.Buy` — written by the buyer, tagged to the creator.
const buyEvent = (buyer, setID, creator) =>
  ev('vaultBuy', buyer, { set: setID, to: creator }, { amountMinor: 19900, currency: 'INR', rail: 'web', reference: 'r', name: 'Me' });
const subEvent = (buyer, creator, at) =>
  ev('subscribe', buyer, { to: creator }, { tier: 't1', days: 30, transactionID: null, name: 'Me' }, at);

const fresh = (events) => { const s = new Store(); for (const e of events) s.ingest(e); return s; };

// --- tests ----------------------------------------------------------------------
const tests = {
  'a free set is open to everyone'() {
    const s = fresh([profileEvent('sarah', 'Sarah Kim'), setEvent('sarah')]);
    const feed = s.feed();
    assert.equal(feed.length, 1);
    assert.equal(feed[0].gate.kind, 'open');
    assert.equal(feed[0].creatorName, 'Sarah Kim');
  },

  'a priced set is locked, and names its price'() {
    const s = fresh([setEvent('sarah', { priceMinor: 19900 })]);
    const [p] = s.feed();
    assert.equal(p.gate.kind, 'buy');
    assert.equal(p.gate.priceMinor, 19900);
  },

  'buying it opens it'() {
    const s = fresh([setEvent('sarah', { priceMinor: 19900 }), buyEvent(ME, 's1', 'sarah')]);
    assert.equal(s.feed()[0].gate.kind, 'open');
  },

  "someone else's purchase does not open it for me"() {
    const s = fresh([setEvent('sarah', { priceMinor: 19900 }), buyEvent('someone_else', 's1', 'sarah')]);
    assert.equal(s.feed()[0].gate.kind, 'buy');
  },

  'a subscribers-only set asks for the subscription, at the creator\'s price'() {
    const s = fresh([planEvent('sarah'), setEvent('sarah', { subscribersOnly: true })]);
    const [p] = s.feed();
    assert.equal(p.gate.kind, 'subscribe');
    assert.equal(p.gate.priceMinor, 14900);
  },

  'a subscribers-only set with no published plan is not shown at all'() {
    // The app's rule: a lock we can't put a price on isn't worth showing.
    const s = fresh([setEvent('sarah', { subscribersOnly: true })]);
    assert.equal(s.feed().length, 0);
  },

  'an active subscription opens it; a lapsed one does not'() {
    const now = Math.floor(Date.now() / 1000);
    const live = fresh([planEvent('sarah'), setEvent('sarah', { subscribersOnly: true }), subEvent(ME, 'sarah', now - 86400)]);
    assert.equal(live.feed()[0].gate.kind, 'open');
    const dead = fresh([planEvent('sarah'), setEvent('sarah', { subscribersOnly: true }), subEvent(ME, 'sarah', now - 40 * 86400)]);
    assert.equal(dead.feed()[0].gate.kind, 'subscribe');
  },

  'my own posts are always open to me'() {
    const s = fresh([setEvent(ME, { priceMinor: 99900, subscribersOnly: true })]);
    assert.equal(s.feed()[0].gate.kind, 'open');
  },

  'a cancelled plan stops being a plan'() {
    const s = fresh([planEvent('sarah'), planEvent('sarah', 0, 'none')]);
    assert.equal(s.plan('sarah'), null);
  },

  'a later event for the same set replaces the earlier one'() {
    const s = fresh([setEvent('sarah', { title: 'First' }, 100), setEvent('sarah', { title: 'Renamed', priceMinor: 500 }, 200)]);
    const sets = s.sets('sarah');
    assert.equal(sets.length, 1);
    assert.equal(sets[0].title, 'Renamed');
    assert.equal(sets[0].priceMinor, 500);
  },

  'a delete removes the set'() {
    const gone = ev('vaultSet', 'sarah', { set: 's1' }, { set: null, cover: null, sealedItems: null, itemCount: 0 }, 300);
    const s = fresh([setEvent('sarah', {}, 100), gone]);
    assert.equal(s.sets('sarah').length, 0);
  },

  'an invisible set is not published'() {
    const s = fresh([setEvent('sarah', { visible: false })]);
    assert.equal(s.sets('sarah').length, 0);
  },

  'the feed is newest first'() {
    const s = fresh([setEvent('sarah', { id: 'old' }, 100), setEvent('sarah', { id: 'new' }, 900)]);
    assert.deepEqual(s.feed().map(p => p.id), ['new', 'old']);
  },

  'follows are last-write-wins'() {
    const s = fresh([
      ev('follow', ME, { to: 'sarah', close: '0' }, { ok: '1' }, 100),
      ev('unfollow', ME, { to: 'sarah' }, { ok: '1' }, 200),
      ev('follow', ME, { to: 'sarah', close: '0' }, { ok: '1' }, 300)
    ]);
    assert.ok(s.following().has('sarah'));
  },

  'items stay null without the key, rather than throwing'() {
    const s = fresh([setEvent('sarah', { priceMinor: 100 })]);
    return s.items(s.sets('sarah')[0]).then(items => assert.equal(items, null));
  },

  'prices are formatted, not printed raw'() {
    assert.match(Money.label(19900, 'INR'), /199/);
    assert.equal(Money.label(0, 'INR').includes('0'), true);
  }
};

let pass = 0, fail = 0;
for (const [name, fn] of Object.entries(tests)) {
  try { await fn(); pass++; console.log('  ok  ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + '\n       ' + e.message); }
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
