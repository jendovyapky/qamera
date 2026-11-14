// Zpětný převod obrazu z iPhonu (P.apl): Apple JPEG bez/s převodem → film, vedle reference (např. Apple Log → stejný film)
// node tapl.js FILM out apple.jpg [reference.png]   (jen Honzovy soubory, výstup mimo repo)
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
(async () => {
  const [film, out, jpg, ref] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__f/*', r => r.fulfill({ body: fs.readFileSync(r.request().url().endsWith('/0') ? jpg : ref), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const res = await p.evaluate(async ([film, hasRef]) => {
    const fit = c => { const k = 700 / c.height, o = mk(Math.round(c.width * k), 700); o.getContext('2d').drawImage(c, 0, 0, o.width, o.height); return o; };
    const ap = fit(await decodeTo(await (await fetch('/__f/0')).blob(), 4000)), rf = hasRef ? fit(await decodeTo(await (await fetch('/__f/1')).blob(), 4000)) : null;
    const W = ap.width, H = ap.height, cols = [ap];
    for (const apl of [0, 1]) { const P = Object.assign(DEF(), { film, apl }); if (!util.e || util.e.dead) utilReset(); const o = mk(W, H); o.getContext('2d').drawImage(utilRender(ap, P, W, H, { seed: 5 }), 0, 0); cols.push(o); }
    if (rf) cols.push(rf);
    const st = c => { const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data, L = [], S = []; for (let i = 0; i < d.length; i += 16) { const r = d[i] / 255, g = d[i + 1] / 255, bb = d[i + 2] / 255, mx = Math.max(r, g, bb), mn = Math.min(r, g, bb); L.push(.2126 * r + .7152 * g + .0722 * bb); S.push((mx - mn) / (mx + 1e-3)); }
      L.sort((a, b) => a - b); const q = k => L[Math.floor(L.length * k)].toFixed(3); return `p5 ${q(.05)} p50 ${q(.5)} p95 ${q(.95)} sat ${(S.reduce((a, b) => a + b, 0) / S.length).toFixed(3)}`; };
    const o = mk(cols.reduce((a, c) => a + c.width + 8, 0), H), g = o.getContext('2d'); let x = 0;
    const names = ['APPLE', film + ' (dřív)', film + ' + převod', 'REFERENCE'];
    cols.forEach((c, i) => { g.drawImage(c, x, 0); g.font = 'bold 22px sans-serif'; g.fillStyle = '#ff0'; g.fillText(names[i], x + 12, 30); x += c.width + 8; });
    return [o.toDataURL('image/jpeg', .88), cols.map((c, i) => names[i] + ': ' + st(c))];
  }, [film, !!ref]);
  fs.writeFileSync(path.join(out, path.basename(jpg) + '_apl_' + film + '.jpg'), Buffer.from(res[0].split(',')[1], 'base64')); console.log(res[1].join('\n')); console.log('errors', errs); await b.close();
})();
