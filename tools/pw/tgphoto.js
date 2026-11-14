// Honzova fotka (_dev.png) přes Qameru: staré zrno (grv 2) × nové (grv 3), bez ostatních efektů → png (porovnat se spektrafilmem z grainphoto.py)
const { chromium } = require('playwright-core'); const fs = require('fs');
(async () => {
  const [film, dev, out] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(dev), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const res = await p.evaluate(async film => {
    const src = await decodeTo(await (await fetch('/__f')).blob(), 4096); src._sh = true; const o = {};
    for (const grv of [2, 3]) { const P = Object.assign(DEF(), { film, grv, hal: 0, bloom: 0, glow: 0, vig: 0 }); if (!util.e || util.e.dead) utilReset();
      utilRender(src, P, src.width, src.height, { seed: 7 }); await new Promise(r => setTimeout(r, 1200));
      o['g' + grv] = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/png'); }
    return o; }, film);
  for (const k in res) fs.writeFileSync(out + '_' + k + '.png', Buffer.from(res[k].split(',')[1], 'base64'));
  console.log('chyby', errs); await b.close();
})();
