// Světla / Stíny + tah od levého okraje v editoru (zpět do galerie)
// node tshad.js [dng]  → shad_ed.png (Úpravy v editoru), shad_mid.png (tah uprostřed), s DNG i shad_<x>.png (výchozí / světla −1 / stíny +1 / obojí)
const { chromium } = require('playwright-core');
const fs = require('fs');
(async () => {
  const dng = process.argv[2];
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  if (dng) await p.route('**/__dng/*', r => r.fulfill({ body: fs.readFileSync(dng), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  if (dng) {
    const res = await p.evaluate(async () => {
      const blob = await (await fetch('/__dng/0')).blob(), m = await import('./raw.js');
      const d = await m.developRaw(new File([blob], 'x.dng'), () => {});
      const k = 1200 / Math.max(d.canvas.width, d.canvas.height), src = mk(Math.round(d.canvas.width * k), Math.round(d.canvas.height * k));
      src.getContext('2d').drawImage(d.canvas, 0, 0, src.width, src.height);
      const o = {};
      for (const [n, x] of Object.entries({ def: {}, hil: { hil: -1 }, shad: { shad: 1 }, both: { hil: -1, shad: 1 } })) {
        const P = Object.assign(DEF(), { film: 'P400', grain: 0, hal: 0, bloom: 0, glow: 0, vig: 0 }, x);
        if (!util.e || util.e.dead) utilReset();
        o[n] = copyCanvas(utilRender(src, P, src.width, src.height, { seed: 7 })).toDataURL('image/jpeg', .9);
      }
      return o;
    });
    for (const [n, v] of Object.entries(res)) fs.writeFileSync('shad_' + n + '.jpg', Buffer.from(v.split(',')[1], 'base64'));
  }
  // editor s fotkou z demo foťáku, záložka Úpravy
  await p.evaluate(async () => { go('gallery'); }); await p.waitForTimeout(800);
  const has = await p.evaluate(() => S.photos.length);
  if (!has) { await p.evaluate(() => go('camera')); await p.waitForTimeout(800); await p.evaluate(() => shoot()); await p.waitForTimeout(2500); await p.evaluate(() => go('gallery')); await p.waitForTimeout(800); }
  await p.evaluate(() => openEditor(S.photos[0])); await p.waitForTimeout(1800);
  await p.evaluate(() => { S.adjKey = 'hil'; setTab('adj'); }); await p.waitForTimeout(900);
  await p.screenshot({ path: 'shad_ed.png' });
  console.log('chips', await p.evaluate(() => $$('#chipRow .chip').map(x => x.textContent.trim()).join(' | ')));
  const cdp = await c.newCDPSession(p);
  const touch = (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] });
  console.log('start', await p.evaluate(() => [S.screen, stack.join(',')]));
  await touch('touchStart', 6, 300); for (let i = 1; i <= 10; i++) { await touch('touchMove', 6 + 19 * i, 301); await p.waitForTimeout(16); }
  await p.screenshot({ path: 'shad_mid.png' });
  for (let i = 11; i <= 14; i++) { await touch('touchMove', 6 + 19 * i, 301); await p.waitForTimeout(16); } await touch('touchEnd');
  await p.waitForTimeout(1200);
  console.log('po tahu', await p.evaluate(() => [S.screen, $('#s-editor').hidden, stack.join(',')]));
  // úklid demo fotky
  if (!has) await p.evaluate(async () => { await dbDel(S.photos[0].id); });
  console.log('errors', errs); await b.close();
})();
