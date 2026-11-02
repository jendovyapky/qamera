// tah od levého okraje v galerii = zpět do foťáku (krátký tah se vrátí, delší / rychlý přepne)
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('framenavigated', f => f === p.mainFrame() && console.log('nav', f.url()));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  const cdp = await c.newCDPSession(p);
  const touch = async (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y }] });
  const drag = async (x0, x1, steps, ms) => { await touch('touchStart', x0, 420); for (let i = 1; i <= steps; i++) { await touch('touchMove', x0 + (x1 - x0) * i / steps, 420 + i); await p.waitForTimeout(ms); } await touch('touchEnd'); };
  const scr = () => p.evaluate(() => S.screen);
  await p.evaluate(() => go('gallery')); await p.waitForTimeout(900);
  console.log('start', await scr());
  // krátký pomalý tah → zůstane galerie
  await drag(6, 90, 8, 30); await p.waitForTimeout(900);
  console.log('kratky', await scr(), await p.evaluate(() => [$('#s-camera').hidden, $('#s-gallery').style.transform]));
  // tah do půlky, screenshot uprostřed
  await touch('touchStart', 6, 420); for (let i = 1; i <= 10; i++) { await touch('touchMove', 6 + 19 * i, 421); await p.waitForTimeout(16); }
  await p.screenshot({ path: 'edge_mid.png' });
  for (let i = 11; i <= 14; i++) { await touch('touchMove', 6 + 19 * i, 421); await p.waitForTimeout(16); } await touch('touchEnd');
  await p.waitForTimeout(1200);
  console.log('dlouhy', await scr(), await p.evaluate(() => [$('#s-gallery').hidden, stack.join(',')]));
  await p.screenshot({ path: 'edge_end.png' });
  console.log('errors', errs);
  await b.close();
})();
