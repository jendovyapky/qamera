// Recepty (kreativní vzhledy nad filmem, filmy se nemění): pro každou fotku originál / čistý film / recept → out/<foto>_<i>.jpg
// node trecipe.js out dev1.png [dev2.png …]
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
const R = [
  { name: 'ULICE', film: 'P800C', P: { con: .1, temp: .04, fade: .06, grade: { sh: [3.3, .5], mid: [0, 0], hi: [.55, .35] }, hsl: { 0: [0, .25, 0], 3: [.12, -.15, -.05], 4: [0, .1, 0] } } },
  { name: 'RING', film: 'G200P', P: { exp: -.2, con: .2, temp: .2, grade: { sh: [3.4, .2], mid: [.6, .4], hi: [.5, .15] }, hsl: { 0: [0, .2, 0], 1: [0, .1, -.05], 5: [0, -.4, 0] } } },
  { name: 'PRACH', film: 'P400', P: { con: -.1, sat: -.25, fade: .15, temp: .08, grade: { sh: [0, 0], mid: [0, 0], hi: [.9, .25] }, hsl: { 3: [0, -.3, 0], 5: [0, -.3, 0] } } },
];
(async () => {
  const [out, ...devs] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => { window.QDEV = true; });
  let cur = null; await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(cur), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(5000);
  for (const dev of devs) {
    cur = dev;
    const res = await p.evaluate(async R => {
      const src0 = await decodeTo(await (await fetch('/__f')).blob(), 4096), src = mk(1200, Math.round(1200 * src0.height / src0.width)); src.getContext('2d').drawImage(src0, 0, 0, src.width, src.height); src._sh = true;
      const run = P => { if (!util.e || util.e.dead) utilReset(); utilRender(src, P, src.width, src.height, { seed: 7 }); return copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/jpeg', .9); };
      const base = o => Object.assign(DEF(), { hal: 0, bloom: 0, glow: 0 }, o), o = [run(base({ film: 'NONE', vig: 0, grain: 0 }))];
      for (const r of R) { o.push(run(base({ film: r.film })));
        const P = base({ film: r.film }); for (const k in r.P) if (k === 'hsl') { for (const i in r.P.hsl) P.hsl[i] = r.P.hsl[i]; } else P[k] = r.P[k]; o.push(run(P)); }
      return o; }, R);
    const nm = path.basename(dev).replace(/_dev\.png$/, '');
    res.forEach((d, i) => fs.writeFileSync(path.join(out, `${nm}_${i}.jpg`), Buffer.from(d.split(',')[1], 'base64')));
  }
  console.log('chyby', errs); await b.close();
})();
