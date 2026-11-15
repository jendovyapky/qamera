// KLIP z appky: podvržený nativní most (QNATIVE.clip + webkit.messageHandlers) „natočí“ klip (webm z MediaRecorderu místo mp4)
// node tclip.js → clip_cam.png, clip_rec.png, clip_gal.png, clip_play.png
const { chromium } = require('playwright-core');
(async () => {
  const sm = await chromium.launch({ channel: 'chrome' }), sp = await sm.newPage();
  const vid = Buffer.from(await sp.evaluate(async () => { const c = document.createElement('canvas'); c.width = 360; c.height = 640; const g = c.getContext('2d');
    const rec = new MediaRecorder(c.captureStream(30), { mimeType: 'video/webm' }), ch = []; rec.ondataavailable = e => ch.push(e.data);
    rec.start(); const t0 = performance.now(); await new Promise(r => { const f = () => { const t = (performance.now() - t0) / 1000; g.fillStyle = `hsl(${t * 90},60%,45%)`; g.fillRect(0, 0, 360, 640); g.fillStyle = '#fff'; g.beginPath(); g.arc(180 + Math.sin(t * 3) * 120, 320, 40, 0, 7); g.fill(); t < 1.6 ? requestAnimationFrame(f) : r(); }; f(); });
    rec.stop(); await new Promise(r => rec.onstop = r); const b = new Blob(ch); return btoa(String.fromCharCode(...new Uint8Array(await b.arrayBuffer()))); }), 'base64');
  const jpg = Buffer.from(await sp.evaluate(() => { const c = document.createElement('canvas'); c.width = 1080; c.height = 1920; const g = c.getContext('2d'), gr = g.createLinearGradient(0, 0, 0, 1920);
    gr.addColorStop(0, '#3a6'); gr.addColorStop(1, '#fc8'); g.fillStyle = gr; g.fillRect(0, 0, 1080, 1920); return c.toDataURL('image/jpeg', .9).split(',')[1]; }), 'base64');
  await sm.close();
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true, permissions: ['camera'] }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__cap/*', r => { const n = r.request().url().split('/').pop(); r.fulfill({ body: n.endsWith('.jpg') ? jpg : vid, contentType: n.endsWith('.jpg') ? 'image/jpeg' : 'video/webm' }); });
  await p.addInitScript(() => {
    window.QNATIVE = { raw: 2, bayer: true, clip: 1, cedit: 1 }; window.__msgs = [];
    window.webkit = { messageHandlers: { qamera: { postMessage: m => { window.__msgs.push(m.kind === 'clip' ? JSON.stringify(m) : m.kind);
      if (m.kind === 'clip' && m.src) { setTimeout(() => window.__qClipProg(m.id, .4), 300); setTimeout(() => window.__qClip(m.id, true, { mp4: '/__cap/k2.mp4', jpg: '/__cap/k2.jpg', log: true, lensZoom: 1, src: m.src, same: true }), 900); }
      else if (m.kind === 'clip') { setTimeout(() => window.__qClipRec(m.id), 300); setTimeout(() => window.__qClipProg(m.id, .5), 5600); setTimeout(() => window.__qClip(m.id, true, { mp4: '/__cap/k.mp4', jpg: '/__cap/k.jpg', sjpg: '/__cap/k-s.jpg', src: 'ABC-123', log: true, lensZoom: 1 }), 6400); } } } } };
  });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  console.log('tlacitko KLIP', await p.evaluate(() => !$('#tClip').hidden));
  await p.evaluate(() => liveOn()); await p.waitForTimeout(1500);
  await p.evaluate(() => { setFilm('P400C'); $('#tClip').click(); }); await p.waitForTimeout(600);
  console.log('ok', await p.evaluate(() => [CAM.live, S.nclip, nativeClipOk()]));
  await p.screenshot({ path: 'clip_cam.png' });
  const n0 = await p.evaluate(() => S.photos.length);
  await p.evaluate(() => __qShutter()); await p.waitForTimeout(2500);
  await p.screenshot({ path: 'clip_rec.png' });
  for (let i = 0; i < 40; i++) { await p.waitForTimeout(400); if (await p.evaluate(() => !S.busy)) break; }
  await p.waitForTimeout(800);
  console.log(JSON.stringify(await p.evaluate(n0 => { const ph = S.photos[0]; return { pridano: S.photos.length - n0, film: ph.film, tags: ph.tags, clip: ph.clip && ph.clip.size, P: [ph.P.film, ph.P.cf, ph.P.clog], live: CAM.live, msgs: __msgs }; }, n0)));
  await p.evaluate(() => go('gallery')); await p.waitForTimeout(1200); await p.screenshot({ path: 'clip_gal.png' });
  await p.evaluate(() => document.querySelector('.gitem').click()); await p.waitForTimeout(1200);
  console.log('video', await p.evaluate(() => { const v = $('.clipv video'); return v && [v.readyState, v.paused, v.videoWidth]; }));
  await p.screenshot({ path: 'clip_play.png' });
  // úprava filmu u klipu (appka má originál): Film → výběr s náhledem → Vyvolat
  console.log('originál', await p.evaluate(() => { const ph = S.photos[0]; return [ph.csrc, ph.cframe && ph.cframe.size, Object.keys(ph.P.cp || {}).join(',')]; }));
  await p.evaluate(() => $('.clipv [data-a="u"]').click()); await p.waitForTimeout(900);
  console.log('filmy v řadě', await p.evaluate(() => [$$('.clipv .clipfs button').length, $('.clipv .clipfs button.on').dataset.f, !$('.clipv .clipp').hidden]));
  await p.evaluate(() => [...$$('.clipv .clipfs button')].find(b => b.dataset.f === 'TX400').click()); await p.waitForTimeout(700);
  await p.screenshot({ path: 'clip_edit.png' });
  await p.evaluate(() => $('.clipv [data-a="g"]').click()); await p.waitForTimeout(500); await p.screenshot({ path: 'clip_edit_busy.png' }); await p.waitForTimeout(2500);
  console.log('po vyvolání', await p.evaluate(() => { const ph = S.photos[0]; return [ph.film, ph.P.cf, ph.clip.size, $('.clipv .clipfs').hidden, !$('.clipv video').hidden, __msgs.filter(x => x.includes('"src"')).map(x => { const m = JSON.parse(x); return [m.film, m.src, m.grain, m.same]; })]; }));
  await p.screenshot({ path: 'clip_edit_done.png' });
  // znovu načtení z IndexedDB
  await p.reload(); await p.waitForTimeout(4000);
  console.log('po reloadu', await p.evaluate(() => { const ph = S.photos.find(x => x.clip); return ph && [ph.film, ph.clip.size, ph.P.cf, ph.csrc, !!ph.cframe]; }));
  await p.evaluate(async () => { for (const ph of S.photos.filter(x => x.clip)) await dbDel(ph.id); });
  console.log('errors', errs);
  await b.close();
})();
