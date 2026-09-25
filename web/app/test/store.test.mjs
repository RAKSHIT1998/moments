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

/// `Payloads.Offer` — what a creator will do, and for how much.
const offerEvent = (author, offerID, kind, priceMinor, over = {}, at) =>
  ev('offer', author, { offer: offerID },
     { offer: { id: offerID, creatorID: author, creatorName: over.creatorName || 'Sarah Kim', kind,
                minutes: over.minutes ?? 0, priceMinor, currency: 'INR', note: '', active: over.active !== false } }, at);

/// `Payloads.BookingBody` — a request and where it got to.
const bookingEvent = (author, over = {}, at) => {
  const b = { id: over.id || 'bk1', offerID: over.offerID || '', creatorID: over.creatorID || 'sarah',
              creatorName: 'Sarah Kim', buyerID: over.buyerID || ME, buyerName: 'Me',
              kind: over.kind || 'photo', minutes: over.minutes ?? 0, amountMinor: over.amountMinor ?? 0,
              currency: 'INR', startsAt: 1_800_000_000, status: over.status || 'asked', note: over.note || '',
              rail: 'web', reference: null, roomID: '', createdAt: at ?? 1_700_000_000 };
  return ev('booking', author, { booking: b.id, to: b.creatorID }, { booking: b }, at);
};

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

  'offers come back in shopping order, not price order'() {
    const s = fresh([
      offerEvent('sarah', 'o_custom', 'custom', 29900),
      offerEvent('sarah', 'o_voice', 'voiceCall', 49900, { minutes: 10 }),
      offerEvent('sarah', 'o_photo', 'photo', 9900)
    ]);
    assert.deepEqual(s.offers('sarah').map(o => o.kind), ['photo', 'voiceCall', 'custom']);
  },

  'a paused offer is not on sale'() {
    const s = fresh([offerEvent('sarah', 'o1', 'photo', 9900, { active: false })]);
    assert.equal(s.offers('sarah').length, 0);
  },

  'a later offer event replaces the earlier one'() {
    const s = fresh([
      offerEvent('sarah', 'o1', 'photo', 9900, {}, 100),
      offerEvent('sarah', 'o1', 'photo', 19900, {}, 200)
    ]);
    assert.equal(s.offers('sarah')[0].priceMinor, 19900);
  },

  'my requests and requests to me both show; other people\'s do not'() {
    const s = fresh([
      bookingEvent(ME, { id: 'mine' }),
      bookingEvent('sarah', { id: 'tome', creatorID: ME, buyerID: 'sarah' }),
      bookingEvent('x', { id: 'theirs', creatorID: 'y', buyerID: 'x' })
    ]);
    const ids = s.bookings().map(b => b.id);
    assert.ok(ids.includes('mine'));
    assert.ok(ids.includes('tome'));
    assert.ok(!ids.includes('theirs'), 'a request between two other people was visible');
  },

  'only the creator can quote — a buyer cannot price their own request'() {
    // The buyer publishes a "quoted" event for their own booking, trying to set the price to zero.
    const s = fresh([
      bookingEvent(ME, { id: 'b1', creatorID: 'sarah' }, 100),
      bookingEvent(ME, { id: 'b1', creatorID: 'sarah', status: 'quoted', amountMinor: 0 }, 200)
    ]);
    assert.equal(s.bookings()[0].status, 'asked', 'a buyer quoted their own request');
  },

  'the creator quoting does move it'() {
    const s = fresh([
      bookingEvent(ME, { id: 'b1', creatorID: 'sarah' }, 100),
      bookingEvent('sarah', { id: 'b1', creatorID: 'sarah', status: 'quoted', amountMinor: 49900 }, 200)
    ]);
    const b = s.bookings()[0];
    assert.equal(b.status, 'quoted');
    assert.equal(b.amountMinor, 49900);
  },

  'search finds a creator by name or by handle, and never myself'() {
    const s = fresh([
      profileEvent('sarah', 'Sarah Kim'),
      setEvent('sarah'),
      profileEvent(ME, 'Me Myself'),
      setEvent(ME)
    ]);
    assert.equal(s.searchCreators('sarah').length, 1);
    assert.equal(s.searchCreators('@sarah').length, 1, 'handle search should ignore the @');
    assert.equal(s.searchCreators('nobody').length, 0);
    assert.ok(!s.searchCreators('').some(c => c.id === ME), 'I turned up in my own search results');
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
