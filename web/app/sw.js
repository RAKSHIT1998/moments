// Offline shell: the app's own files. Events are never cached here — they live in the page and on your relays.
const CACHE = 'moment-web-v1';
const FILES = ['./', './index.html', './app.js', './moment.js', './manifest.webmanifest', '../logo.png'];
self.addEventListener('install', e => e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES))));
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))));
self.addEventListener('fetch', e => { if (e.request.method !== 'GET') return; e.respondWith(caches.match(e.request).then(r => r || fetch(e.request))); });
