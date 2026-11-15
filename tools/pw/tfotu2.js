// Fotufilm demo – průzkum / render s klikáním: node tfotu2.js out foto.png "Film" "x,y;x,y;..." [jméno]
// po načtení fotky a výběru filmu proklikne zadané body (CSS px), počká a uloží screenshot
const { chromium } = require('playwright-core'); const path = require('path');
(async () => {
  const [out, img, film, clicks = '', nm = 'probe'] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', headless: false, args: ['--enable-unsafe-webgpu'] });
  const c = await b.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 }), p = await c.newPage();
  const big = []; p.on('request', r => { const d = r.postDataBuffer(); if (r.method() !== 'GET' || (d && d.length > 2000)) big.push(r.method() + ' ' + r.url().slice(0, 100)); });
  await p.goto('https://fotufilm.com/demo/'); await p.waitForTimeout(25000);
  const fc = p.waitForEvent('filechooser', { timeout: 15000 }); await p.mouse.click(800, 500); (await fc).setFiles(img); await p.waitForTimeout(15000);
  await p.mouse.click(120, 92); await p.keyboard.press('Control+A'); await p.keyboard.type(film); await p.waitForTimeout(1500); await p.mouse.click(120, 135); await p.waitForTimeout(10000);
  let i = 0;
  for (const s of clicks.split(';').filter(Boolean)) { const [x, y] = s.split(',').map(Number); await p.mouse.click(x, y); await p.waitForTimeout(4000); await p.screenshot({ path: path.join(out, `${nm}_${i++}.png`) }); }
  await p.waitForTimeout(8000); await p.screenshot({ path: path.join(out, `${nm}.png`) });
  console.log('ne-GET:', big); await b.close();
})();
