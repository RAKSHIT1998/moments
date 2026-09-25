import { Identity, Events, Keys, Relay, Store, Money } from './moment.js';

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const store = new Store();
let relay = null, me = null, myID = '';
const relays = () => JSON.parse(localStorage.getItem('moment.relays') || '[]');
const ago = (t) => {
  const s = Math.max(0, Date.now() / 1000 - t);
  if (s < 3600) return `${Math.round(s / 60)}m`;
  if (s < 86400) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
};
const initials = (n) => String(n || '?').trim().split(/\s+/).slice(0, 2).map(w => w[0]).join('').toUpperCase();

async function boot() {
  if (typeof nacl === 'undefined') {
    // Without the signing library there is no identity, and every screen here depends on one.
    // Say so, rather than leaving a blank page and no reason.
    $('#view').innerHTML = `<div class="banner warn"><strong>MOMENT Web couldn't start.</strong>
      Its signing library didn't load, so this browser has no identity to sign with. Reload, and if it
      keeps happening the file <code>vendor-nacl-fast.min.js</code> is missing from the server.</div>`;
    return;
  }
  me = await Identity.load(); myID = await me.momentID(); $('#idPill').textContent = myID;
  if (localStorage.getItem('moment.profile.name') == null) localStorage.setItem('moment.profile.name', 'You');
  connect();
  window.addEventListener('hashchange', route); route();
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
}

function connect() {
  if (relay) return;
  const urls = relays(); if (!urls.length) return;
  relay = new Relay(urls, (e) => {
    store.ingest(e);
    if (['vaultSet', 'plan', 'profile', 'vaultBuy', 'subscribe', 'follow', 'unfollow', 'links', 'vaultKey', 'offer', 'booking'].includes(e.kind)) schedule();
  });
  relay.onStatus = () => { const n = relay.connected; $('#relayStatus').textContent = n ? `${n} relay${n > 1 ? 's' : ''}` : 'connecting…'; };
  relay.connect();
  // Everything this client needs: who people are, what they sell, and anything addressed to me.
  relay.subscribe('world', { kinds: ['profile', 'vaultSet', 'plan', 'links', 'offer'] });
  relay.subscribe('mine', { authors: [Identity.author] });
  relay.subscribe('forme', { kinds: ['vaultKey', 'grant', 'booking'], '#to': [Identity.author] });
  relay.subscribe('myreq', { kinds: ['booking'], authors: [Identity.author] });
  publishProfile();
}

async function publishProfile() {
  if (!relay) return;
  const p = {
    displayName: localStorage.getItem('moment.profile.name') || 'You',
    handle: localStorage.getItem('moment.profile.handle') || '',
    bio: localStorage.getItem('moment.profile.bio') || '',
    privateAccount: false, momentID: myID, agreePK: Identity.agreePK
  };
  await publish(await Events.make('profile', {}, JSON.stringify(p)));
}

/// Publish, and keep a copy.
///
/// A relay forwards an event to every subscriber *except* the socket that sent it — which is correct
/// for a relay and wrong for the client, because it means nothing you do ever comes back to you. A
/// follow, a request, a profile edit would all vanish until some other relay echoed them. So the
/// store is told first, then the wire.
async function publish(event) {
  store.ingest(event);
  relay?.publish(event);
  schedule();
  return event;
}

/// Re-renders only the grid, so typing in the search field doesn't rebuild the page under the cursor.
function rerenderDiscoverOnly() {
  const grid = document.querySelector('.grid-creators');
  const results = store.searchCreators(discoverQuery);
  if (grid) { grid.innerHTML = results.map(creatorCard).join(''); }
  else rerender();
}

/// Events arrive in bursts; redraw once per frame rather than once per event.
let pending = false;
function schedule() { if (pending) return; pending = true; requestAnimationFrame(() => { pending = false; rerender(); }); }

let current = '';
function route() {
  const h = location.hash || '#/feed'; current = h;
  document.querySelectorAll('nav.tabs a').forEach(a => a.classList.toggle('on', h.startsWith('#/' + a.dataset.tab)));
  window.scrollTo(0, 0);
  rerender();
}

