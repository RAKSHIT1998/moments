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
    if (['vaultSet', 'plan', 'profile', 'vaultBuy', 'subscribe', 'follow', 'unfollow', 'links', 'vaultKey'].includes(e.kind)) schedule();
  });
  relay.onStatus = () => { const n = relay.connected; $('#relayStatus').textContent = n ? `${n} relay${n > 1 ? 's' : ''}` : 'connecting…'; };
  relay.connect();
  // Everything this client needs: who people are, what they sell, and anything addressed to me.
  relay.subscribe('world', { kinds: ['profile', 'vaultSet', 'plan', 'links'] });
  relay.subscribe('mine', { authors: [Identity.author] });
  relay.subscribe('forme', { kinds: ['vaultKey', 'grant'], '#to': [Identity.author] });
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
  relay.publish(await Events.make('profile', {}, JSON.stringify(p)));
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
  else if (h.startsWith('#/creators')) v.innerHTML = creatorsPage();
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
    ${sets.length ? sets.map(s => {
      const gate = store.gate(s, purchases, subs);
      return gate ? postCard({ ...s, gate, creatorName: name }) : '';
    }).join('') : `<div class="empty">Nothing published yet.</div>`}`;
}

// ---- Creators this browser knows -------------------------------------------------
function creatorsPage() {
  if (!relays().length) return noRelay();
  const ids = store.creators().filter(id => id !== Identity.author);
  if (!ids.length) return `<div class="empty"><p>No creators yet.</p><p class="tiny">They appear as their posts reach the relays you're on.</p></div>`;
  const following = store.following();
  return ids.map(id => {
    const name = store.name(id), plan = store.plan(id), n = store.sets(id).length;
    return `<div class="card"><div class="row" style="justify-content:space-between">
      <a href="#/u/${encodeURIComponent(id)}" style="text-decoration:none;color:inherit" class="row">
        <div class="av" style="width:40px;height:40px">${esc(initials(name))}</div>
        <div><div style="font-weight:650">${esc(name)}</div>
          <div class="tiny">${n} post${n === 1 ? '' : 's'}${plan ? ` · ${esc(Money.label(plan.priceMinor, plan.currency))}/mo` : ''}</div></div>
      </a>
      <button class="pill ${following.has(id) ? 'on' : ''}" data-follow="${esc(id)}">${following.has(id) ? 'Following' : 'Follow'}</button>
    </div></div>`;
  }).join('');
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
    relay?.publish(await Events.make(on ? 'unfollow' : 'follow', { to: id, close: '0' }, JSON.stringify({ ok: '1' })));
    setTimeout(rerender, 120);
  }));
  document.querySelectorAll('[data-buy]').forEach(b => b.addEventListener('click', () => payWall('set', b.dataset.buy)));
  document.querySelectorAll('[data-sub]').forEach(b => b.addEventListener('click', () => payWall('subscription', b.dataset.sub)));
}

/// There is no payment processor wired anywhere in MOMENT yet — not in the app and not here.
/// Saying so is the only honest thing this button can do; pretending to charge would be worse than
/// not having the button.
function payWall(what, id) {
  const name = what === 'set'
    ? (store.sets(null).find(s => s.id === id)?.title || 'this post')
    : store.name(id);
  alert(`Checkout isn't wired up yet.\n\nNothing in MOMENT can take a payment right now — not this browser and not the iPhone app. When it is, this button will charge you for ${name} and the creator's device will hand your key straight to this browser.\n\nIf you've already paid on the app with this same key, the post opens here by itself.`);
}

boot();
