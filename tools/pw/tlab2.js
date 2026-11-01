const { chromium } = require('playwright-core');
const fs = require('fs');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true, serviceWorkers: 'block' }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => localStorage.setItem('qamera.newsSeen', '"9"'));
  await p.goto('http://localhost:8765/docs/preview/'); await p.waitForTimeout(5000);
  // mřížka variant: řádky = 2 fotky, sloupce = varianty
  const url = await p.evaluate(() => {
    const V = [['základ', {}], ['neg −3', { nexp: -3 }], ['neg +3', { nexp: 3 }], ['POL', { lf: 'POL' }], ['85', { lf: '85' }], ['BW400', { film: 'BW400' }], ['BW+R', { film: 'BW400', lf: 'R' }], ['BW+G', { film: 'BW400', lf: 'G' }], ['HALF', { ffmt: 'half', grain: 1.2 }], ['4×5', { ffmt: '45', grain: 1.2 }]];
    const phs = [S.photos[0], S.photos.find(x => /noc|ulice|zapad/.test(x.kind || '')) || S.photos[3], S.photos[5]];
    const W = 200, H = 260, out = document.createElement('canvas'); out.width = W * V.length; out.height = (H + 18) * phs.length; const g = out.getContext('2d'); g.fillStyle = '#111'; g.fillRect(0, 0, out.width, out.height); g.font = '13px sans-serif';
    phs.forEach((ph, r) => V.forEach(([l, m], i) => { const P = Object.assign(JSON.parse(JSON.stringify(ph.P)), m); g.drawImage(utilRender(ph.src, P, W, H, {}), i * W, r * (H + 18) + 18); g.fillStyle = '#fff'; g.fillText(l, i * W + 6, r * (H + 18) + 14); }));
    return out.toDataURL('image/jpeg', .9); });
  fs.writeFileSync('lab_grid.jpg', Buffer.from(url.split(',')[1], 'base64'));
  // učení: 3 fotky, stejný film, Halation 40
  const learn = await p.evaluate(async () => { const out = []; for (const ph of S.photos.slice(0, 4)) { ph.P.film = 'P400'; openEditor(ph); await new Promise(r => setTimeout(r, 300)); S.P.hal = .4; commit(); out.push(document.querySelector('#toast').textContent); } return out; });
  await p.screenshot({ path: 'lab_learn.png' });
  const tb = await p.evaluate(() => { const b = document.querySelector('#toast button'); if (b) b.click(); return JSON.stringify(MYDEF); });
  const nb = await p.evaluate(() => [applyMyDef(Object.assign(DEF(), { film: 'P400' })).hal, camParams().film, camParams().hal]);
  // změna filmu: nesáhnutá fotka → výchozí nového filmu; Výchozí v panelu
  const sw = await p.evaluate(() => { const P = Object.assign(DEF(), { film: 'G200' }); swapFilm(P, 'P400'); const a = P.hal; P.hal = .9; swapFilm(P, 'G200'); return [a, P.hal]; });
  console.log({ learn, tb, nb, sw, errs });
  await b.close();
})();
