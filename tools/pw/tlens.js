// Objektivy: tlačítka 4× / 8× podle QNATIVE.tele (iOS appka), přepnutí na kameru „tele“ a tele v RAW mostu
// node tlens.js  → lens_bar.png (lišta s tlačítky), výpis stavů
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true, permissions: ['camera'] });
  const p = await c.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => { window.QNATIVE = { raw: 2, bayer: true, tele: 4, teleCrop: true }; window.__msgs = [];
    window.webkit = { messageHandlers: { qamera: { postMessage: m => window.__msgs.push(m) } } }; });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  console.log('tlacitka', await p.evaluate(() => $$('#zoomGrp button').map(b => b.textContent)));
  const r = await p.evaluate(() => { const g = $('#zoomGrp').getBoundingClientRect(), v = $('#zoomGrp').closest('.vf') || document.body, w = v.getBoundingClientRect(); return { g: [g.x, g.y, g.width, g.height], vf: [w.x, w.width] }; });
  console.log('rozmer', JSON.stringify(r));
  // DEMO: 4× a 8× = digitální, zvýraznění
  for (const z of [4, 8, 1]) { await p.evaluate(z => setZoom(z), z); await p.waitForTimeout(900); console.log(z, await p.evaluate(() => [S.zoom.toFixed(2), $$('#zoomGrp button.on').map(b => b.textContent)])); }
  await p.screenshot({ path: 'lens_bar.png', clip: { x: 0, y: r.g[1] - 40, width: 390, height: r.g[3] + 80 } });
  console.log('sousedi', await p.evaluate(() => { const g = $('#zoomGrp').getBoundingClientRect(); return [...$('#zoomGrp').parentElement.children].filter(e => e !== $('#zoomGrp') && e.offsetParent).map(e => { const q = e.getBoundingClientRect(); return [e.id || e.className, Math.round(q.left), Math.round(q.right), q.right > g.left && q.left < g.right ? 'PREKRYV' : 'ok']; }); }));
  // živá kamera s podvrženou kamerou „Back Telephoto Camera“
  await p.evaluate(async () => { await liveOn(); CAM.devices = [{ deviceId: CAM.devices[0] && CAM.devices[0].deviceId || 'x', label: 'Back Telephoto Camera', kind: 'videoinput' }]; });
  await p.waitForTimeout(1200);
  await p.evaluate(() => setZoom(8)); await p.waitForTimeout(1500);
  console.log('live 8x', await p.evaluate(() => [CAM.live, CAM.tele, S.zoom.toFixed(2), $$('#zoomGrp button.on').map(b => b.textContent)]));
  await p.evaluate(() => setZoom(1)); await p.waitForTimeout(1500);
  console.log('live 1x', await p.evaluate(() => [CAM.tele, S.zoom.toFixed(2), $$('#zoomGrp button.on').map(b => b.textContent)]));
  console.log('errors', errs); await b.close();
})();
