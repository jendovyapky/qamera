const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 390, height: 844 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  await p.mouse.click(195, 400); await p.waitForTimeout(1500);
  const run = async (label, fail) => {
    const r = await p.evaluate(async (fail) => {
      document.querySelectorAll('.xmod').forEach(x => x.remove());
      if (fail) { const o = HTMLCanvasElement.prototype.getContext; let n = 0; HTMLCanvasElement.prototype.getContext = function (t, a) { if (t === '2d' && this.width >= 200 && n++ < fail) return null; return o.call(this, t, a); }; window._restore = () => HTMLCanvasElement.prototype.getContext = o; }
      const ph = S.photos.find(p => p.kind !== 'arch'); exportMany([ph]);
      for (let t = 0; t < 200; t++) { await new Promise(r => setTimeout(r, 100)); const m = document.querySelector('.xmod'); if (m && (m.classList.contains('done') || m.classList.contains('fail'))) break; }
      window._restore && window._restore(); window._restore = null;
      const m = document.querySelector('.xmod'); return { cls: m.className, st: m.querySelector('#xSt').textContent, pct: m.querySelector('#xPct').textContent, err: (m.querySelector('.xerr') || {}).textContent, go: m.querySelector('#xGo').textContent, util: [util.e.c.width, util.e.c.height] };
    }, fail);
    console.log(label, JSON.stringify(r)); await p.screenshot({ path: `exp_${label}.png` });
  };
  await run('ok', 0); await run('retry', 1); await run('fail', 99); await run('after', 0);
  console.log('errors', errs); await b.close();
})();
