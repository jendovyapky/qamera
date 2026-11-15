// Barevná tabulka klipu (clipLut) × foto shader: stejný obrázek přes tabulku (trilineárně, jako appka) a přímo shaderem bez prostorových efektů.
// node tlut.js dev.png  → pro každé nastavení průměrný a největší rozdíl (z 255)
const { chromium } = require('playwright-core'); const fs = require('fs');
(async () => {
  const [dev] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => { window.QDEV = true; });
  await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(dev), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(5000);
  const res = await p.evaluate(async () => {
    const s0 = await decodeTo(await (await fetch('/__f')).blob(), 4096), src = mk(640, Math.round(640 * s0.height / s0.width)); src.getContext('2d').drawImage(s0, 0, 0, src.width, src.height); src._sh = true;
    const sd = src.getContext('2d').getImageData(0, 0, src.width, src.height).data, n = CLUTN, out = [];
    try { await ensureScan('frontier'); } catch {}
    const off = { grain: 0, hal: 0, bloom: 0, glow: 0, vig: 0 };
    const V = { 'P800C výchozí': { film: 'P800C' }, 'P400 síla 50 %': { film: 'P400', str: .5 }, 'P400 síla 0 %': { film: 'P400', str: 0 }, 'G200 EV +1': { film: 'G200', exp: 1 }, 'C200 kontrast +, sytost −': { film: 'C200', con: .3, sat: -.3 },
      'P400 teplota': { film: 'P400', temp: .5, tint: -.3 }, 'P400 filtr 85': { film: 'P400', lf: '85' }, 'P400 polarizační': { film: 'P400', lf: 'POL' }, 'P400 exp. negativu −2': { film: 'P400', nexp: -2 }, 'P400 sken Frontier': { film: 'P400', scan: 'frontier' },
      'P400 fade': { film: 'P400', fade: .5 }, 'P400 měkkost': { film: 'P400', fsoft: .6 }, 'V3-500T (pleť)': { film: 'V3-500T' }, 'TX400 nové ČB': { film: 'TX400' }, 'ORTHO': { film: 'ORTHO' }, 'P400U': { film: 'P400U' }, 'bez filmu': { film: 'NONE' } };
    for (const k in V) { const P = Object.assign(DEF(), V[k]);
      const img = new Image(); img.src = clipLut(P, true); await img.decode(); const lc = mk(n * n, n), lg = lc.getContext('2d'); lg.drawImage(img, 0, 0); const L = lg.getImageData(0, 0, n * n, n).data;
      if (!util.e || util.e.dead) utilReset(); const P1 = Object.assign({}, P, off); utilRender(src, P1, src.width, src.height, { seed: 7 });
      const ref = copyCanvas(utilRender(src, P1, src.width, src.height, { seed: 7 })).getContext('2d').getImageData(0, 0, src.width, src.height).data;
      let sum = 0, mx = 0; const at = (r, g, bb, ch) => L[(g * n * n + bb * n + r) * 4 + ch];
      for (let i = 0; i < sd.length; i += 4) { const fr = sd[i] / 255 * (n - 1), fg = sd[i + 1] / 255 * (n - 1), fb = sd[i + 2] / 255 * (n - 1), r0 = Math.min(n - 2, fr | 0), g0 = Math.min(n - 2, fg | 0), b0 = Math.min(n - 2, fb | 0), tr = fr - r0, tg = fg - g0, tb = fb - b0;
        for (let ch = 0; ch < 3; ch++) { const c00 = at(r0, g0, b0, ch) * (1 - tr) + at(r0 + 1, g0, b0, ch) * tr, c10 = at(r0, g0 + 1, b0, ch) * (1 - tr) + at(r0 + 1, g0 + 1, b0, ch) * tr, c01 = at(r0, g0, b0 + 1, ch) * (1 - tr) + at(r0 + 1, g0, b0 + 1, ch) * tr, c11 = at(r0, g0 + 1, b0 + 1, ch) * (1 - tr) + at(r0 + 1, g0 + 1, b0 + 1, ch) * tr;
          const v = (c00 * (1 - tg) + c10 * tg) * (1 - tb) + (c01 * (1 - tg) + c11 * tg) * tb, d = Math.abs(v - ref[i + ch]); sum += d; if (d > mx) mx = d; } }
      out.push(k.padEnd(28) + ' průměr ' + (sum / (sd.length / 4 * 3)).toFixed(2) + '  největší ' + mx.toFixed(1) + '  (PNG ' + Math.round(img.src.length / 1024) + ' kB)'); }
    return out; });
  console.log(res.join('\n')); console.log('chyby', errs); await b.close();
})();
