// Zrno Qamery × spektrafilm na šedé škále (stejné pásy jako E:\qamera\spektra\grainmeas.py: −7…+5 EV, pás 112 px, šířka 1024, 1 zrno = 1 px)
// node tgrain.js FILM [out.png]  → σ·255 po kanálech, korelace mezi kanály, autokorelace o 1 px
const { chromium } = require('playwright-core'); const fs = require('fs');
(async () => {
  const [film, out] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const res = await p.evaluate(async film => {
    const BH = 112, W = 1024, EV = []; for (let e = -7; e <= 5; e++) EV.push(e);
    const src = mk(W, BH * EV.length), g = src.getContext('2d');
    EV.forEach((e, i) => { let v = .18 * Math.pow(2, e); v = v > .55 ? .55 + .45 * (1 - Math.exp(-(v - .55) / .45)) : v; const s = Math.round(255 * (v <= .0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - .055)); g.fillStyle = `rgb(${s},${s},${s})`; g.fillRect(0, i * BH, W, BH); });
    src._sh = true;
    const P = Object.assign(DEF(), { film, hal: 0, bloom: 0, glow: 0, vig: 0 });
    if (!util.e || util.e.dead) utilReset(); let c = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7, gn: src.height })); await new Promise(r => setTimeout(r, 1500));
    c = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7, gn: src.height }));
    const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data, rows = [];
    EV.forEach((e, i) => { const y0 = i * BH + 12, y1 = (i + 1) * BH - 12, x0 = 16, x1 = W - 16, n = (y1 - y0) * (x1 - x0), m = [0, 0, 0];
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) for (let k = 0; k < 3; k++) m[k] += d[(y * W + x) * 4 + k]; for (let k = 0; k < 3; k++) m[k] /= n;
      const v = [0, 0, 0], cc = [0, 0, 0], ac = [0, 0, 0];
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const q = (y * W + x) * 4, a = [d[q] - m[0], d[q + 1] - m[1], d[q + 2] - m[2]];
        for (let k = 0; k < 3; k++) { v[k] += a[k] * a[k]; ac[k] += a[k] * (d[q + 4 + k] - m[k]); } cc[0] += a[0] * a[1]; cc[1] += a[0] * a[2]; cc[2] += a[1] * a[2]; }
      const sd = v.map(x => Math.sqrt(x / n));
      rows.push(`EV ${e > 0 ? '+' : ''}${e} mean [${m.map(x => x.toFixed(1))}] sd [${sd.map(x => x.toFixed(2))}] corr RG ${(cc[0] / n / sd[0] / sd[1]).toFixed(2)} RB ${(cc[1] / n / sd[0] / sd[2]).toFixed(2)} GB ${(cc[2] / n / sd[1] / sd[2]).toFixed(2)} ac1 [${ac.map((x, k) => (x / v[k]).toFixed(2))}]`); });
    return { rows, img: c.toDataURL('image/png') };
  }, film);
  if (out) fs.writeFileSync(out, Buffer.from(res.img.split(',')[1], 'base64'));
  console.log(res.rows.join('\n')); console.log('chyby', errs); await b.close();
})();
