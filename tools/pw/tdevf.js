// DEV: ve výběru filmů jen filmy ze spektrafilmu (QNATIVE / QDEV), produkce všechny
const { chromium } = require('playwright-core');
(async () => { const b = await chromium.launch({ channel: 'chrome' });
  for (const nat of [false, true]) { const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 } }), p = await c.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message));
    if (nat) await p.addInitScript(() => { window.QNATIVE = {}; });
    await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3000);
    console.log(nat ? 'DEV' : 'produkce', await p.evaluate(() => { const l = filmsOrdered().map(f => f.code); return [l.length, l.slice(0, 5).join(','), l.join(',')]; }), errs); await c.close(); }
  await b.close(); })();
