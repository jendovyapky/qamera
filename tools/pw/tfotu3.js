// Fotufilm demo se zvoleným tiskovým materiálem: node tfotu3.js out foto.png "Film:m1,m2;Film2:m3"
// m = položka v Print → Output medium: match, edge, endura, crystal, 2383, 2393, lab, tele, digital
// uloží <film>_<m>.png (celá stránka DPR 2 – v panelu je vidět, co se vybralo); hlídá síťové požadavky
const { chromium } = require('playwright-core'); const path = require('path');
const Y = { match: 391, edge: 416, endura: 441, crystal: 466, '2383': 491, '2393': 516, lab: 583, tele: 608, digital: 633 };
(async () => {
  const [out, img, spec] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', headless: false, args: ['--enable-unsafe-webgpu'] });
  const c = await b.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 }), p = await c.newPage();
  const big = []; p.on('request', r => { const d = r.postDataBuffer(); if (r.method() !== 'GET' || (d && d.length > 2000)) big.push(r.method() + ' ' + r.url().slice(0, 100)); });
  await p.goto('https://fotufilm.com/demo/'); await p.waitForTimeout(25000);
  const fc = p.waitForEvent('filechooser', { timeout: 15000 }); await p.mouse.click(800, 500); (await fc).setFiles(img); await p.waitForTimeout(15000);
  for (const part of spec.split(';').filter(Boolean)) {
    const [film, ms] = part.split(':');
    await p.mouse.click(120, 92); await p.keyboard.press('Control+A'); await p.keyboard.type(film); await p.waitForTimeout(1500);
    await p.mouse.click(120, 135); await p.waitForTimeout(9000);
    await p.mouse.click(1550, 277); await p.waitForTimeout(1500);
    for (const m of ms.split(',')) {
      await p.mouse.click(1440, 359); await p.waitForTimeout(1200); await p.mouse.click(1420, Y[m]); await p.waitForTimeout(9000);
      await p.screenshot({ path: path.join(out, `${film.replace(/\W/g, '')}_${m}.png`) });
    }
  }
  console.log('ne-GET:', big); await b.close();
})();
