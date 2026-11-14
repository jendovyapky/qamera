// Filmy V2 proti původním na DNG: node tv2b.js out_dir dng... → <dng>_cmp.jpg (řádky: G200 | G200C, P160 | P160C, V3-500T stará úprava | nová fv 3)
const { chromium } = require('playwright-core');
const fs = require('fs'), path = require('path');
(async () => {
  const [out, ...dngs] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__dng/*', r => r.fulfill({ body: fs.readFileSync(dngs[+r.request().url().split('/').pop()]), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  for (let i = 0; i < dngs.length; i++) {
    const url = await p.evaluate(async i => {
      const blob = await (await fetch('/__dng/' + i)).blob(), m = await import('./raw.js');
      const d = await m.developRaw(new File([blob], 'x.dng'), () => {});
      const W = 800, H = Math.round(d.canvas.height * W / d.canvas.width), src = mk(W, H); src.getContext('2d').drawImage(d.canvas, 0, 0, W, H);
      const rows = [[['NONE', 3, 'FOTKA BEZ FILMU'], ['P400C', 3, 'P400C (V2)']], [['G200', 2, 'G200 (puvodni film)'], ['G200C', 3, 'G200C (V2)']], [['P160', 2, 'P160 (puvodni film)'], ['P160C', 3, 'P160C (V2)']], [['V3-500T', 2, 'V3-500T stara uprava'], ['V3-500T', 3, 'V3-500T (V2)']]];
      const o = mk(W * 2 + 10, rows.length * (H + 10)), g = o.getContext('2d'); g.fillStyle = '#000'; g.fillRect(0, 0, o.width, o.height);
      rows.forEach((r, y) => r.forEach(([film, fv, lab], x) => { const P = Object.assign(DEF(), { film, fv, grain: .6, hal: 0, bloom: 0, glow: 0, vig: 0 }); if (!util.e || util.e.dead) utilReset();
        g.drawImage(copyCanvas(utilRender(src, P, W, H, { seed: 7 })), x * (W + 10), y * (H + 10)); g.fillStyle = 'rgba(0,0,0,.6)'; g.fillRect(x * (W + 10), y * (H + 10), 330, 38); g.fillStyle = '#ff0'; g.font = 'bold 22px monospace'; g.fillText(lab, x * (W + 10) + 10, y * (H + 10) + 26); }));
      return o.toDataURL('image/jpeg', .88);
    }, i);
    fs.writeFileSync(path.join(out, path.basename(dngs[i]).replace(/\.dng$/i, '') + '_cmp.jpg'), Buffer.from(url.split(',')[1], 'base64'));
  }
  console.log('errors', errs); await b.close();
})();