async function rerender() {
  const h = current, v = $('#view');
  if (h.startsWith('#/u/')) v.innerHTML = await creatorPage(decodeURIComponent(h.slice(4)));
  else if (h.startsWith('#/s/')) v.innerHTML = await setPage(decodeURIComponent(h.slice(4)));
  else if (h.startsWith('#/discover') || h.startsWith('#/creators')) v.innerHTML = discoverPage();
  else if (h.startsWith('#/requests')) v.innerHTML = requestsPage();
  else if (h.startsWith('#/unlocked')) v.innerHTML = await unlockedPage();
  else if (h.startsWith('#/you')) v.innerHTML = youPage();
  else v.innerHTML = feedPage();
  wire();
}

// ---- Home: the creator feed --------------------------------------------------
// A column of posts. A locked one shows its cover blurred with the price on it — nothing is teased
// without naming what it costs.
function feedPage() {
  if (!relays().length) return noRelay();
  const posts = store.feed();
  if (!posts.length) {
    return `<div class="empty"><p>Nothing here yet.</p><p class="tiny">This browser has heard from ${relay?.connected || 0} relay(s) and no creator has posted to them. Add another relay under <a class="link" href="#/you">You</a>, or open a creator's link.</p></div>`;
  }
  return posts.map(postCard).join('');
}

function postCard(p) {
  const locked = p.gate.kind !== 'open';
  const cover = p.cover
    ? `<img src="${p.cover}" alt="">`
    : `<div style="width:100%;height:100%;background:linear-gradient(140deg,var(--accent),transparent)"></div>`;
  const face = p.gate.kind === 'buy'
    ? `<div class="lockface"><div class="price">${esc(Money.label(p.gate.priceMinor, p.gate.currency))}</div>
         <button class="buy" data-buy="${esc(p.id)}">Unlock</button>
         <div class="tiny" style="color:#fff;opacity:.8">${p.itemCount} ${p.isVideo ? 'clip' : 'photo'}${p.itemCount === 1 ? '' : 's'}</div></div>`
    : p.gate.kind === 'subscribe'
      ? `<div class="lockface"><div class="price">${esc(Money.label(p.gate.priceMinor, p.gate.currency))}</div>
           <button class="buy" data-sub="${esc(p.creatorID)}">Subscribe</button>
           <div class="tiny" style="color:#fff;opacity:.8">Opens every subscribers-only post</div></div>`
      : '';
  return `<article class="post">
    <div class="who">
      <div class="av">${esc(initials(p.creatorName))}</div>
      <div><a href="#/u/${encodeURIComponent(p.creatorID)}">${esc(p.creatorName)}</a><div class="when">${ago(p.createdAt)} ago</div></div>
    </div>
    <a class="shot ${locked ? 'locked' : ''}" href="#/s/${encodeURIComponent(p.id)}">${cover}${face}</a>
    <div class="body">
      <h2>${esc(p.title)}</h2>
      ${p.blurb ? `<div class="muted">${esc(p.blurb)}</div>` : ''}
      <div class="tiny" style="margin-top:6px">${p.subscribersOnly ? 'Subscribers' : (p.priceMinor ? esc(Money.label(p.priceMinor, p.currency)) : 'Free')} · ${p.itemCount} ${p.isVideo ? 'clip' : 'photo'}${p.itemCount === 1 ? '' : 's'}</div>
    </div>
  </article>`;
}

// ---- One post ----------------------------------------------------------------
async function setPage(id) {
  const set = store.sets(null).find(s => s.id === id);
  if (!set) return `<div class="empty">That post hasn't reached this browser.</div>`;
  const gate = store.gate(set, store.purchases(), store.subscriptions());
  const name = set.creatorName || store.name(set.creatorID);
  let inner;
  if (!gate || gate.kind !== 'open') {
    inner = `<div class="card">
      <h3>${gate?.kind === 'subscribe' ? 'Subscribers only' : 'Locked'}</h3>
      <p class="muted">${gate?.kind === 'subscribe'
        ? `A subscription to ${esc(name)} opens this and everything else they mark for subscribers.`
        : `${esc(name)} is selling this set for ${esc(Money.label(set.priceMinor, set.currency))}.`}</p>
      <button class="primary" ${gate?.kind === 'subscribe' ? `data-sub="${esc(set.creatorID)}"` : `data-buy="${esc(set.id)}"`}>
        ${gate?.kind === 'subscribe' ? `Subscribe · ${esc(Money.label(gate.priceMinor, gate.currency))}` : `Unlock · ${esc(Money.label(set.priceMinor, set.currency))}`}
      </button>
    </div>`;
  } else {
    const items = await store.items(set);
    inner = items === null
      ? `<div class="card"><h3>You have this, but not the key yet</h3>
           <p class="muted">The photos are sealed under a key only ${esc(name)}'s device hands out. It arrives the next time their app is online — this page will fill in by itself.</p></div>`
      : `<div class="grid">${items.map(i => i.url
          ? (i.kind === 'video' ? `<video src="${i.url}" controls playsinline></video>` : `<img src="${i.url}" alt="${esc(i.caption || '')}">`)
          : '').join('')}</div>`;
  }
  return `<div class="who" style="padding-left:0">
      <div class="av">${esc(initials(name))}</div>
      <div><a href="#/u/${encodeURIComponent(set.creatorID)}">${esc(name)}</a><div class="when">${ago(set.createdAt)} ago</div></div>
    </div>
    <h1 style="margin:6px 0 2px;font-size:22px">${esc(set.title)}</h1>
    ${set.blurb ? `<p class="muted" style="margin:0 0 14px">${esc(set.blurb)}</p>` : '<div style="height:12px"></div>'}
    ${inner}
    ${captureNote()}`;
}

