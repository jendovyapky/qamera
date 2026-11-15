// C200 fv 4 = olivové stíny (luts/log/C200O.png), fv 3 = beze změny: node tolive.js dev.png out
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
(async () => {
  const [dev, out] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] }), c = await b.newContext({ serviceWorkers: 'block' }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(dev), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3000);
  const r = await p.evaluate(async () => {
    for (let i = 0; i < 100 && !(LUTL.C200 && LUTL.C200O); i++) await new Promise(r => setTimeout(r, 100));
    const src0 = await decodeTo(await (await fetch('/__f')).blob(), 4096), W = 1600, src = mk(W, Math.round(W * src0.height / src0.width)); src.getContext('2d').drawImage(src0, 0, 0, src.width, src.height); src._sh = true;
    const o = {};
    for (const fv of [3, 4]) { const P = Object.assign(DEF(), { film: 'C200', fv, hal: 0, bloom: 0, glow: 0, vig: 0, grain: 0 });
      utilRender(src, P, src.width, src.height, { seed: 7 }); o[fv] = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/png'); }
    return { o, def: DEF().fv, has: !!LUTL.C200O }; });
  for (const k in r.o) fs.writeFileSync(path.join(out, 'olive_fv' + k + '.png'), Buffer.from(r.o[k].split(',')[1], 'base64'));
  console.log('DEF.fv', r.def, 'C200O', r.has, 'chyby', errs); await b.close();
})();
