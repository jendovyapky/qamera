// Přehrání fotky z Ladění na PC: originál z kamery (raw-*.dng + raw-*.json z appky Soubory → Qamera DEV → Ladeni)
// stejnou cestou jako v telefonu: vyvolání (raw.js = stejná matematika jako RawDevelop, jas hledáčku z json.mean) → film (apl −0,5 jako RAW z appky).
// node treplay.js FILM out_dir raw-xxx.dng...   (jen Honzovy soubory, výstup mimo repo)
const { chromium } = require('playwright-core');
const fs = require('fs'), path = require('path');
(async () => {
  const [film, out, ...files] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__dng/*', r => r.fulfill({ body: fs.readFileSync(files[+r.request().url().split('/').pop()]), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  for (let i = 0; i < files.length; i++) {
    const jf = files[i].replace(/\.dng$/i, '.json'), meta = fs.existsSync(jf) ? JSON.parse(fs.readFileSync(jf, 'utf8')) : {};
    const res = await p.evaluate(async ([i, film, mean]) => {
      globalThis.__qRawMean = mean > 0 ? mean : 0;
      const blob = await (await fetch('/__dng/' + i)).blob(), m = await import('./raw.js');
      const d = await m.developRaw(new File([blob], 'x.dng', { type: 'image/x-adobe-dng' }), () => {});
      const k = 1600 / Math.max(d.canvas.width, d.canvas.height), src = mk(Math.round(d.canvas.width * k), Math.round(d.canvas.height * k));
      src.getContext('2d').drawImage(d.canvas, 0, 0, src.width, src.height); if (d.canvas._hl) src._hl = d.canvas._hl;
      const P = Object.assign(DEF(), { film, apl: -0.5 });
      if (!util.e || util.e.dead) utilReset();
      return { dev: src.toDataURL('image/png'), film: copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/jpeg', .92) };
    }, [i, film, meta.mean]);
    const base = path.basename(files[i]).replace(/\.dng$/i, '');
    fs.writeFileSync(path.join(out, base + '_dev.png'), Buffer.from(res.dev.split(',')[1], 'base64'));
    fs.writeFileSync(path.join(out, base + '_' + film + '.jpg'), Buffer.from(res.film.split(',')[1], 'base64'));
    console.log(base, meta);
  }
  console.log('chyby', errs); await b.close();
})();