// ---- A creator -----------------------------------------------------------------
async function creatorPage(id) {
  const prof = store.profile(id), plan = store.plan(id), links = store.links(id);
  const name = prof?.displayName || store.name(id);
  const sets = store.sets(id);
  const purchases = store.purchases(), subs = store.subscriptions();
  const subbed = subs.get(id) && subs.get(id).expiresAt > Date.now() / 1000;
  const free = sets.filter(s => !s.priceMinor && !s.subscribersOnly).length;
  const linkRow = links ? Object.entries(links).filter(([, v]) => v).map(([k, v]) =>
    `<span class="pill">${esc(k)} ${esc(v)}</span>`).join(' ') : '';
  return `<div class="card">
      <div class="row" style="gap:12px">
        <div class="av" style="width:54px;height:54px;font-size:19px">${esc(initials(name))}</div>
        <div><div style="font-size:19px;font-weight:700">${esc(name)}</div>
          <div class="tiny"><code>${esc(prof?.momentID || '')}</code></div></div>
      </div>
      ${prof?.bio ? `<p class="muted" style="margin:12px 0 0">${esc(prof.bio)}</p>` : ''}
      <div class="row tiny" style="margin-top:10px">
        <span>${sets.length} post${sets.length === 1 ? '' : 's'}</span><span>·</span>
        <span>${free} free</span><span>·</span><span>${sets.length - free} locked</span>
      </div>
      ${linkRow ? `<div class="row" style="margin-top:10px">${linkRow}</div>` : ''}
      ${plan ? `<div style="margin-top:14px">
        ${subbed
          ? `<div class="banner">Subscribed. Every subscribers-only post is open until ${new Date(subs.get(id).expiresAt * 1000).toLocaleDateString()}.</div>`
          : `<button class="primary" data-sub="${esc(id)}">Subscribe · ${esc(Money.label(plan.priceMinor, plan.currency))} / 30 days</button>
             <p class="tiny" style="margin:8px 0 0">${esc(plan.pitch || plan.title || '')}</p>`}
      </div>` : ''}
    </div>
    ${requestBlock(id, name)}
    ${sets.length ? sets.map(s => {
      const gate = store.gate(s, purchases, subs);
      return gate ? postCard({ ...s, gate, creatorName: name }) : '';
    }).join('') : `<div class="empty">Nothing published yet.</div>`}`;
}

