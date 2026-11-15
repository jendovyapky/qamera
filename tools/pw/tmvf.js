// Hledáček v Metalu (podvržený most): web posílá obdélník a vzhled, po __qMvf(true) přestane kreslit sám; dlouhý čas → zpět na web.
// Natočení ikon (__qOrient) a přední kamera běžná / celý senzor (0,5×).  node tmvf.js (server na :8765)
const { chromium } = require('playwright-core');
(async () => {
  const sm = await chromium.launch({ channel: 'chrome' }), sp = await sm.newPage();
  const frame = Buffer.from(await sp.evaluate(() => { const c = document.createElement('canvas'); c.width = 720; c.height = 960; const g = c.getContext('2d'); g.fillStyle = '#7aa6c8'; g.fillRect(0, 0, 720, 960); return c.toDataURL('image/jpeg', .85).split(',')[1]; }), 'base64');
  await sm.close();
  const meta = Buffer.from(JSON.stringify({ w: 720, h: 960, log: true, lens: 'wide' }));
  const h = Buffer.alloc(6); h.writeUInt32BE(2 + meta.length + frame.length, 0); h.writeUInt16BE(meta.length, 4);
  const one = Buffer.concat([h, meta, frame]), body = Buffer.concat(Array(30).fill(one));
  const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__live', r => r.fulfill({ body, contentType: 'application/octet-stream' }));
  await p.addInitScript(() => {
    window.QNATIVE = { raw: 2, clip: 1, crec: 1, ncam: 1, mvf: 1 }; window.__m = [];
    window.webkit = { messageHandlers: { qamera: { postMessage: m => { if (m.kind === 'ncam') window.__m.push(Object.assign({}, m, m.lut ? { lut: m.lut.length } : {}));
      if (m.kind === 'ncam' && m.op === 'start') setTimeout(() => window.__qCam(m.id, true, { log: true, lens: m.lens, lensZoom: 1, w: 720, h: 960, maxZoom: 8, torch: true, label: 'Cam' }), 150); } } } };
  });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  await p.evaluate(() => liveOn()); await p.waitForTimeout(1500);
  const vfs = () => p.evaluate(() => __m.filter(m => m.op === 'vf'));
  const last = async () => { const v = await vfs(); return v[v.length - 1]; };
  console.log('vf', JSON.stringify(await last()));
  console.log('uni', JSON.stringify(await p.evaluate(() => { const l = __m.filter(m => m.op === 'uni'); const x = l[l.length - 1]; return x && { n: l.length, lut: x.lut, curve: (x.curve || '').length, pocet: Object.keys(x.u).length, uExp: x.u.uExp, uGE: x.u.uGE, uHsl: (x.u.uHsl || []).length, uEst: x.u.uEst, uLF: x.u.uLF, uGN: x.u.uGN, uStr: x.u.uStr }; })));
  console.log('klíče', await p.evaluate(() => { const l = __m.filter(m => m.op === 'uni'); return Object.keys(l[l.length - 1].u).sort().join(' '); }));
  // bez potvrzení appky web kreslí dál
  const rc = async () => p.evaluate(async () => { let n = 0; const o = camE.render; camE.render = function () { n++; return o.apply(this, arguments); }; await new Promise(r => setTimeout(r, 500)); camE.render = o; return n; });
  console.log('render před potvrzením', await rc(), 'třída', await p.evaluate(() => document.documentElement.className));
  await p.evaluate(() => __qMvf(true));
  console.log('render po potvrzení', await rc(), 'třída', await p.evaluate(() => document.documentElement.className), 'pozadí', await p.evaluate(() => getComputedStyle(document.querySelector('#vf')).backgroundColor));
  // změna EV → nová tabulka
  const n0 = await p.evaluate(() => __m.filter(m => m.op === 'uni').length);
  await p.evaluate(() => { S.ev = 1; updLcd(); }); await p.waitForTimeout(400);
  console.log('nové hodnoty po EV', (await p.evaluate(() => __m.filter(m => m.op === 'uni').length)) - n0, await p.evaluate(() => { const l = __m.filter(m => m.op === 'uni'); return l[l.length - 1].u.uExp; }));
  // dlouhý čas → web kreslí sám
  await p.evaluate(() => { S.timeIdx = 2; }); await p.waitForTimeout(300);
  console.log('dlouhý čas: vf.on', (await last()).on, 'třída', JSON.stringify(await p.evaluate(() => document.documentElement.className)), 'render', await rc());
  await p.evaluate(() => { S.timeIdx = 0; }); await p.waitForTimeout(300);
  console.log('zpět AUTO: vf.on', (await last()).on);
  // natočení ikon
  await p.evaluate(() => __qOrient(270)); await p.waitForTimeout(100);
  console.log('orot 270', await p.evaluate(() => getComputedStyle(document.querySelector('#s-camera')).getPropertyValue('--orot')), 'zoom popisky', await p.evaluate(() => [...document.querySelectorAll('#zoomGrp .zr')].map(e => e.textContent).join(' ')));
  await p.evaluate(() => __qOrient(0)); await p.waitForTimeout(100);
  console.log('orot 0', await p.evaluate(() => getComputedStyle(document.querySelector('#s-camera')).getPropertyValue('--orot')));
  await p.evaluate(() => __qOrient(90)); await p.waitForTimeout(700);
  await p.screenshot({ path: 'mvf_orient.png' });
  // přední kamera: 0,5× = celý senzor
  await p.evaluate(() => { CAM.facing = 'user'; return liveOn(); }); await p.waitForTimeout(1500);
  console.log('přední: tlačítka', await p.evaluate(() => [...document.querySelectorAll('#zoomGrp button')].filter(b => getComputedStyle(b).display !== 'none').map(b => b.textContent + (b.classList.contains('on') ? '*' : '')).join(' ')));
  await p.evaluate(() => setZoom(.5)); await p.waitForTimeout(1500);
  const st = await p.evaluate(() => __m.filter(m => m.op === 'start').map(m => m.lens + ':' + m.full).join(' '));
  console.log('starty', st, 'tlačítka', await p.evaluate(() => [...document.querySelectorAll('#zoomGrp button')].filter(b => getComputedStyle(b).display !== 'none').map(b => b.textContent + (b.classList.contains('on') ? '*' : '')).join(' ')), 'vf.mir', (await last()).mir);
  await p.evaluate(() => __qMvf(false, 'test')); await p.waitForTimeout(200);
  console.log('chyba Metalu → třída', JSON.stringify(await p.evaluate(() => document.documentElement.className)), 'vf.on', (await last()).on);
  console.log('chyby', errs);
  await b.close();
})();
