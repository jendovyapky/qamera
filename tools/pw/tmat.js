// Matice film × papír skutečným shaderem: LUT filmu se podvrhne souborem z dir (<kód>_<papír>.png) → out/<kód>_<papír>.jpg
// node tmat.js dev.png lutdir out   (bez halation/bloom/glow/vinětace, zrno výchozí)
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
(async () => {
  const [dev, dir, out] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.png'))) {
    const [code] = f.split('_'), c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } }), p = await c.newPage();
    await p.addInitScript(() => { window.QDEV = true; });
    await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(dev), contentType: 'image/png' }));
    await p.route(`**/luts/log/${code}.png`, r => r.fulfill({ body: fs.readFileSync(path.join(dir, f)), contentType: 'image/png' }));
    await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
    const url = await p.evaluate(async film => {
      const src0 = await decodeTo(await (await fetch('/__f')).blob(), 4096), W = Math.min(2400, src0.width), src = mk(W, Math.round(W * src0.height / src0.width)); src.getContext('2d').drawImage(src0, 0, 0, src.width, src.height); src._sh = true;
      const P = Object.assign(DEF(), { film, hal: 0, bloom: 0, glow: 0, vig: 0 }); utilRender(src, P, src.width, src.height, { seed: 7 });
      for (let i = 0; i < 40 && !LUTL[film]; i++) await new Promise(r => setTimeout(r, 100));
      return copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/jpeg', .92); }, code);
    fs.writeFileSync(path.join(out, f.replace('.png', '.jpg')), Buffer.from(url.split(',')[1], 'base64')); await c.close(); console.log(f);
  }
  await b.close();
})();
