const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  for (const [t, name] of [['2026-11-01T15:30:00+01:00', 'pred'], ['2026-11-01T16:12:00+01:00', 'zlata'], ['2026-11-01T16:40:00+01:00', 'predmodrou'], ['2026-11-01T17:05:00+01:00', 'modra']]) {
    const c = await b.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, timezoneId: 'Europe/Prague', deviceScaleFactor: 2, serviceWorkers: 'block' }), p = await c.newPage();
    const errs = []; p.on('pageerror', e => errs.push(e.message));
    await p.clock.install({ time: new Date(t) });
    await p.addInitScript(() => localStorage.setItem('qamera.newsSeen', '"9"'));
    await p.goto('http://localhost:8765/docs/preview/'); await p.clock.runFor(6000); await p.waitForTimeout(800);
    const st = () => p.evaluate(() => [document.querySelector('#tSun').className, document.querySelector('#sunCard').className, document.querySelector('#sunTxt').textContent]);
    const a = await st();
    await p.screenshot({ path: `sun_${name}.png`, clip: { x: 0, y: 130, width: 390, height: 120 } });
    let after = null;
    if (a[1].includes('on')) { await p.click('#sunCard'); await p.waitForTimeout(700); after = await st(); await p.screenshot({ path: `sun_${name}_zabaleno.png`, clip: { x: 0, y: 130, width: 390, height: 120 } });
      await p.clock.runFor(31000); after.push((await st())[1]); }
    console.log(name, a, after, errs); await c.close();
  }
  await b.close();
})();
