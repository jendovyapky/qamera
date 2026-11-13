// Film na skutečném DNG: raw.js → film v1 i v2 (výchozí, bez zrna/záře/vinětace)
// node tfilm.js FILM[,FILM2…] out_dir dng...   (jen vlastní nebo Honzou dodané DNG, výstup mimo repo)
// výstup: <dng>_appraw.png (vyvolané bez filmu), <dng>_<FILM>_v1.png, <dng>_<FILM>_v2.png
const { chromium } = require('playwright-core');
const fs = require('fs'), path = require('path');
(async () => {
  const [films, out, ...dngs] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__dng/*', r => r.fulfill({ body: fs.readFileSync(dngs[+r.request().url().split('/').pop()]), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  for (let i = 0; i < dngs.length; i++) {
    const t0 = Date.now();
    const res = await p.evaluate(async ([i, films]) => {
      const blob = await (await fetch('/__dng/' + i)).blob(), m = await import('./raw.js');
      const d = await m.developRaw(new File([blob], 'x.dng', { type: 'image/x-adobe-dng' }), () => {});
      const k = 1600 / Math.max(d.canvas.width, d.canvas.height), src = mk(Math.round(d.canvas.width * k), Math.round(d.canvas.height * k));
      src.getContext('2d').drawImage(d.canvas, 0, 0, src.width, src.height);
      const r = { raw: src.toDataURL('image/png'), info: [d.canvas.width, d.canvas.height, d.label || ''] };
      for (const film of films.split(',')) for (const fv of [1, 2]) {
        const P = Object.assign(DEF(), { film, fv, grain: 0, hal: 0, bloom: 0, glow: 0, vig: 0 });
        if (!util.e || util.e.dead) utilReset();
        r[film + '_v' + fv] = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/png');
      }
      return r;
    }, [i, films]);
    const base = path.basename(dngs[i]).replace(/\.dng$/i, '');
    for (const [k, v] of Object.entries(res)) if (k !== 'info') fs.writeFileSync(path.join(out, base + '_' + (k === 'raw' ? 'appraw' : k) + '.png'), Buffer.from(v.split(',')[1], 'base64'));
    console.log(base, res.info, (Date.now() - t0) + ' ms');
  }
  console.log('errors', errs); await b.close();
})();
