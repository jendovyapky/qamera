const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  for (const [vp, name] of [[{ width: 390, height: 844 }, 'm'], [{ width: 1440, height: 900 }, 'pc']]) {
    const c = await b.newContext({ serviceWorkers: 'block', viewport: vp, hasTouch: name === 'm', isMobile: name === 'm' }), p = await c.newPage();
    const errs = []; p.on('pageerror', e => errs.push(e.message));
    await p.goto('http://localhost:8765/docs/preview/'); await p.waitForTimeout(5000);
    const fresh = await p.evaluate(() => [!!document.querySelector('.newsmod'), localStorage.getItem('qamera.newsSeen')]);
    await p.evaluate(() => { localStorage.setItem('qamera.newsSeen', '"0.17"'); }); await p.reload(); await p.waitForTimeout(5500);
    const upd = await p.evaluate(() => !!document.querySelector('.newsmod.on'));
    await p.screenshot({ path: `news_${name}.png` });
    await p.click('#nwOk'); await p.waitForTimeout(500); await p.reload(); await p.waitForTimeout(5000);
    const again = await p.evaluate(() => !!document.querySelector('.newsmod'));
    console.log(name, { fresh, upd, again, errs }); await c.close();
  }
  await b.close();
})();
