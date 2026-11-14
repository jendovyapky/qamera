// Film V2 (P400C): štítek V2 na kazetě ve výběru filmu + zrno podle hustoty (šedý klín) proti P400
// node tv2.js → v2_cam.png, v2_grain.png
const { chromium } = require('playwright-core');
const fs = require('fs');
(async () => {
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  await p.evaluate(() => { go('camera'); }); await p.waitForTimeout(900);
  await p.evaluate(() => { setFilm('P400C'); openFilmSheet(); }); await p.waitForTimeout(1500);
  await p.screenshot({ path: 'v2_cam.png' });
  const g = await p.evaluate(() => {
    const src = mk(1200, 300), x = src.getContext('2d'), gr = x.createLinearGradient(0, 0, 1200, 0);
    gr.addColorStop(0, '#000'); gr.addColorStop(1, '#fff'); x.fillStyle = gr; x.fillRect(0, 0, 1200, 300);
    const o = {};
    for (const film of ['P400', 'P400C']) { const P = Object.assign(DEF(), { film, grain: 1, hal: 0, bloom: 0, glow: 0, vig: 0 }); if (!util.e || util.e.dead) utilReset(); o[film] = copyCanvas(utilRender(src, P, 1200, 300, { seed: 7 })).toDataURL('image/png'); }
    return o;
  });
  for (const [k, v] of Object.entries(g)) fs.writeFileSync('v2_grain_' + k + '.png', Buffer.from(v.split(',')[1], 'base64'));
  console.log('errors', errs); await b.close();
})();
