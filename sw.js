/* Qamera service worker – appka funguje i offline. Po větší změně zvýšit VERSION, ať se telefonům stáhne nová verze. */
const VERSION = 'qamera-0.16.1';
const SHELL = ['./', './docs/preview/', './docs/preview/index.html', './manifest.webmanifest', './icons/icon.svg', './icons/icon-192.png', './icons/apple-touch-icon.png', './luts/films.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== location.origin) return; // model hloubky a knihovny z CDN si cachuje prohlížeč / transformers.js
  if (req.mode === 'navigate' || url.pathname.endsWith('.html')) { // stránky: nejdřív síť (nová verze), bez sítě z cache
    e.respondWith(fetch(req).then(r => { const cp = r.clone(); caches.open(VERSION).then(c => c.put(req, cp)); return r; }).catch(() => caches.match(req).then(r => r || caches.match('./docs/preview/'))));
    return;
  }
  e.respondWith(caches.match(req).then(hit => { // ostatní (LUT, ikony, fonty z vlastního webu): z cache, na pozadí obnovit
    const net = fetch(req).then(r => { if (r.ok) { const cp = r.clone(); caches.open(VERSION).then(c => c.put(req, cp)); } return r; }).catch(() => hit);
    return hit || net;
  }));
});
