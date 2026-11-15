// Sada filmů v DEV přes skutečný shader appky (vyvolaný originál _dev.png): každý film → out/<kód>.jpg; kontrola, že ČB jdou přes log LUT
// node tset.js dev.png out_dir
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
(async () => {
  const [dev, out] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => { window.QDEV = true; });
  await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(dev), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(5000);
  const res = await p.evaluate(async () => {
    const src0 = await decodeTo(await (await fetch('/__f')).blob(), 4096), src = mk(1200, Math.round(1200 * src0.height / src0.width)); src.getContext('2d').drawImage(src0, 0, 0, src.width, src.height); src._sh = true;
    const o = {}, info = {};
    for (const film of filmsOrdered().map(f => f.code)) { const P = Object.assign(DEF(), { film, hal: 0, bloom: 0, glow: 0, vig: 0 }); if (!util.e || util.e.dead) utilReset();
      utilRender(src, P, src.width, src.height, { seed: 7 }); const cv = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })); o[film] = cv.toDataURL('image/jpeg', .9);
      const d = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data; let m = [0, 0, 0], ch = 0; for (let i = 0; i < d.length; i += 4) { m[0] += d[i]; m[1] += d[i + 1]; m[2] += d[i + 2]; ch += Math.abs(d[i] - d[i + 2]); }
      info[film] = { mean: m.map(v => Math.round(v / (d.length / 4))), chroma: +(ch / (d.length / 4)).toFixed(1), log: !!LUTL[film] }; }
    return { o, info }; });
  for (const k in res.o) fs.writeFileSync(path.join(out, k.replace(/[^\w-]/g, '_') + '.jpg'), Buffer.from(res.o[k].split(',')[1], 'base64'));
  console.log(JSON.stringify(res.info).replace(/},/g, '},\n')); console.log('chyby', errs); await b.close();
})();
