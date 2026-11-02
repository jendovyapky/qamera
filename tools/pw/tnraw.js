// RAW z appky: podvržený nativní most (window.QNATIVE + webkit.messageHandlers) vrátí DNG, web ho vyvolá a uloží jako fotku
// node tnraw.js C:\cesta\k\souboru.dng   (osobní fotky jen lokálně, nikdy necommitovat)
const { chromium } = require('playwright-core');
const fs = require('fs');
(async () => {
  const dng = process.argv[2]; if (!dng) { console.log('chybí cesta k DNG'); return; }
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, permissions: ['camera'] }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__cap/test.dng', r => r.fulfill({ body: fs.readFileSync(dng), contentType: 'application/octet-stream' }));
  await p.addInitScript(() => {
    window.QNATIVE = { raw: true }; window.__msgs = [];
    window.webkit = { messageHandlers: { qamera: { postMessage: m => { window.__msgs.push(m.kind);
      if (m.kind === 'raw') setTimeout(() => window.__qRaw(m.id, true, '/__cap/test.dng', 'ProRAW', 1), 400); } } } };
  });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  console.log('tlacitko RAW', await p.evaluate(() => !$('#tRaw').hidden));
  await p.evaluate(() => $('#tRaw').click()); await p.waitForTimeout(300);
  await p.evaluate(() => liveOn()); await p.waitForTimeout(2000);
  console.log('live', await p.evaluate(() => [CAM.live, S.nraw, nativeRawOk()]));
  await p.screenshot({ path: 'nraw_cam.png' });
  const n0 = await p.evaluate(() => S.photos.length);
  await p.evaluate(() => shoot()); await p.waitForTimeout(250);
  console.log('busy', await p.evaluate(() => [S.busy, !!CAM.stream]));
  for (let i = 0; i < 60; i++) { await p.waitForTimeout(500); if (await p.evaluate(() => !S.busy)) break; }
  const r = await p.evaluate(n0 => { const ph = S.photos[0]; return { pridano: S.photos.length - n0, raw: ph.raw, tags: ph.tags, src: [ph.src.width, ph.src.height], hl: !!ph.hl, blob: ph.blob && ph.blob.size, live: CAM.live && !!CAM.stream, msgs: __msgs }; }, n0);
  console.log(JSON.stringify(r));
  await p.waitForTimeout(800); await p.screenshot({ path: 'nraw_after.png' });
  await p.evaluate(() => { openEditor(S.photos[0]); }); await p.waitForTimeout(2500); await p.screenshot({ path: 'nraw_editor.png' });
  // úklid testovací fotky
  await p.evaluate(async () => { const id = S.photos[0].id; await dbDel(id); });
  console.log('errors', errs);
  await b.close();
})();
