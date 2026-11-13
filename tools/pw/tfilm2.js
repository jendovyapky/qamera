// Film v1 vs v2 na syntetickém obrázku (tabulka ColorChecker ze spektra/chart.py): node tfilm2.js vstup.png out_dir [FILM]
const { chromium } = require('playwright-core');
const fs = require('fs'), path = require('path');
(async () => {
  const [inp, out, film = 'P400'] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.route('**/__in.png', r => r.fulfill({ body: fs.readFileSync(inp), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const r = await p.evaluate(async film => {
    for (let t = 0; t < 50 && !LUTL[film]; t++) await new Promise(r => setTimeout(r, 100));
    const bm = await createImageBitmap(await (await fetch('/__in.png')).blob(), { colorSpaceConversion: 'none' }), src = mk(bm.width, bm.height); src.getContext('2d').drawImage(bm, 0, 0);
    if (!util.e || util.e.dead) utilReset();
    const res = {};
    for (const fv of [1, 2]) { const P = Object.assign(DEF(), { film, fv, grain: 0, hal: 0, bloom: 0, glow: 0, vig: 0 });
      res['v' + fv] = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/png'); }
    return { res, logLut: !!LUTL[film] };
  }, film);
  for (const k in r.res) fs.writeFileSync(path.join(out, `chart_${k}.png`), Buffer.from(r.res[k].split(',')[1], 'base64'));
  console.log('log LUT', r.logLut, 'errors', errs); await b.close();
})();
