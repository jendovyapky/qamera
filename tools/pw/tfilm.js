// Srovnání se spektrafilmem: stejné DNG přes appku (raw.js → film na výchozích, bez zrna/záře/vinětace)
// node tfilm.js FILM out_dir dng...   (jen vlastní nebo volně licencované DNG, výstup mimo repo)
const { chromium } = require('playwright-core');
const fs = require('fs'), path = require('path');
(async () => {
  const [film, out, ...dngs] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__dng/*', r => r.fulfill({ body: fs.readFileSync(dngs[+r.request().url().split('/').pop()]), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  for (let i = 0; i < dngs.length; i++) {
    const url = await p.evaluate(async ([i, film]) => {
      const blob = await (await fetch('/__dng/' + i)).blob(), m = await import('./raw.js');
      const d = await m.developRaw(new File([blob], 'x.dng', { type: 'image/x-adobe-dng' }), () => {});
      const k = 1200 / Math.max(d.canvas.width, d.canvas.height), src = mk(Math.round(d.canvas.width * k), Math.round(d.canvas.height * k));
      src.getContext('2d').drawImage(d.canvas, 0, 0, src.width, src.height);
      const P = Object.assign(DEF(), { film, grain: 0, hal: 0, bloom: 0, glow: 0, vig: 0 });
      if (!util.e || util.e.dead) utilReset();
      const o = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 }));
      const plain = src.toDataURL('image/png');
      return [o.toDataURL('image/png'), plain];
    }, [i, film]);
    const base = path.basename(dngs[i], '.dng');
    fs.writeFileSync(path.join(out, base + '_app.png'), Buffer.from(url[0].split(',')[1], 'base64'));
    fs.writeFileSync(path.join(out, base + '_appraw.png'), Buffer.from(url[1].split(',')[1], 'base64'));
    console.log(base);
  }
  console.log('errors', errs); await b.close();
})();
