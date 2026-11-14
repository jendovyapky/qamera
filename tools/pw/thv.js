// hledáček: odhad světel z 8bit obrazu (hv 1 = dřív, hv 2 = slabší) na bílém okně monitoru s V3-500T → hv_cmp.png
const { chromium } = require('playwright-core'); const fs = require('fs');
(async () => {
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 } }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const d = await p.evaluate(() => { const src = mk(900, 600), x = src.getContext('2d'); x.fillStyle = '#2a2d33'; x.fillRect(0, 0, 900, 600); x.fillStyle = '#fff'; x.fillRect(250, 180, 400, 200);
    x.fillStyle = '#ffe9a0'; x.beginPath(); x.arc(120, 100, 14, 0, 7); x.fill();
    const o = mk(1800, 600), g = o.getContext('2d');
    [1, 2].forEach((hv, i) => { const P = Object.assign(DEF(), { film: 'V3-500T', hv }); if (!util.e || util.e.dead) utilReset(); g.drawImage(utilRender(src, P, 900, 600, { seed: 3 }), i * 900, 0); });
    return o.toDataURL('image/jpeg', .9); });
  fs.writeFileSync('hv_cmp.jpg', Buffer.from(d.split(',')[1], 'base64')); console.log('errors', errs); await b.close();
})();
