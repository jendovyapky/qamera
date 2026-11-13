// Film v2 v appce: editor (ukázková fotka) a hledáček, v1 vs v2 vedle sebe + chyby v konzoli
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4500);
  await p.mouse.click(195, 400); await p.waitForTimeout(800);
  await p.screenshot({ path: 'fv2_cam.png' });
  for (const fv of [1, 2]) {
    await p.evaluate(fv => { const ph = S.photos.find(p => p.kind !== 'arch'); ph.P.fv = fv; ph.P.film = 'P400'; openEditor(ph); }, fv);
    await p.waitForTimeout(1800); await p.screenshot({ path: `fv2_ed${fv}.png` });
    await p.evaluate(() => go('camera')); await p.waitForTimeout(900);
  }
  console.log('errors', errs); await b.close();
})();