/// The creator's rate card on their page: the same offers the app shows in a DM.
function requestBlock(id, name) {
  const offers = store.offers(id);
  const rows = offers.map(o => `<button class="offer-row" data-offer="${esc(o.id)}" data-creator="${esc(id)}">
      <span>${esc(KINDS[o.kind] || o.kind)}${o.minutes ? ` · ${o.minutes} min` : ''}</span>
      <span class="price">${esc(Money.label(o.priceMinor, o.currency))}</span>
    </button>`).join('');
  return `<div class="card">
      <h3>Ask ${esc(name.split(' ')[0] || name)} for something</h3>
      ${rows || `<p class="muted">They haven't listed prices. Ask anyway — they name one for your request.</p>`}
      <button class="offer-row" data-ask="${esc(id)}" style="margin-bottom:0">
        <span>Something else</span><span class="price">They name a price</span>
      </button>
    </div>`;
}

// ---- Discover: the grid, and finding someone by name or @handle ---------------------
let discoverQuery = '';

function discoverPage() {
  if (!relays().length) return noRelay();
  const results = store.searchCreators(discoverQuery);
  const search = `<div class="search">
      <span>🔍</span>
      <input id="creatorSearch" placeholder="Search name or @handle" value="${esc(discoverQuery)}" autocomplete="off">
    </div>`;
  if (!results.length) {
    return search + `<div class="empty"><p>${discoverQuery ? 'Nobody by that name.' : 'No creators yet.'}</p>
      <p class="tiny">${discoverQuery ? 'Try part of a display name instead of the handle.'
        : 'They appear as their posts reach the relays you are on.'}</p></div>`;
  }
  return search + `<div class="grid-creators">${results.map(creatorCard).join('')}</div>`;
}

function creatorCard(c) {
  const cover = c.cover
    ? `<img src="${c.cover}" alt="" loading="lazy">`
    : `<div style="width:100%;height:100%;background:linear-gradient(140deg,var(--accent),transparent)"></div>`;
  const price = c.plan ? `${esc(Money.label(c.plan.priceMinor, c.plan.currency))}/mo`
                       : (c.free ? `${c.free} free` : `${c.sets.length} post${c.sets.length === 1 ? '' : 's'}`);
  return `<a class="creator-card" href="#/u/${encodeURIComponent(c.id)}">
      <div class="top">${cover}<div class="av">${esc(initials(c.name))}</div></div>
      <div class="meta">
        <div class="nm">${esc(c.name)}</div>
        ${c.handle ? `<div class="hd">@${esc(c.handle)}</div>` : ''}
        <div class="pr">${price}</div>
      </div>
    </a>`;
}

// ---- Requests: ask for something, and watch what it costs --------------------------
const KINDS = {
  photo: 'A photo', videoCall: 'Video call', voiceCall: 'Voice call',
  meet: 'Meet in person', custom: 'Something else'
};
const STATUS_TEXT = {
  asked: 'Waiting for a price', quoted: 'Price offered', requested: 'Waiting on them',
  accepted: 'Confirmed', declined: 'Declined', done: 'Done', refunded: 'Refunded'
};

function requestsPage() {
  if (!relays().length) return noRelay();
  const all = store.bookings();
  const mine = all.filter(b => b.buyerID === Identity.author);
  const toMe = all.filter(b => b.creatorID === Identity.author);
  const head = (t) => `<h2 style="font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:4px 0 10px">${t}</h2>`;
  let out = '';
  if (toMe.length) out += head('Asked of you') + toMe.map(b => requestCard(b, true)).join('');
  out += head('You asked for');
  out += mine.length ? mine.map(b => requestCard(b, false)).join('')
    : `<div class="empty"><p>Nothing asked for yet.</p>
       <p class="tiny">Open a creator and ask for a photo, a call, or anything else. They name the price; you pay only if you accept it.</p></div>`;
  return out;
}

function requestCard(b, isCreator) {
  const who = isCreator ? b.buyerName : b.creatorName;
  const price = b.amountMinor ? Money.label(b.amountMinor, b.currency) : null;
  return `<div class="req">
      <div class="row" style="justify-content:space-between">
        <strong>${esc(KINDS[b.kind] || b.kind)}</strong>
        <span class="st ${esc(b.status)}">${esc(STATUS_TEXT[b.status] || b.status)}</span>
      </div>
      <div class="tiny" style="margin-top:3px">${esc(who || '')}${b.minutes ? ` · ${b.minutes} min` : ''}${price ? ` · ${esc(price)}` : ''}</div>
      ${b.note ? `<div class="muted" style="margin-top:6px">“${esc(b.note)}”</div>` : ''}
      ${!isCreator && b.status === 'quoted'
        ? `<div style="margin-top:10px"><button class="buy" data-accept="${esc(b.id)}">Accept ${esc(price)}</button></div>` : ''}
      ${isCreator && b.status === 'asked'
        ? `<div class="tiny" style="margin-top:8px">Name a price in the iPhone app — quoting isn't wired here yet.</div>` : ''}
    </div>`;
}

/// Publishes a `booking` event in the shape the app writes, so a request made here shows up there and
/// the other way round. Dates go out as seconds, which is what JSONEncoder.event does.
async function sendRequest(creatorID, creatorName, kind, note, offer) {
  const now = Math.floor(Date.now() / 1000);
  const booking = {
    id: 'bk_' + crypto.randomUUID(),
    offerID: offer ? offer.id : '',
    creatorID, creatorName: creatorName || 'Creator',
    buyerID: Identity.author,
    buyerName: localStorage.getItem('moment.profile.name') || 'You',
    kind: offer ? offer.kind : kind,
    minutes: offer ? offer.minutes : 0,
    amountMinor: offer ? offer.priceMinor : 0,
    currency: offer ? offer.currency : 'INR',
    startsAt: now + 86400,
    status: offer ? 'requested' : 'asked',
    note: note || '',
    rail: 'web',
    reference: null,
    roomID: '',
    createdAt: now,
    connectedAt: null,
    endedAt: null,
    extraMinutes: 0
  };
  await publish(await Events.make('booking', { booking: booking.id, to: creatorID }, JSON.stringify({ booking })));
  return booking;
}

// ---- What you've paid for --------------------------------------------------------
async function unlockedPage() {
  const purchases = store.purchases(), subs = store.subscriptions();
  const mine = store.sets(null).filter(s => purchases.has(s.id) || (s.subscribersOnly && subs.get(s.creatorID)?.expiresAt > Date.now() / 1000));
  if (!mine.length) return `<div class="empty"><p>Nothing unlocked yet.</p><p class="tiny">Sets you buy and subscriptions you take stay here, openable on any device that holds your key.</p></div>`;
  let out = '';
  for (const s of mine) {
    const items = await store.items(s);
    out += `<div class="card"><h3><a class="link" href="#/s/${encodeURIComponent(s.id)}" style="text-decoration:none">${esc(s.title)}</a></h3>
      <div class="tiny" style="margin-bottom:10px">${esc(s.creatorName || store.name(s.creatorID))}</div>
      ${items === null
        ? `<p class="muted">Waiting for the key from ${esc(s.creatorName || 'the creator')}'s device.</p>`
        : `<div class="grid">${items.slice(0, 6).map(i => i.url ? (i.kind === 'video'
            ? `<video src="${i.url}" playsinline muted></video>` : `<img src="${i.url}" alt="">`) : '').join('')}</div>`}
    </div>`;
  }
  return out;
}

// ---- You -------------------------------------------------------------------------
function youPage() {
  const list = relays();
  return `<div class="card">
      <h3>You</h3>
      <p class="tiny">This browser is an identity. There is no account and no password — the key below <em>is</em> you, and losing it loses the posts you've unlocked.</p>
      <label>Name</label>
      <input id="pname" value="${esc(localStorage.getItem('moment.profile.name') || '')}">
      <label>Bio</label>
      <input id="pbio" value="${esc(localStorage.getItem('moment.profile.bio') || '')}">
      <div style="height:12px"></div>
      <button class="primary" id="saveProfile">Save</button>
      <label>Your MOMENT ID</label>
      <code>${esc(myID)}</code>
    </div>

    <div class="card">
      <h3>Relays</h3>
      <p class="tiny">Open servers that pass signed events along. They can't read what you've paid for — the media is sealed under keys they never see. Run your own if you like.</p>
      ${list.length ? list.map(u => `<div class="row" style="justify-content:space-between;margin:8px 0">
          <code>${esc(u)}</code><button class="pill warn" data-delrelay="${esc(u)}">Remove</button></div>`).join('')
        : '<p class="muted">None yet.</p>'}
      <label>Add one</label>
      <input id="relayURL" placeholder="wss://relay.example.com">
      <div style="height:10px"></div>
      <button class="ghost" id="addRelay">Add relay</button>
    </div>

    <div class="card">
      <h3>Your key</h3>
      <p class="tiny">Copy this into another browser to be the same person there. Anyone who has it is you — treat it like a password you can never change.</p>
      <details><summary class="tiny" style="cursor:pointer">Show recovery seed</summary>
        <code style="display:block;margin-top:8px">${esc(Identity.exportSeed() || '')}</code></details>
      <label>Restore from a seed</label>
      <input id="seedIn" placeholder="paste a seed">
      <div style="height:10px"></div>
      <button class="ghost" id="restore">Replace this identity</button>
    </div>

    ${captureNote()}

    <div class="card">
      <h3>What this web app can't do</h3>
      <p class="tiny">Posting, selling, calls and chats are in the iPhone app. This is a reader: browse creators, unlock what you've paid for, and keep your identity. It also can't protect paid photos from screenshots the way iOS can — see above.</p>
    </div>`;
}

/// Said in every place paid media appears, because the honest answer differs from the app's.
function captureNote() {
  return `<div class="banner warn"><strong>Screenshots aren't blocked here.</strong> The iPhone app renders paid photos inside a system layer that comes out blank in screenshots and recordings. A browser has no such layer, so anything you open here can be captured. Creators: this is why the app is the safer place for your work.</div>`;
}

