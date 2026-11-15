// Boční tlačítko: web posílá objektivy / sílu a reaguje na __qCtl (lens, str, iso, dur, expo) – podvržený most
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' }), c = await b.newContext({ serviceWorkers: 'block', viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true }), p = await c.newPage();
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.addInitScript(() => { window.QNATIVE = { raw: 2, ncam: 1, tele: 4, teleCrop: 1 }; window.__m = [];
    window.webkit = { messageHandlers: { qamera: { postMessage: m => window.__m.push(m) } } }; });
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(3500);
  const r = await p.evaluate(async () => {
    const zb = () => [...document.querySelectorAll('#zoomGrp button')];
    natCtl(true); const first = __m.filter(m => m.op === 'ctl').pop();
    __qCtl('str', 55); const s1 = camSetOf(S.film), hud1 = $('#hud').textContent;
    natCtl(false); const after = __m.filter(m => m.op === 'ctl').pop();
    __qCtl('expo', [400, 0.008]); const hud2 = $('#hud').textContent;
    __qCtl('iso', 0); const hud3 = $('#hud').textContent; __qCtl('dur', 1 / 125); const hud4 = $('#hud').textContent;
    __qCtl('lens', 2); await new Promise(r => setTimeout(r, 600)); const on = zb().findIndex(b => b.classList.contains('on'));
    __qCtl('str', Math.round((filmBase(S.film).str ?? 1) * 100)); const s2 = camSetOf(S.film);
    return { lenses: first.lenses, lens: first.lens, str: first.str, s1, after: after.str, hud1, hud2, hud3, hud4, on, s2 }; });
  console.log(JSON.stringify(r, null, 1)); console.log('chyby', errs); await b.close();
})();
