// Záře fotky po složkách (jako hledáček / snímek z logu: src._sh, bez mapy světel): base, +bloom, +glow, obojí → png (pro kalibraci klipu)
// node tglow.js FILM dev.png out_prefix
const { chromium } = require('playwright-core'); const fs = require('fs');
(async () => {
  const [film, dev, out] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(dev), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4500);
  const res = await p.evaluate(async film => {
    const s0 = await decodeTo(await (await fetch('/__f')).blob(), 4096), src = mk(1200, Math.round(1200 * s0.height / s0.width)); src.getContext('2d').drawImage(s0, 0, 0, src.width, src.height); src._sh = true;
    const D = DEF(), f = FILM[film], V = { base: { bloom: 0, glow: 0 }, bloom: { glow: 0 }, glow: { bloom: 0 }, both: {} }, o = { gl: f.gl, bloomDef: D.bloom };
    for (const k in V) { const P = Object.assign(DEF(), { film, grain: 0, hal: 0, vig: 0 }, V[k]); if (!util.e || util.e.dead) utilReset(); utilRender(src, P, src.width, src.height, { seed: 7 });
      o[k] = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/png'); }
    o.src = src.toDataURL('image/png'); return o; }, film);
  for (const k of ['base', 'bloom', 'glow', 'both', 'src']) fs.writeFileSync(out + '_' + k + '.png', Buffer.from(res[k].split(',')[1], 'base64'));
  console.log('glow filmu', res.gl, 'bloom', res.bloomDef, 'chyby', errs); await b.close();
})();
