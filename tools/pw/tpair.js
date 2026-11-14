// pár Apple JPEG × RAW (raw.js) ve stejném rozměru → PNG pro fitování převodu (jen Honzou dodané DNG, výstup mimo repo)
// node tpair.js out dng apple.jpg
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
(async () => {
  const [out, dng, jpg] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  await p.route('**/__f/*', r => r.fulfill({ body: fs.readFileSync(r.request().url().endsWith('/0') ? dng : jpg), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  const res = await p.evaluate(async () => {
    const m = await import('./raw.js'), d = await m.developRaw(new File([await (await fetch('/__f/0')).blob()], 'x.dng'), () => {});
    const ap = await decodeTo(await (await fetch('/__f/1')).blob(), 8192), W = 800, H = Math.round(800 * d.canvas.height / d.canvas.width);
    const fit = c => { const o = mk(W, H); o.getContext('2d').drawImage(c, 0, 0, W, H); return o.toDataURL('image/png'); };
    return [fit(d.canvas), fit(ap), [d.canvas.width, d.canvas.height, ap.width, ap.height]];
  });
  const base = path.join(out, path.basename(dng));
  fs.writeFileSync(base + '_raw.png', Buffer.from(res[0].split(',')[1], 'base64')); fs.writeFileSync(base + '_app.png', Buffer.from(res[1].split(',')[1], 'base64')); console.log(res[2]); await b.close();
})();
