import { Identity, Events, Keys, Geo, Relay, Store } from './moment.js';

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const img = (b64) => b64 ? `data:image/jpeg;base64,${b64}` : '';
const store = new Store();
let relay = null, me = null, myID = '', loc = null;
const relays = () => JSON.parse(localStorage.getItem('moment.relays') || '[]');

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
  relay = new Relay(urls, (e) => { store.ingest(e); if (['moment', 'now', 'contribution', 'join', 'profile'].includes(e.kind)) rerender(); });
  relay.onStatus = () => { const n = relay.connected; $('#relayStatus').textContent = n ? `${n} relay${n > 1 ? 's' : ''}` : 'connecting…'; };
  relay.connect();
  relay.subscribe('me', { authors: [Identity.author] });
  publishProfile();
}
async function publishProfile() {
  if (!relay) return;
  const p = { displayName: localStorage.getItem('moment.profile.name') || 'You', handle: '', bio: '', privateAccount: false, momentID: myID, agreePK: Identity.agreePK };
  relay.publish(await Events.make('profile', {}, JSON.stringify(p)));
}
async function locate() {
  if (loc) return loc;
  return new Promise((res) => navigator.geolocation.getCurrentPosition(p => { loc = { lat: p.coords.latitude, lon: p.coords.longitude }; res(loc); }, () => res(null), { timeout: 8000 }));
}

let current = '';
function route() {
  const h = location.hash || '#/tonight'; current = h;
  document.querySelectorAll('nav.tabs a').forEach(a => a.classList.toggle('on', h.startsWith('#/' + a.dataset.tab)));
  rerender();
}
async function rerender() {
  const h = current, v = $('#view');
  if (h.startsWith('#/m/')) return v.innerHTML = await momentPage(h.slice(4));
  if (h.startsWith('#/now')) return v.innerHTML = nowPage();
  if (h.startsWith('#/new')) return v.innerHTML = newPage();
  if (h.startsWith('#/settings')) return v.innerHTML = settingsPage();
  v.innerHTML = await tonightPage();
}

// ---- Tonight: public Moments + NOW in the cells around you ---------------------
async function tonightPage() {
  if (!relays().length) return `<div class="banner">Add a relay to see what's happening. Relays are open servers anyone can run — <a href="#/settings">Settings → Relays</a>.</div>` + about();
  const l = await locate();
  if (l && relay) relay.subscribe('geo', { kinds: ['moment', 'now'], geo: Geo.cells(l.lat, l.lon, 5) });
  const moments = [];
  for (const e of store.kind('moment').reverse()) { if (e.tags.vis !== 'publicAll' && e.tags.vis !== 'subscribers') continue; const m = await store.moment(e.id); if (m) moments.push(m); }
  const nows = store.nows().filter(x => x.p.activity && x.p.activity !== 'none');
  let html = `<h1 style="margin:6px 0 14px">Tonight${l ? ' near you' : ''}</h1>`;
  if (!l) html += `<div class="banner">Allow location to see the Moments and NOW posts around you. Your position never leaves this browser — it only picks which 0.1° cells to ask relays for.</div>`;
  if (nows.length) html += `<div class="row" style="margin-bottom:14px">${nows.map(x => `<span class="pill">⚡ ${esc(x.p.authorName)} · ${esc(x.p.text || x.p.activity)}</span>`).join('')}</div>`;
  if (!moments.length) html += `<div class="banner">Nothing yet. ${relay?.connected ? 'When someone near you makes a public Moment, it appears here.' : 'Connecting to relays…'}</div>`;
  for (const m of moments) html += momentCard(m);
  return html;
}
function momentCard(m) {
  return `<a class="card" href="#/m/${m.id}" style="display:block;color:inherit;text-decoration:none">
    ${m.cover ? `<img class="cover" src="${img(m.cover)}" alt="">` : ''}
    ${m.locked ? `<div class="lock">🔒 <b>For subscribers</b><span class="muted">Open in the app to subscribe</span></div>` : ''}
    <div class="body"><h2>${esc(m.title)}</h2><div class="muted">${m.isLive ? '<span class="live">● Live</span> · ' : ''}${m.members.length} ${m.members.length === 1 ? 'person' : 'people'}${m.place ? ' · ' + esc(m.place.name) : ''} · ${new Date(m.createdAt * 1000).toLocaleDateString()}</div></div></a>`;
}

