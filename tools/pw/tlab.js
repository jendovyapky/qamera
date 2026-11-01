const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, serviceWorkers: 'block' }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.addInitScript(() => localStorage.setItem('qamera.newsSeen', '"9"'));
  await p.goto('http://localhost:8765/docs/preview/'); await p.waitForTimeout(5000);
  // průměrná barva vyrenderované fotky s danými parametry
  const avg = mod => p.evaluate(m => { const ph = S.photos[0], P = Object.assign(JSON.parse(JSON.stringify(ph.P)), m); const cv0 = utilRender(ph.src, P, 120, 160, {}), cv = document.createElement('canvas'); cv.width = 120; cv.height = 160; cv.getContext('2d').drawImage(cv0, 0, 0); const d = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data;
    let r = 0, g = 0, bb = 0, sd = 0, n = d.length / 4; for (let i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; bb += d[i + 2]; } r /= n; g /= n; bb /= n;
    let dark = 0; for (let i = 0; i < d.length; i += 4) if (d[i] + d[i + 1] + d[i + 2] < 60) dark++; return [r, g, bb].map(Math.round).concat([+(dark / n).toFixed(3)]); }, mod);
  const res = {
    base: await avg({}), lat0: await avg({ nexp: 0 }), latM3: await avg({ nexp: -3 }), latP3: await avg({ nexp: 3 }),
    pol: await avg({ lf: 'POL' }), f85: await avg({ lf: '85' }), f80: await avg({ lf: '80' }),
    bw: await avg({ film: 'BW400' }), bwR: await avg({ film: 'BW400', lf: 'R' }), bwG: await avg({ film: 'BW400', lf: 'G' }),
    half: await avg({ ffmt: 'half' }), f45: await avg({ ffmt: '45' }),
  };
  console.log(res);
  // editor: panel filmu
  await p.evaluate(() => openEditor(S.photos[0])); await p.waitForTimeout(1200);
  await p.evaluate(() => { S.filmOpen = true; setTab('film'); }); await p.waitForTimeout(900);
  await p.screenshot({ path: 'lab_panel.png' });
  await p.evaluate(() => document.querySelector('[data-fkseg=lf] button[data-v="85"]').click()); await p.waitForTimeout(200);
  const lf = await p.evaluate(() => [S.P.lf, S.cur.P.lf]);
  await p.evaluate(() => document.querySelector('.fxp').scrollTop = 999); await p.waitForTimeout(200); await p.screenshot({ path: 'lab_panel2.png' });
  // učení: 3 fotky s Halation 40
  const learn = await p.evaluate(async () => { const out = []; for (const ph of S.photos.filter(x => x.P.film === S.photos[0].P.film).slice(0, 4)) { openEditor(ph); await new Promise(r => setTimeout(r, 300)); S.P.hal = .4; commit(); out.push(document.querySelector('#toast').textContent); } return out; });
  const tb = await p.evaluate(() => { const b = document.querySelector('#toast button'); if (b) b.click(); return JSON.stringify(MYDEF); });
  // nová fotka po importu by měla mít hal .4
  const nb = await p.evaluate(() => applyMyDef(Object.assign(DEF(), { film: S.photos[0].P.film })).hal);
  console.log({ lf, learn, tb, nb, errs: errs.slice(0, 5) });
  await c.close();
  // PC
  const c2 = await b.newContext({ viewport: { width: 1440, height: 900 }, serviceWorkers: 'block' }), p2 = await c2.newPage(); p2.on('pageerror', e => errs.push('pc ' + e.message));
  await p2.addInitScript(() => localStorage.setItem('qamera.newsSeen', '"9"'));
  await p2.goto('http://localhost:8765/docs/preview/'); await p2.waitForTimeout(6000);
  await p2.evaluate(() => { openPc && openPc(S.photos[0]); }); await p2.waitForTimeout(1200);
  await p2.evaluate(() => document.querySelector('#pcFLab').scrollIntoView()); await p2.waitForTimeout(300);
  await p2.screenshot({ path: 'lab_pc.png' });
  console.log('pc errs', errs);
  await b.close();
})();
