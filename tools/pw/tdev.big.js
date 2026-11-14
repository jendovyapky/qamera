// Vyvolání velkého DNG (48 Mpx ProRAW) přes raw.js: soubor jde do stránky přes <input type=file> (CDP route velký soubor neunese)
// node tdev.big.js soubor.dng out_dev.png [mean]
const { chromium } = require('playwright-core'); const fs = require('fs');
(async () => {
  const [dng, out, mean] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('crash', () => console.log('STRÁNKA SPADLA'));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  await p.evaluate(() => { const i = document.createElement('input'); i.type = 'file'; i.id = '__big'; document.body.appendChild(i); });
  await p.setInputFiles('#__big', dng);
  const res = await p.evaluate(async mean => { globalThis.__qRawMean = mean > 0 ? mean : 0; const f = document.getElementById('__big').files[0], m = await import('./raw.js');
    const d = await m.developRaw(new File([f], 'x.dng', { type: 'image/x-adobe-dng' }), () => {});
    const k = 1600 / Math.max(d.canvas.width, d.canvas.height), s = mk(Math.round(d.canvas.width * k), Math.round(d.canvas.height * k)); s.getContext('2d').drawImage(d.canvas, 0, 0, s.width, s.height);
    return { w: d.canvas.width, h: d.canvas.height, png: s.toDataURL('image/png') }; }, +mean || 0);
  fs.writeFileSync(out, Buffer.from(res.png.split(',')[1], 'base64')); console.log(res.w, res.h, 'chyby', errs); await b.close();
})();
