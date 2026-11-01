const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, serviceWorkers: 'block' }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => localStorage.setItem('qamera.newsSeen', '"9"'));
  await p.goto('http://localhost:8765/docs/preview/'); await p.waitForTimeout(5000);
  await p.evaluate(() => openFilmSheet()); await p.waitForTimeout(700);
  await p.click('#tuneBtn'); await p.waitForTimeout(600);
  const before = await p.evaluate(() => JSON.stringify(camParams()).length);
  await p.evaluate(() => { const i = document.querySelector('[data-ck=hal]'); i.value = 250; i.oninput(); i.onchange(); const g = document.querySelector('[data-ck=grain]'); g.value = 120; g.oninput(); g.onchange(); });
  await p.waitForTimeout(400); await p.screenshot({ path: 'cam_tune.png' });
  const r = await p.evaluate(() => { const P = camParams(); return { hal: P.hal, grain: P.grain, film: S.film, stored: localStorage.getItem('qamera.camSet'), set: document.querySelector('#tuneBtn').className }; });
  // jiný film → výchozí hodnoty, zpět → pamatuje
  await p.evaluate(() => setFilm('G200')); await p.waitForTimeout(200);
  const g = await p.evaluate(() => ({ hal: camParams().hal, v: document.querySelector('[data-ck=hal]').value, set: document.querySelector('#tuneBtn').className }));
  await p.evaluate(() => setFilm(r0 = Object.keys(JSON.parse(localStorage.getItem('qamera.camSet')))[0]));
  await p.click('#ftDef'); await p.waitForTimeout(200);
  const d = await p.evaluate(() => ({ hal: camParams().hal, stored: localStorage.getItem('qamera.camSet') }));
  await p.click('#tuneBtn'); await p.waitForTimeout(400); await p.screenshot({ path: 'cam_tune_off.png' });
  console.log({ r, g, d, errs }); await b.close();
})();
