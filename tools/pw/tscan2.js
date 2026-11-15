// Qamera: vybrané filmy se skenem labu → out/<kód>_<sken>.jpg   node tscan2.js dev.png out "G200,C200" frontier,noritsu
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
(async () => {
  const [dev, out, films, scans] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] }), c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } }), p = await c.newPage();
  await p.addInitScript(() => { window.QDEV = true; });
  await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(dev), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3000);
  const o = await p.evaluate(async ([films, scans]) => {
    const src0 = await decodeTo(await (await fetch('/__f')).blob(), 4096), W = Math.min(2400, src0.width), src = mk(W, Math.round(W * src0.height / src0.width)); src.getContext('2d').drawImage(src0, 0, 0, src.width, src.height); src._sh = true;
    const o = {};
    for (const sc of scans) { await ensureScan(sc);
      for (const film of films) { for (let i = 0; i < 150 && !LUTL[film]; i++) await new Promise(r => setTimeout(r, 100));
        const P = Object.assign(DEF(), { film, scan: sc, hal: 0, bloom: 0, glow: 0, vig: 0 }); utilRender(src, P, src.width, src.height, { seed: 7 });
        o[film + '_' + sc] = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/jpeg', .92); } }
    return o; }, [films.split(','), scans.split(',')]);
  for (const k in o) fs.writeFileSync(path.join(out, k + '.jpg'), Buffer.from(o[k].split(',')[1], 'base64'));
  console.log(Object.keys(o)); await b.close();
})();
