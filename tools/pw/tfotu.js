// Srovnání s Fotufilm (webové demo, běží v prohlížeči): otevře fotku, vybere film, uloží screenshot plochy
// node tfotu.js out foto.png "Film1,Film2"   (hlídá síťové požadavky – fotka nesmí odejít ven)
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
(async () => {
  const [out, img, films = ''] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', headless: false, args: ['--enable-unsafe-webgpu'] });
  const c = await b.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 2 }), p = await c.newPage();
  const big = []; p.on('request', r => { const d = r.postDataBuffer(); if (r.method() !== 'GET' || (d && d.length > 2000)) big.push(r.method() + ' ' + r.url().slice(0, 100) + ' ' + (d ? d.length : 0)); });
  await p.goto('https://fotufilm.com/demo/'); await p.waitForTimeout(25000);
  await p.screenshot({ path: path.join(out, 'f_0.png') });
  const fc = p.waitForEvent('filechooser', { timeout: 15000 });
  await p.mouse.click(800, 500); // „Open image or video“ uprostřed plochy
  (await fc).setFiles(img); await p.waitForTimeout(/\.dng$/i.test(img) ? 60000 : 15000);
  await p.screenshot({ path: path.join(out, 'f_1.png') });
  let i = 2;
  for (const f of films.split(',').filter(Boolean)) {
    await p.mouse.click(120, 92); await p.keyboard.press('Control+A'); await p.keyboard.type(f); await p.waitForTimeout(1500);
    await p.mouse.click(120, 135); await p.waitForTimeout(12000);
    await p.screenshot({ path: path.join(out, `f_${i++}_${f.replace(/\W/g, '')}.png`) });
  }
  console.log('požadavky ne-GET / s daty:', big); await b.close();
})();