function noRelay() {
  return `<div class="banner">Add a relay to see anything. Relays are open servers anyone can run — <a class="link" href="#/you">You → Relays</a>.</div>
    <div class="card"><h3>What this is</h3>
      <p class="muted">MOMENT is a creator platform with no company server. Creators post sets — some free, some priced — and keep the keys. This browser speaks the same protocol as the iPhone app: the same signed events, the same sealed media.</p></div>`;
}

// ---- Actions ---------------------------------------------------------------------
function wire() {
  $('#saveProfile')?.addEventListener('click', async () => {
    localStorage.setItem('moment.profile.name', $('#pname').value.trim() || 'You');
    localStorage.setItem('moment.profile.bio', $('#pbio').value.trim());
    await publishProfile(); rerender();
  });
  $('#addRelay')?.addEventListener('click', () => {
    const u = $('#relayURL').value.trim();
    if (!/^wss?:\/\//.test(u)) return alert('A relay URL starts with wss:// or ws://');
    const list = relays(); if (!list.includes(u)) list.push(u);
    localStorage.setItem('moment.relays', JSON.stringify(list));
    relay = null; connect(); rerender();
  });
  document.querySelectorAll('[data-delrelay]').forEach(b => b.addEventListener('click', () => {
    localStorage.setItem('moment.relays', JSON.stringify(relays().filter(u => u !== b.dataset.delrelay)));
    location.reload();
  }));
  $('#restore')?.addEventListener('click', async () => {
    const s = $('#seedIn').value.trim(); if (!s) return;
    if (!confirm('Replace this identity? Anything unlocked under the current key becomes unreachable in this browser.')) return;
    await Identity.importSeed(s); location.reload();
  });
  document.querySelectorAll('[data-follow]').forEach(b => b.addEventListener('click', async () => {
    const id = b.dataset.follow, on = store.following().has(id);
    await publish(await Events.make(on ? 'unfollow' : 'follow', { to: id, close: '0' }, JSON.stringify({ ok: '1' })));
  }));
  const q = $('#creatorSearch');
  if (q) {
    q.addEventListener('input', () => { discoverQuery = q.value; rerenderDiscoverOnly(); });
    if (discoverQuery) { q.focus(); q.setSelectionRange(q.value.length, q.value.length); }
  }
  document.querySelectorAll('[data-offer]').forEach(b => b.addEventListener('click', async () => {
    const offer = store.offers(b.dataset.creator).find(o => o.id === b.dataset.offer);
    if (!offer) return;
    const note = prompt(`Anything they should know? (${KINDS[offer.kind] || offer.kind}, ${Money.label(offer.priceMinor, offer.currency)})`) ?? '';
    await sendRequest(b.dataset.creator, store.name(b.dataset.creator), offer.kind, note, offer);
    alert('Asked. It shows under Requests — nothing is charged until they confirm.');
    location.hash = '#/requests';
  }));
  document.querySelectorAll('[data-ask]').forEach(b => b.addEventListener('click', async () => {
    const note = prompt('What are you asking for?');
    if (!note) return;
    await sendRequest(b.dataset.ask, store.name(b.dataset.ask), 'custom', note, null);
    alert('Asked. They name a price; you pay only if you accept it.');
    location.hash = '#/requests';
  }));
  document.querySelectorAll('[data-accept]').forEach(b => b.addEventListener('click', () => payWall('request', b.dataset.accept)));
  document.querySelectorAll('[data-buy]').forEach(b => b.addEventListener('click', () => payWall('set', b.dataset.buy)));
  document.querySelectorAll('[data-sub]').forEach(b => b.addEventListener('click', () => payWall('subscription', b.dataset.sub)));
}

/// There is no payment processor wired anywhere in MOMENT yet — not in the app and not here.
/// Saying so is the only honest thing this button can do; pretending to charge would be worse than
/// not having the button.
function payWall(what, id) {
  const name = what === 'set' ? (store.sets(null).find(s => s.id === id)?.title || 'this post')
             : what === 'request' ? 'this request'
             : store.name(id);
  alert(`Checkout isn't wired up yet.\n\nNothing in MOMENT can take a payment right now — not this browser and not the iPhone app. When it is, this button will charge you for ${name} and the creator's device will hand your key straight to this browser.\n\nIf you've already paid on the app with this same key, it opens here by itself.`);
}

boot();