// ---- A Moment (public, or private via an invite link with the key in the fragment) ----
async function momentPage(id) {
  const [mid, key] = id.split('#');
  if (key) Keys.save(mid, key.replace(/-/g, '+').replace(/_/g, '/'));
  if (relay) relay.subscribe('m.' + mid.slice(0, 8), { moments: [mid] });
  const m = await store.moment(mid);
  if (!m) return `<div class="banner">Looking for this Moment on your relays… If it was shared by someone nearby, it may only exist on their phone until they're online.</div>`;
  const joined = (store.byMoment.get(mid) || []).some(e => e.kind === 'join' && e.author === Identity.author) || m.creator === Identity.author;
  return `<a class="pill" href="#/tonight">← Back</a>
    <div class="card" style="margin-top:12px">${m.cover ? `<img class="cover" src="${img(m.cover)}" alt="">` : ''}${m.locked ? `<div class="lock">🔒 <b>${m.visibility === 'subscribers' ? 'For subscribers' : 'Private'}</b><span class="muted">${m.visibility === 'subscribers' ? 'Subscribe in the app' : 'You need the invite link with its key'}</span></div>` : ''}
    <div class="body"><h2>${esc(m.title)}</h2><div class="muted">${esc(m.creatorName)} · ${m.members.length} people${m.place ? ' · ' + esc(m.place.name) : ''}</div>${m.description ? `<p>${esc(m.description)}</p>` : ''}
    ${!m.locked ? (joined ? `<p class="muted">You're in this Moment.</p>` : `<button class="primary" onclick="window.join('${mid}')">I was there</button>`) : ''}
    </div></div>
    ${m.sides.length ? `<h3>Everyone's sides</h3><div class="grid">${m.sides.map(s => s.media ? `<div class="side"><img src="${img(s.media)}" alt=""><span>${esc(s.author)}</span></div>` : `<div class="card body" style="grid-column:1/-1;padding:12px">“${esc(s.caption)}” <span class="muted">— ${esc(s.author)}</span></div>`).join('')}</div>` : (!m.locked ? `<p class="muted">No sides yet.</p>` : '')}
    ${!m.locked && joined ? sideForm(mid) : ''}
    <p class="muted" style="margin-top:20px">Open in the app: <code>moment://moment/${mid}</code></p>`;
}
function sideForm(mid) {
  return `<div class="card" style="margin-top:14px"><div class="body"><h3 style="margin-top:0">Add your side</h3>
    <label>Photo</label><input type="file" id="sidePhoto" accept="image/*"><label>Caption</label><input id="sideCaption" placeholder="What was this?">
    <button class="primary" style="margin-top:12px" onclick="window.addSide('${mid}')">Add</button></div></div>`;
}
window.join = async (mid) => {
  const m = await store.moment(mid); if (!m || !relay) return;
  const name = localStorage.getItem('moment.profile.name') || 'You';
  let content = JSON.stringify({ name }), tags = { moment: mid };
  if (m.key) { content = await Keys.seal(m.key, content); tags.enc = '1'; }
  const e = await Events.make('join', tags, content); store.ingest(e); relay.publish(e); rerender();
};
window.addSide = async (mid) => {
  const m = await store.moment(mid); if (!m || !relay) return;
  const f = $('#sidePhoto').files[0]; const caption = $('#sideCaption').value.trim();
  const media = f ? await shrink(f, 1280) : null;
  const body = { kind: media ? 'photo' : 'text', caption, media, mediaKind: media ? 'photo' : null, originalTimestamp: Math.floor(Date.now() / 1000), authorName: localStorage.getItem('moment.profile.name') || 'You' };
  let content = JSON.stringify(body), tags = { moment: mid };
  if (m.key) { content = await Keys.seal(m.key, content); tags.enc = '1'; }
  const e = await Events.make('contribution', tags, content); store.ingest(e); relay.publish(e); rerender();
};
async function shrink(file, side) {
  const bmp = await createImageBitmap(file); const s = Math.min(1, side / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas'); c.width = Math.round(bmp.width * s); c.height = Math.round(bmp.height * s);
  c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
  return c.toDataURL('image/jpeg', 0.82).split(',')[1];   // EXIF is dropped by re-encoding
}

// ---- NOW ------------------------------------------------------------------------
function nowPage() {
  const nows = store.nows();
  return `<h1 style="margin:6px 0 14px">NOW</h1>
    <div class="card"><div class="body"><label>What are you up for?</label><select id="nowAct">${['coffee', 'drinks', 'food', 'drive', 'beach', 'exploring', 'chilling'].map(a => `<option>${a}</option>`).join('')}</select>
    <label>Say something</label><input id="nowText" placeholder="Anyone out?"><button class="primary amber" style="margin-top:12px" onclick="window.postNow()">Post · gone in 4 hours</button></div></div>
    ${nows.map(x => `<div class="card"><div class="body"><b>${esc(x.p.authorName)}</b> <span class="muted">${x.p.activity && x.p.activity !== 'none' ? 'is up for ' + esc(x.p.activity) : ''}</span><div>${esc(x.p.text)}</div></div></div>`).join('') || '<p class="muted">Nobody yet.</p>'}`;
}
window.postNow = async () => {
  if (!relay) return alert('Add a relay first.');
  const l = await locate(); const exp = Math.floor(Date.now() / 1000) + 4 * 3600;
  const p = { text: $('#nowText').value.trim(), media: null, expiresAt: exp, coarsePlace: null, activity: $('#nowAct').value, place: l ? { id: `here_${Math.round(l.lat * 1000)}_${Math.round(l.lon * 1000)}`, name: 'Nearby', area: '', latitude: l.lat, longitude: l.lon, category: null } : null, authorName: localStorage.getItem('moment.profile.name') || 'You' };
  const tags = { exp: String(exp), disc: '1' }; if (l) { tags.geo = Geo.cell(l.lat, l.lon); tags.place = p.place.id; }
  const e = await Events.make('now', tags, JSON.stringify(p)); store.ingest(e); relay.publish(e); rerender();
};

// ---- Create a public Moment --------------------------------------------------------
function newPage() {
  return `<h1 style="margin:6px 0 14px">New Moment</h1><div class="card"><div class="body">
    <label>Title</label><input id="mTitle" placeholder="Rooftop Friday"><label>Cover photo</label><input type="file" id="mCover" accept="image/*">
    <label>A line</label><input id="mDesc" placeholder="Optional">
    <p class="muted">Web Moments are public and carry your approximate cell so people nearby find them. Private (invite-only) Moments are made in the app.</p>
    <button class="primary" onclick="window.createMoment()">Create</button></div></div>`;
}
window.createMoment = async () => {
  if (!relay) return alert('Add a relay first.');
  const l = await locate(); const f = $('#mCover').files[0];
  const p = { title: $('#mTitle').value.trim() || 'Untitled', description: $('#mDesc').value.trim(), startAt: null, endAt: null, locationName: null, coarsePlace: null, visibility: 'publicAll', templateID: null, remixedFromID: null, isLive: false, cover: f ? await shrink(f, 720) : null, isTeaser: false, place: null, creatorName: localStorage.getItem('moment.profile.name') || 'You' };
  const tags = { vis: 'publicAll' }; if (l) tags.geo = Geo.cell(l.lat, l.lon);
  const e = await Events.make('moment', tags, JSON.stringify(p)); store.ingest(e); relay.publish(e); location.hash = '#/m/' + e.id;
};

// ---- Settings: identity, relays --------------------------------------------------
function settingsPage() {
  return `<h1 style="margin:6px 0 14px">You</h1>
    <div class="card"><div class="body"><div class="muted">Your MOMENT ID</div><h2><code>${myID}</code></h2>
    <label>Name</label><input id="pName" value="${esc(localStorage.getItem('moment.profile.name') || 'You')}"><button class="primary" style="margin-top:12px" onclick="window.saveName()">Save</button>
    <p class="muted">Your identity is a key in this browser. Back it up: <button class="pill" onclick="window.exportSeed()">Copy secret</button> · <button class="pill" onclick="window.importSeed()">Restore</button></p></div></div>
    <div class="card"><div class="body"><h3 style="margin-top:0">Relays</h3>
    ${relays().map(u => `<div class="row" style="justify-content:space-between;margin-bottom:6px"><code>${esc(u)}</code><button class="pill" onclick="window.removeRelay('${esc(u)}')">Remove</button></div>`).join('') || '<p class="muted">None yet.</p>'}
    <input id="relayUrl" placeholder="wss://relay.example.org"><button class="primary" style="margin-top:10px" onclick="window.addRelay()">Add relay</button>
    <p class="muted">Relays are dumb, open servers anyone can run (see <code>relay/</code> in the source). They store signed events and can't read private Moments.</p></div></div>
    ${about()}`;
}
function about() { return `<div class="banner">MOMENT Web talks the same protocol as the iPhone app: your identity is an Ed25519 key, every action is a signed event, and private Moments are AES‑GCM sealed with a key that only travels inside the invite link. No account, no server of ours, nothing collected. <a href="../">About MOMENT</a></div>`; }
window.saveName = () => { localStorage.setItem('moment.profile.name', $('#pName').value.trim() || 'You'); publishProfile(); rerender(); };
window.addRelay = () => { const u = $('#relayUrl').value.trim(); if (!/^wss?:\/\//.test(u)) return alert('Use ws:// or wss://'); localStorage.setItem('moment.relays', JSON.stringify([...new Set([...relays(), u])])); relay = null; connect(); rerender(); };
window.removeRelay = (u) => { localStorage.setItem('moment.relays', JSON.stringify(relays().filter(x => x !== u))); location.reload(); };
window.exportSeed = async () => { await navigator.clipboard.writeText(Identity.exportSeed()); alert('Copied. Keep it somewhere safe — it is your identity.'); };
window.importSeed = async () => { const s = prompt('Paste your secret'); if (s) { await Identity.importSeed(s.trim()); location.reload(); } };

boot();
