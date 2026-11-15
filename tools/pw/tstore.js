// Galerie v úložišti appky (QNATIVE.store): podvržené /__st/… (jako GalleryStore + LocalServer, i s úklidem neodkazovaných souborů).
// Přesun z IndexedDB, úprava bez nového nahrání, klip přesunem (adopt), přehrání, export do Fotek, nové vyvolání, reload, smazání.  node tstore.js
const { chromium } = require('playwright-core');
(async () => {
  const sm = await chromium.launch({ channel: 'chrome' }), sp = await sm.newPage();
  const vid = Buffer.from(await sp.evaluate(async () => { const c = document.createElement('canvas'); c.width = 360; c.height = 640; const g = c.getContext('2d');
    const rec = new MediaRecorder(c.captureStream(30), { mimeType: 'video/webm' }), ch = []; rec.ondataavailable = e => ch.push(e.data);
    rec.start(); const t0 = performance.now(); await new Promise(r => { const f = () => { const t = (performance.now() - t0) / 1000; g.fillStyle = `hsl(${t * 90},60%,45%)`; g.fillRect(0, 0, 360, 640); if (t < 1.2) requestAnimationFrame(f); else r(); }; f(); });
    rec.stop(); await new Promise(r => rec.onstop = r); const b = new Blob(ch); return btoa(String.fromCharCode(...new Uint8Array(await b.arrayBuffer()))); }), 'base64');
  const jpg = Buffer.from(await sp.evaluate(() => { const c = document.createElement('canvas'); c.width = 1080; c.height = 1920; const g = c.getContext('2d'); g.fillStyle = '#5a8'; g.fillRect(0, 0, 1080, 1920); return c.toDataURL('image/jpeg', .9).split(',')[1]; }), 'base64');
  await sm.close();
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true, permissions: ['camera'] });
  // podvržené úložiště appky
  const recs = new Map(), files = new Map(), log = [];
  const cap = { 'k.mp4': vid, 'k2.mp4': vid };
  await c.route('**/__cap/*', r => { const n = r.request().url().split('/').pop(); r.fulfill({ body: n.endsWith('.jpg') ? jpg : vid, contentType: n.endsWith('.jpg') ? 'image/jpeg' : 'video/webm' }); });
  await c.route('**/__st/**', r => { const q = r.request(), u = new URL(q.url()), m = q.method(), rest = decodeURIComponent(u.pathname.slice(6)); log.push(m + ' ' + rest.split('-').slice(0, 2).join('-'));
    const js = o => r.fulfill({ body: JSON.stringify(o), contentType: 'application/json' });
    if (rest === 'list') return r.fulfill({ body: '[' + [...recs.values()].join(',') + ']', contentType: 'application/json' });
    if (rest.startsWith('rec/') && m === 'PUT') { const id = rest.slice(4), t = q.postData(); JSON.parse(t); recs.set(id, t);
      for (const n of [...files.keys()]) if (n.startsWith(id + '-') && !t.includes('"' + n + '"')) files.delete(n); return js({ ok: true }); }
    if (rest.startsWith('f/')) { const n = rest.slice(2); if (m === 'PUT') { const d = q.postDataBuffer() || Buffer.alloc(0); files.set(n, d); return js({ ok: true, n: d.length }); }
      if (!files.has(n)) return r.fulfill({ status: 404, body: '404' }); return r.fulfill({ body: files.get(n), contentType: n.endsWith('.mp4') ? 'video/webm' : n.endsWith('.png') ? 'image/png' : 'image/jpeg' }); }
    if (rest === 'adopt') { const f = u.searchParams.get('from'), t = u.searchParams.get('to'); if (!cap[f]) return r.fulfill({ status: 404, body: '{}' }); files.set(t, cap[f]); delete cap[f]; return js({ ok: true, n: files.get(t).length }); }
    if (rest.startsWith('del/')) { const id = rest.slice(4); recs.delete(id); for (const n of [...files.keys()]) if (n.startsWith(id + '-')) files.delete(n); return js({ ok: true }); }
    r.fulfill({ status: 400, body: '' }); });
  const errs = [];
  // A) bez úložiště appky: fotka do IndexedDB (jako dřív)
  const pa = await c.newPage(); pa.on('pageerror', e => errs.push(e.message));
  await pa.goto('http://localhost:8765/docs/preview/#nahled'); await pa.waitForTimeout(3000);
  await pa.evaluate(() => { const P = DEF(); P.film = 'P400'; keep(addPhoto(drawScene('les', 720, 960, 5), P, 'import', ['import'], true, uid())); }); await pa.waitForTimeout(1500);
  console.log('A IndexedDB', await pa.evaluate(() => idbAll().then(a => a.length)));
  await pa.close();
  // B) appka s úložištěm
  const p = await c.newPage(); p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => {
    window.QNATIVE = { store: 1, raw: 2, clip: 1, cedit: 1 }; window.__msgs = [];
    window.__qSaveStored = name => { window.__msgs.push('shareStored ' + name.split('-')[1]); return Promise.resolve(); };
    window.webkit = { messageHandlers: { qamera: { postMessage: m => { window.__msgs.push(m.kind + (m.kind === 'rawDone' ? ':' + m.files.join(',') : ''));
      if (m.kind === 'clip' && !m.src) { setTimeout(() => window.__qClipRec(m.id), 300); setTimeout(() => window.__qClip(m.id, true, { mp4: '/__cap/k.mp4', jpg: '/__cap/k.jpg', log: true, lensZoom: 1, src: 'S1' }), 5600); }
      if (m.kind === 'clip' && m.src) setTimeout(() => window.__qClip(m.id, true, { mp4: '/__cap/k2.mp4', jpg: '/__cap/k.jpg', log: true }), 500); } } } };
  });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const fl = () => [...files.keys()].map(n => n.split('-')[1]).sort().join(',');
  console.log('B přesun: záznamy', recs.size, 'soubory', fl(), 'IndexedDB', await p.evaluate(() => idbAll().then(a => a.length)), 'fotka odkaz', await p.evaluate(() => { const ph = S.photos.find(x => x.saved); return ph && isRef(ph.blob); }));
  // úprava: jen záznam, data znovu nenahrávat
  const nf = files.size; log.length = 0;
  await p.evaluate(() => { const ph = S.photos.find(x => x.saved); ph.P.exp = 1; return dbPut(ph); });
  console.log('úprava: soubory', nf, '→', files.size, 'požadavky', log.join(' | '), 'exp v záznamu', JSON.parse([...recs.values()][0]).P.exp);
  // fotka jde načíst v plné velikosti (originál z appky)
  console.log('plná', await p.evaluate(async () => { const ph = S.photos.find(x => x.saved); ph._full = false; await ensureFull(ph); return [ph.src.width, ph.src.height]; }));
  // klip
  await p.evaluate(() => liveOn()); await p.waitForTimeout(1500);
  await p.evaluate(() => { setFilm('P400C'); $('#tClip').click(); }); await p.waitForTimeout(400);
  await p.evaluate(() => __qShutter());
  for (let i = 0; i < 40; i++) { await p.waitForTimeout(400); if (await p.evaluate(() => !S.busy && S.photos[0] && S.photos[0].clip)) break; }
  await p.waitForTimeout(1500);
  console.log('klip', JSON.stringify(await p.evaluate(() => { const ph = S.photos[0]; return { ref: isRef(ph.clip), n: ph.clip.n, csrc: ph.csrc, msgs: __msgs.filter(m => m.startsWith('rawDone')) }; })), 'soubory', fl());
  await p.evaluate(() => go('gallery')); await p.waitForTimeout(1000);
  await p.evaluate(() => document.querySelector('.gitem').click()); await p.waitForTimeout(1500);
  console.log('přehrání', await p.evaluate(() => { const v = $('.clipv video'); return v && [v.src.replace(location.origin, '').slice(0, 14), v.readyState, v.videoWidth]; }));
  await p.evaluate(() => exportClip(S.photos[0])); console.log('export', await p.evaluate(() => __msgs.filter(m => m.startsWith('share'))));
  await p.evaluate(() => $('.clipv [data-a="x"]').click()); await p.waitForTimeout(400);
  // nové vyvolání z originálu: nový soubor, starý se uklidí
  const c0 = [...files.keys()].find(n => n.includes('-clip-'));
  await p.evaluate(() => redevelopClip(S.photos[0], 'P800C')); await p.waitForTimeout(800);
  const c1 = [...files.keys()].filter(n => n.includes('-clip-'));
  console.log('nové vyvolání: klipů', c1.length, 'jiný soubor', c1[0] !== c0, 'film', await p.evaluate(() => S.photos[0].P.cf));
  // reload: vše z appky
  await p.reload(); await p.waitForTimeout(4500);
  console.log('reload', JSON.stringify(await p.evaluate(() => S.photos.filter(x => x.saved).map(x => [x.kind, x.film, x.src.width, isRef(x.blob), x.clip ? isRef(x.clip) : null]))));
  // smazání
  const id = await p.evaluate(() => S.photos.find(x => x.saved && !x.clip).id);
  await p.evaluate(id => dbDel(id), id); await p.waitForTimeout(300);
  console.log('smazání: záznamy', recs.size, 'soubory', fl());
  console.log('chyby', errs);
  await b.close();
})();
