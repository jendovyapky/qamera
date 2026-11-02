// RAW z appky: podvržený nativní most (window.QNATIVE + webkit.messageHandlers) vrátí buď hotový JPEG + mapu světel + hloubku
// (node tnraw.js jpg), nebo DNG, který web vyvolá sám (node tnraw.js C:\cesta\k\souboru.dng – osobní fotky jen lokálně, nikdy necommitovat)
const { chromium } = require('playwright-core');
const fs = require('fs');
(async () => {
  const arg = process.argv[2]; if (!arg) { console.log('node tnraw.js jpg | <DNG>'); return; }
  const jpg = arg === 'jpg', ans = jpg ? { jpg: '/__cap/t.jpg', hl: '/__cap/t-hl.png', depth: '/__cap/t-d.png', label: 'ProRAW', lensZoom: 1, ev: 1 } : { dng: '/__cap/t.dng', label: 'RAW', lensZoom: 1, ev: 0 };
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, permissions: ['camera'] }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  const sm = await chromium.launch({ channel: 'chrome' }), sp = await sm.newPage();
  const mkImg = (w, h, f) => sp.evaluate(([w, h, f]) => { const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d');
    if (f === 'jpg') { const gr = g.createLinearGradient(0, 0, w, h); gr.addColorStop(0, '#244'); gr.addColorStop(1, '#fc8'); g.fillStyle = gr; g.fillRect(0, 0, w, h); g.fillStyle = '#fff'; g.beginPath(); g.arc(w * .7, h * .3, w * .05, 0, 7); g.fill(); }
    else if (f === 'hl') { g.fillStyle = '#000'; g.fillRect(0, 0, w, h); g.fillStyle = '#fff'; g.beginPath(); g.arc(w * .7, h * .3, w * .05, 0, 7); g.fill(); }
    else { const gr = g.createLinearGradient(0, h, 0, 0); gr.addColorStop(0, '#fff'); gr.addColorStop(1, '#000'); g.fillStyle = gr; g.fillRect(0, 0, w, h); }
    return c.toDataURL(f === 'jpg' ? 'image/jpeg' : 'image/png', .9).split(',')[1]; }, [w, h, f]).then(b => Buffer.from(b, 'base64'));
  const files = jpg ? { 't.jpg': await mkImg(3024, 4032, 'jpg'), 't-hl.png': await mkImg(384, 512, 'hl'), 't-d.png': await mkImg(240, 320, 'd') } : { 't.dng': fs.readFileSync(arg) };
  await sm.close();
  await p.route('**/__cap/*', r => { const n = r.request().url().split('/').pop(); r.fulfill({ body: files[n], contentType: 'application/octet-stream' }); });
  await p.addInitScript(() => {
    window.QNATIVE = { raw: 2 }; window.__msgs = [];
    window.webkit = { messageHandlers: { qamera: { postMessage: m => { window.__msgs.push(m.kind === 'rawDone' ? 'rawDone:' + m.files.length : m.kind);
      if (m.kind === 'raw') setTimeout(() => window.__qRaw(m.id, true, window.__ans), 400); } } } };
  });
  await p.addInitScript(a => { window.__ans = a; }, ans);
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  console.log('tlacitko RAW', await p.evaluate(() => !$('#tRaw').hidden));
  await p.evaluate(() => $('#tRaw').click()); await p.waitForTimeout(300);
  await p.evaluate(() => liveOn()); await p.waitForTimeout(2000);
  console.log('live', await p.evaluate(() => [CAM.live, S.nraw, nativeRawOk()]));
  await p.screenshot({ path: 'nraw_cam.png' });
  const n0 = await p.evaluate(() => S.photos.length);
  await p.evaluate(() => __qShutter()); await p.waitForTimeout(250);
  console.log('busy', await p.evaluate(() => [S.busy, !!CAM.stream]));
  for (let i = 0; i < 60; i++) { await p.waitForTimeout(500); if (await p.evaluate(() => !S.busy)) break; }
  const r = await p.evaluate(n0 => { const ph = S.photos[0]; return { pridano: S.photos.length - n0, raw: ph.raw, tags: ph.tags, src: [ph.src.width, ph.src.height], hl: !!ph.hl, depth: ph.depth && [ph.depth.width, ph.depth.height], dFocus: ph.dFocus, depthBlob: !!ph.depthBlob, blob: ph.blob && ph.blob.size, live: CAM.live && !!CAM.stream, msgs: __msgs }; }, n0);
  console.log(JSON.stringify(r));
  await p.waitForTimeout(800); await p.screenshot({ path: 'nraw_after.png' });
  await p.evaluate(() => { openEditor(S.photos[0]); }); await p.waitForTimeout(2500); await p.screenshot({ path: 'nraw_editor.png' });
  // úklid testovací fotky
  await p.evaluate(async () => { const id = S.photos[0].id; await dbDel(id); });
  console.log('errors', errs);
  await b.close();
})();
