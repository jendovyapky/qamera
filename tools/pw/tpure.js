// Shader × čistá LUT: vyvolaný originál (_dev.png z treplay) přes film s různým nastavením → průměry (porovnat s cmp.py)
const { chromium } = require('playwright-core'); const fs = require('fs');
(async () => {
  const [film, dev, out] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  await p.route('**/__f', r => r.fulfill({ body: fs.readFileSync(dev), contentType: 'image/png' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const res = await p.evaluate(async film => {
    const src = await decodeTo(await (await fetch('/__f')).blob(), 4096); src._sh = true;
    const V = { def: {}, clean: { grain: 0, hal: 0, bloom: 0, glow: 0, vig: 0 }, novig: { vig: 0 }, noglow: { glow: 0 }, nobloom: { bloom: 0 }, nohal: { hal: 0 }, nograin: { grain: 0 }, onlyvig: { grain: 0, hal: 0, bloom: 0, glow: 0 }, onlyglow: { grain: 0, hal: 0, bloom: 0, vig: 0 }, onlygrain: { hal: 0, bloom: 0, glow: 0, vig: 0 } }, o = {};
    for (const k in V) { const P = Object.assign(DEF(), { film }, V[k]); if (!util.e || util.e.dead) utilReset();
      const c = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })), d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let s = [0, 0, 0];
      for (let i = 0; i < d.length; i += 4) { s[0] += d[i]; s[1] += d[i + 1]; s[2] += d[i + 2]; } o[k] = s.map(v => Math.round(v / (d.length / 4))); if (k === 'clean') o.img = c.toDataURL('image/jpeg', .92); }
    return o; }, film);
  if (out) fs.writeFileSync(out, Buffer.from(res.img.split(',')[1], 'base64')); delete res.img; console.log(JSON.stringify(res)); await b.close();
})();
