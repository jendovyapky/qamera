const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3000);
  // 40 velkých fotek (3000×4000 JPEG) rovnou do IndexedDB
  await p.evaluate(async () => { const db = await idb(); const cv = document.createElement('canvas'); cv.width = 3000; cv.height = 4000; const g = cv.getContext('2d');
    for (let i = 0; i < 40; i++) { const gr = g.createLinearGradient(0, 0, 3000, 4000); gr.addColorStop(0, `hsl(${i * 9},70%,50%)`); gr.addColorStop(1, `hsl(${i * 9 + 120},60%,30%)`); g.fillStyle = gr; g.fillRect(0, 0, 3000, 4000); g.fillStyle = '#fff'; g.font = '600px sans-serif'; g.fillText(i, 600, 2400);
      const blob = await new Promise(r => cv.toBlob(r, 'image/jpeg', .9)); await new Promise(r => { const t = db.transaction('photos', 'readwrite'); t.objectStore('photos').put({ id: 9000 + i, kind: 'import', tags: [], date: Date.now() - i * 1000, P: DEF(), blob, dirty: false }); t.oncomplete = r; }); } });
  await p.reload(); await p.waitForTimeout(6000);
  const mem = () => p.evaluate(() => { const px = S.photos.reduce((a, ph) => a + ph.src.width * ph.src.height + (ph.depth ? ph.depth.width * ph.depth.height : 0), 0); return { n: S.photos.length, MB: Math.round(px * 4 / 1048576), full: FULL.map(f => f.id), big: S.photos.filter(ph => Math.max(ph.src.width, ph.src.height) > 640).map(ph => ph.id) }; });
  console.log('po startu', JSON.stringify(await mem()));
  for (const id of [9000, 9001, 9002, 9003, 9004]) { await p.evaluate(id => { openEditor(S.photos.find(x => x.id === id)); }, id); await p.waitForTimeout(1200);
    console.log('editor', id, JSON.stringify(await p.evaluate(() => [S.cur.src.width, S.cur.src.height])), JSON.stringify(await mem())); }
  await p.screenshot({ path: 'mem_ed.png' });
  // export otevřené fotky
  await p.evaluate(() => exportMany([S.cur])); await p.waitForTimeout(6000);
  console.log('export', await p.evaluate(() => document.querySelector('.xmod #xSt').textContent));
  await p.evaluate(() => { document.querySelector('.xmod').remove(); go('gallery'); }); await p.waitForTimeout(1500); await p.screenshot({ path: 'mem_gal.png' });
  console.log('errors', errs);
  await p.evaluate(async () => { const db = await idb(); const t = db.transaction('photos', 'readwrite'); for (let i = 0; i < 40; i++) t.objectStore('photos').delete(9000 + i); });
  await b.close();
})();
