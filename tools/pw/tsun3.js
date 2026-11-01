const { chromium } = require('playwright-core');
(async () => { const b = await chromium.launch({ channel: 'chrome' });
  for (const w of [390, 360, 320]) for (const t of ['2026-11-01T15:30:00+01:00', '2026-11-01T16:40:00+01:00']) {
    const c = await b.newContext({ viewport: { width: w, height: 844 }, hasTouch: true, isMobile: true, timezoneId: 'Europe/Prague', deviceScaleFactor: 2, serviceWorkers: 'block' }), p = await c.newPage();
    const errs = []; p.on('pageerror', e => errs.push(e.message));
    await p.clock.install({ time: new Date(t) }); await p.addInitScript(() => localStorage.setItem('qamera.newsSeen', '"9"'));
    await p.goto('http://localhost:8765/docs/preview/'); await p.clock.runFor(6000); await p.waitForTimeout(900);
    const r = await p.evaluate(() => { const c = document.querySelector('#sunCard').getBoundingClientRect(), f = document.querySelector('#tFlash').getBoundingClientRect(); return [document.querySelector('#sunTxt').textContent, Math.round(c.right), Math.round(f.left), c.right <= f.left - 4]; });
    await p.screenshot({ path: `sunfit_${w}_${t.slice(11, 13)}.png`, clip: { x: 0, y: 120, width: w, height: 110 } });
    console.log(w, t.slice(11, 16), r, errs); await c.close(); }
  await b.close(); })();
