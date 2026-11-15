// Přibalené knihovny appky bez internetu: model hloubky (transformers.js + wasm + q8 z /offline) a fonty.
// Předtím: python tools/offline.py <dir> a server na <dir>:  node toffline.js http://127.0.0.1:8766
const { chromium } = require('playwright-core');
(async () => {
  const base = process.argv[2] || 'http://127.0.0.1:8766';
  const b = await chromium.launch({ channel: 'chrome' });
  const ctx = await b.newContext({ serviceWorkers: 'block' });
  const ext = [];
  await ctx.route('**/*', r => { const u = r.request().url(); if (u.startsWith(base)) return r.continue(); ext.push(u); return r.abort(); });
  const p = await ctx.newPage();
  p.on('console', m => { if (m.type() === 'error') console.log('console:', m.text().slice(0, 200)); });
  p.on('response', r => { if (r.status() >= 400) console.log('404:', r.url()); });
  await p.goto(base + '/offline/fonts/fonts.css');
  const r = await p.evaluate(async () => {
    const T = await import('/offline/tf/transformers.min.js');
    T.env.allowLocalModels = true; T.env.localModelPath = '/offline/models/'; T.env.backends.onnx.wasm.wasmPaths = '/offline/tf/'; T.env.useBrowserCache = false;
    const pipe = await T.pipeline('depth-estimation', 'onnx-community/depth-anything-v2-small', { device: 'wasm', dtype: 'q8' });
    const c = new OffscreenCanvas(256, 192), g = c.getContext('2d'), gr = g.createLinearGradient(0, 0, 0, 192);
    gr.addColorStop(0, '#9cf'); gr.addColorStop(1, '#432'); g.fillStyle = gr; g.fillRect(0, 0, 256, 192); g.fillStyle = '#e33'; g.fillRect(90, 80, 70, 100);
    const img = await T.RawImage.fromBlob(await c.convertToBlob({ type: 'image/png' })), out = await pipe(img);
    const d = out.depth; let mn = 255, mx = 0; for (const v of d.data) { mn = Math.min(mn, v); mx = Math.max(mx, v); }
    return { w: d.width, h: d.height, mn, mx };
  });
  // fonty: stránka v appce (odkaz přepsaný na balíček)
  await p.goto(base + '/docs/preview/#nahled');
  await p.waitForTimeout(2500);
  const fonts = await p.evaluate(async () => { await document.fonts.ready; for (const f of ['Doto', 'Silkscreen']) { try { await document.fonts.load(`700 16px "${f}"`); } catch {} } return ['Geist', 'Geist Mono', 'Doto', 'Silkscreen'].map(f => f + ':' + document.fonts.check(`700 16px "${f}"`)); });
  console.log('hloubka', JSON.stringify(r));
  console.log('fonty', fonts.join(' '));
  console.log('požadavky ven (zablokované):', ext.length, ext.filter(u => !/demo|sun|geo/.test(u)).slice(0, 8));
  await b.close();
})();
