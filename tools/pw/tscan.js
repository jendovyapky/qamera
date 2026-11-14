// Sken labu (Tisk / Frontier / Noritsu) přes appku: render DNG a panel nastavení filmu s řádkem Sken
// node tscan.js [dng]  → scan_<sken>.jpg (s DNG), scan_panel.png
const { chromium } = require('playwright-core');
const fs = require('fs');
(async () => {
  const dng = process.argv[2];
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  if (dng) await p.route('**/__dng/*', r => r.fulfill({ body: fs.readFileSync(dng), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  await p.evaluate(() => Promise.all(Object.keys(SCANS).map(ensureScan)));
  console.log('nacteno', await p.evaluate(() => Object.fromEntries(Object.entries(LUTSC).map(([k, v]) => [k, Object.keys(v).length]))));
  if (dng) {
    const res = await p.evaluate(async () => {
      const blob = await (await fetch('/__dng/0')).blob(), m = await import('./raw.js');
      const d = await m.developRaw(new File([blob], 'x.dng'), () => {});
      const k = 1200 / Math.max(d.canvas.width, d.canvas.height), src = mk(Math.round(d.canvas.width * k), Math.round(d.canvas.height * k));
      src.getContext('2d').drawImage(d.canvas, 0, 0, src.width, src.height);
      const o = {};
      for (const sc of ['', 'frontier', 'noritsu']) {
        const P = Object.assign(DEF(), { film: 'P400', grain: 0, hal: 0, bloom: 0, glow: 0, vig: 0, scan: sc || null });
        if (!util.e || util.e.dead) utilReset();
        o[sc || 'tisk'] = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/jpeg', .9);
      }
      return o;
    });
    for (const [n, v] of Object.entries(res)) fs.writeFileSync('scan_' + n + '.jpg', Buffer.from(v.split(',')[1], 'base64'));
  }
  await p.evaluate(() => go('gallery')); await p.waitForTimeout(800);
  const has = await p.evaluate(() => S.photos.length);
  if (!has) { await p.evaluate(() => go('camera')); await p.waitForTimeout(800); await p.evaluate(() => shoot()); await p.waitForTimeout(2500); await p.evaluate(() => go('gallery')); await p.waitForTimeout(800); }
  await p.evaluate(() => openEditor(S.photos[0])); await p.waitForTimeout(1800);
  await p.evaluate(() => { S.P.film = 'P400'; S.P.fv = 2; S.filmOpen = true; setTab('film'); }); await p.waitForTimeout(1200);
  await p.evaluate(() => { const b = document.querySelector('[data-efseg="scan"] button[data-v="frontier"], [data-fseg="scan"] button[data-v="frontier"], .seg button[data-v="frontier"]'); b && b.click(); }); await p.waitForTimeout(1200);
  await p.screenshot({ path: 'scan_panel.png' });
  console.log('P.scan', await p.evaluate(() => S.P.scan), 'toast', await p.evaluate(() => { const t = document.querySelector('.toast, #toast'); return t && t.textContent; }));
  if (!has) await p.evaluate(async () => { await dbDel(S.photos[0].id); });
  console.log('errors', errs); await b.close();
})();
