const { chromium } = require('playwright-core');
(async () => { const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' }); const errs = [];
  const px = (p, gv) => p.evaluate(gv => { const out = []; for (const ph of S.photos.filter(x => !x.saved).slice(0, 6)) { const P = JSON.parse(JSON.stringify(ph.P)); P.hal = 1.5; P.bloom = .6; P.glow = .5; if (gv) P.gv = gv; const cv = utilRender(ph.src, P, 160, 200, { seed: 7 }), k = document.createElement('canvas'); k.width = 160; k.height = 200; k.getContext('2d').drawImage(cv, 0, 0); out.push(Array.from(k.getContext('2d').getImageData(0, 0, 160, 200).data)); } return out; }, gv);
  // 1) stará verze: importovaná fotka se uloží do IndexedDB bez gv
  let p = await c.newPage(); p.on('pageerror', e => errs.push('old ' + e.message));
  await p.addInitScript(() => localStorage.setItem('qamera.newsSeen', '"9"'));
  await p.goto('http://localhost:8765/docs/preview/_main.html'); await p.waitForTimeout(5000);
  const old = await px(p, 0);
  await p.evaluate(async () => { const c = document.createElement('canvas'); c.width = 400; c.height = 500; const g = c.getContext('2d'); g.fillStyle = '#222'; g.fillRect(0, 0, 400, 500); g.fillStyle = '#fff'; g.beginPath(); g.arc(200, 200, 30, 0, 7); g.fill();
    const blob = await new Promise(r => c.toBlob(r, 'image/jpeg', .95)); await importFiles([new File([blob], 'x.jpg', { type: 'image/jpeg' })]); });
  await p.waitForTimeout(2500); await p.close();
  // 2) nová verze na stejném úložišti
  p = await c.newPage(); p.on('pageerror', e => errs.push('new ' + e.message));
  await p.goto('http://localhost:8765/docs/preview/index.html'); await p.waitForTimeout(6000);
  const gvs = await p.evaluate(() => [S.photos.filter(x => x.saved).map(x => x.P.gv), S.photos.filter(x => !x.saved).slice(0, 3).map(x => x.P.gv), DEF().gv, camParams().gv]);
  const neu1 = await px(p, 1), neu2 = await px(p, 2);
  const diff = (a, b) => { let m = 0, s = 0, n = 0; a.forEach((x, i) => x.forEach((v, j) => { if (j % 4 === 3) return; const d = Math.abs(v - b[i][j]); m = Math.max(m, d); s += d; n++; })); return [m, +(s / n).toFixed(2)]; };
  // demo fotky se generují stejně → stará verze vs nová s gv=1 musí být (skoro) stejná
  console.log({ gvs, staraVsGv1: diff(old, neu1), staraVsGv2: diff(old, neu2), errs });
  await b.close(); })();
