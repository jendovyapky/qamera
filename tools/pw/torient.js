// Telefon na šířku (__qOrient z akcelerometru appky) → fotka na šířku; klip start / stop spouští (až 60 s), mikrofon jen v režimu KLIP
// node torient.js (server na :8765)
const { chromium } = require('playwright-core');
(async () => {
  const sm = await chromium.launch({ channel: 'chrome' }), sp = await sm.newPage();
  const frame = Buffer.from(await sp.evaluate(() => { const c = document.createElement('canvas'); c.width = 720; c.height = 960; const g = c.getContext('2d'); g.fillStyle = '#7aa6c8'; g.fillRect(0, 0, 720, 960); g.fillStyle = '#222'; g.fillRect(100, 500, 220, 300); return c.toDataURL('image/jpeg', .85).split(',')[1]; }), 'base64');
  const jpg = Buffer.from(await sp.evaluate(() => { const c = document.createElement('canvas'); c.width = 1512; c.height = 2016; const g = c.getContext('2d'); g.fillStyle = '#8a7'; g.fillRect(0, 0, 1512, 2016); g.fillStyle = '#f00'; g.fillRect(0, 0, 300, 300); return c.toDataURL('image/jpeg', .9).split(',')[1]; }), 'base64');
  await sm.close();
  const meta = Buffer.from(JSON.stringify({ w: 720, h: 960, log: true, lens: 'wide' }));
  const h = Buffer.alloc(6); h.writeUInt32BE(2 + meta.length + frame.length, 0); h.writeUInt16BE(meta.length, 4);
  const one = Buffer.concat([h, meta, frame]), body = Buffer.concat([one, one, one, one]);
  const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__live', r => r.fulfill({ body, contentType: 'application/octet-stream' }));
  await p.route('**/__cap/*.mp4', r => r.fulfill({ body: Buffer.alloc(4000, 1), contentType: 'video/mp4' }));
  await p.route('**/__cap/*.jpg', r => r.fulfill({ body: jpg, contentType: 'image/jpeg' }));
  await p.addInitScript(() => {
    window.QNATIVE = { raw: 2, bayer: true, clip: 1, crec: 1, ncam: 1 }; window.__msgs = []; window.__clipMsg = null;
    window.webkit = { messageHandlers: { qamera: { postMessage: m => { window.__msgs.push(m.kind + (m.op ? ':' + m.op + (m.op === 'audio' ? '=' + m.on : '') : ''));
      if (m.kind === 'ncam' && m.op === 'start') setTimeout(() => window.__qCam(m.id, true, { log: true, lens: m.lens, lensZoom: 1, w: 720, h: 960, maxZoom: 8, torch: true, label: 'Back Camera' }), 200);
      if (m.kind === 'still') setTimeout(() => window.__qRaw(m.id, true, { jpg: '/__cap/s.jpg', label: 'LOG', lensZoom: 1, ev: 0 }), 300);
      if (m.kind === 'clip') { const x = Object.assign({}, m); delete x.lut; window.__clipMsg = x; setTimeout(() => window.__qClipRec(m.id), 200); }
      if (m.kind === 'clipStop') { const id = window.__clipMsg.id; setTimeout(() => { window.__qClipProg(id, .5); window.__qClip(id, true, { mp4: '/__cap/c.mp4', jpg: '/__cap/c.jpg', log: true, lensZoom: 1, same: true }); }, 300); } } } } };
  });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  await p.evaluate(() => liveOn()); await p.waitForTimeout(1500);
  const shot = async () => { const n0 = await p.evaluate(() => S.photos.length); await p.evaluate(() => __qShutter());
    for (let i = 0; i < 30; i++) { await p.waitForTimeout(300); if (await p.evaluate(() => !S.busy)) break; } await p.waitForTimeout(500);
    return p.evaluate(n0 => { const ph = S.photos[0], d = ph.src.getContext('2d').getImageData(4, 4, 1, 1).data; return { nove: S.photos.length - n0, w: ph.src.width, h: ph.src.height, roh: [d[0], d[1], d[2]] }; }, n0); };
  console.log('na výšku', JSON.stringify(await shot()));
  await p.evaluate(() => __qOrient(90)); console.log('doprava 90°', JSON.stringify(await shot()));
  await p.evaluate(() => __qOrient(270)); console.log('doleva 270°', JSON.stringify(await shot()));
  // klip: režim KLIP zapne mikrofon, spoušť start, za 2 s znovu spoušť = stop
  await p.evaluate(() => { S.nclip = true; S.nraw = false; updModes(); });
  const n0 = await p.evaluate(() => S.photos.length);
  await p.evaluate(() => __qShutter()); await p.waitForTimeout(2200);
  const hudTxt = await p.evaluate(() => { const e = document.querySelector('#hud'); return e ? e.textContent.trim() : '?'; });
  await p.evaluate(() => __qShutter());
  for (let i = 0; i < 30; i++) { await p.waitForTimeout(300); if (await p.evaluate(() => !S.busy)) break; } await p.waitForTimeout(800);
  console.log('klip msg', JSON.stringify(await p.evaluate(() => { const m = __clipMsg; return { sec: m.sec, rot: m.rot, same: m.same }; })), 'hud', JSON.stringify(hudTxt));
  console.log('klip', JSON.stringify(await p.evaluate(n0 => { const ph = S.photos[0]; return { nove: S.photos.length - n0, clip: !!ph.clip, crot: ph.P.crot, busy: S.busy }; }, n0)));
  await p.evaluate(() => { S.nclip = false; updModes(); });
  console.log('msgs', await p.evaluate(() => __msgs.filter(m => !/^log|ctl/.test(m)).join(' ')));
  console.log('chyby', errs);
  await b.close();
})();
