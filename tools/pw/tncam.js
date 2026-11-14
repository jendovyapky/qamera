// Vlastní kamera appky (QNATIVE.ncam): podvržený most + /__live (pakety: u32 délka, u16 délka meta, meta JSON, JPEG)
// node tncam.js → ncam_live.png, ncam_after.png
const { chromium } = require('playwright-core');
(async () => {
  const sm = await chromium.launch({ channel: 'chrome' }), sp = await sm.newPage();
  const frames = (await sp.evaluate(() => Array.from({ length: 6 }, (_, i) => { const c = document.createElement('canvas'); c.width = 720; c.height = 960; const g = c.getContext('2d'), gr = g.createLinearGradient(0, 0, 0, 960);
    gr.addColorStop(0, '#7aa6c8'); gr.addColorStop(.55, '#c9b89a'); gr.addColorStop(1, '#3d4a2a'); g.fillStyle = gr; g.fillRect(0, 0, 720, 960);
    g.fillStyle = '#222'; g.fillRect(80 + i * 20, 500, 220, 300); g.fillStyle = '#fff'; g.beginPath(); g.arc(520, 260, 26, 0, 7); g.fill();
    return c.toDataURL('image/jpeg', .85).split(',')[1]; }))).map(b => Buffer.from(b, 'base64'));
  const jpg = Buffer.from(await sp.evaluate(() => { const c = document.createElement('canvas'); c.width = 1512; c.height = 2016; const g = c.getContext('2d'); g.fillStyle = '#8a7'; g.fillRect(0, 0, 1512, 2016); g.fillStyle = '#fff'; g.beginPath(); g.arc(1100, 540, 60, 0, 7); g.fill(); return c.toDataURL('image/jpeg', .9).split(',')[1]; }), 'base64');
  await sm.close();
  const meta = Buffer.from(JSON.stringify({ w: 720, h: 960, log: true, lens: 'wide' }));
  const pkt = f => { const h = Buffer.alloc(6); h.writeUInt32BE(2 + meta.length + f.length, 0); h.writeUInt16BE(meta.length, 4); return Buffer.concat([h, meta, f]); };
  const body = Buffer.concat(frames.map(pkt));
  const b = await chromium.launch({ channel: 'chrome' });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  let lives = 0;
  await p.route('**/__live', r => { lives++; r.fulfill({ body, contentType: 'application/octet-stream' }); });
  await p.route('**/__cap/*', r => r.fulfill({ body: jpg, contentType: 'image/jpeg' }));
  await p.addInitScript(() => {
    window.QNATIVE = { raw: 2, bayer: true, clip: 1, ncam: 1 }; window.__msgs = [];
    window.webkit = { messageHandlers: { qamera: { postMessage: m => { window.__msgs.push(m.kind + (m.op ? ':' + m.op : ''));
      if (m.kind === 'ncam' && m.op === 'start') setTimeout(() => window.__qCam(m.id, true, { log: true, lens: m.lens, lensZoom: m.lens === 'ultra' ? .5 : 1, w: 720, h: 960, maxZoom: 8, torch: true, label: 'Back Camera' }), 200);
      if (m.kind === 'still') setTimeout(() => window.__qRaw(m.id, true, { jpg: '/__cap/s.jpg', label: 'LOG', lensZoom: 1, ev: 0 }), 300); } } } };
  });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  console.log('liveOn', await p.evaluate(() => liveOn()), await p.evaluate(() => [CAM.err, NATCAM]));
  await p.waitForTimeout(1500);
  console.log(JSON.stringify(await p.evaluate(() => ({ nat: CAM.nat, live: CAM.live, nlog: CAM.nlog, vw: CAM.video.videoWidth, vh: CAM.video.videoHeight, apl: camParams().apl, sh: LIVE.canvas._sh, track: CAM.track.label }))));
  console.log('live požadavků', lives);
  await p.screenshot({ path: 'ncam_live.png' });
  const n0 = await p.evaluate(() => S.photos.length);
  await p.evaluate(() => __qShutter()); await p.waitForTimeout(400);
  console.log('během focení live', await p.evaluate(() => [CAM.live, CAM.nat, CAM.switching]));
  for (let i = 0; i < 30; i++) { await p.waitForTimeout(300); if (await p.evaluate(() => !S.busy)) break; }
  await p.waitForTimeout(600);
  console.log(JSON.stringify(await p.evaluate(n0 => { const ph = S.photos[0]; return { pridano: S.photos.length - n0, raw: ph.raw, apl: ph.P.apl, hl: !!ph.hl, live: CAM.live, nat: CAM.nat }; }, n0)));
  // přepnutí objektivu a zoom
  await p.evaluate(() => setZoom(.5)); await p.waitForTimeout(1500);
  console.log('ultra', await p.evaluate(() => [CAM.nat, CAM.live, CAM.deviceId, CAM.ultra]));
  await p.screenshot({ path: 'ncam_after.png' });
  console.log('msgs', await p.evaluate(() => __msgs.join(' ')));
  console.log('ctl', await p.evaluate(() => { const f0 = S.film; __qCtl('film', 2); const f1 = S.film; __qCtl('ev', -1); return [f0, f1, filmsOrdered()[2].code, S.ev, $('#pEv').textContent, +liveMean().toFixed(4)]; }));
  console.log('chyby', errs);
  await b.close();
})();
