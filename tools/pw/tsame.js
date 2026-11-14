// Hledáček vs RAW: stejná scéna jako Apple JPEG (≈ obraz z videa ve WebKitu) a jako RAW (raw.js) → stejný film, vedle sebe
// node tsame.js FILM out dng apple.jpg   (jen Honzou dodané DNG, výstup mimo repo)
const { chromium } = require('playwright-core'); const fs = require('fs'), path = require('path');
(async () => {
  const [film, out, dng, jpg] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__f/*', r => r.fulfill({ body: fs.readFileSync(r.request().url().endsWith('/0') ? dng : jpg), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const res = await p.evaluate(async film => {
    const m = await import('./raw.js'), d = await m.developRaw(new File([await (await fetch('/__f/0')).blob()], 'x.dng'), () => {});
    const fit = c => { const k = 900 / Math.max(c.width, c.height), o = mk(Math.round(c.width * k), Math.round(c.height * k)); o.getContext('2d').drawImage(c, 0, 0, o.width, o.height); return o; };
    const raw = withHl(fit(d.canvas), d.hl ? fit(d.hl) : null), ap = fit(await decodeTo(await (await fetch('/__f/1')).blob(), 4000));
    const W = raw.width, H = raw.height, o = mk(W * 2, H * 2), g = o.getContext('2d');
    const P = Object.assign(camParams(), { film }); P.exp = 0;
    const row = (src, y, apl) => { g.drawImage(src, 0, y, W, H); if (!util.e || util.e.dead) utilReset(); g.drawImage(utilRender(src, Object.assign({}, P, { apl }), W, H, { seed: 5 }), W, y, W, H); };
    row(ap, 0, .5); row(raw, H, -.5); // Apple obraz se zpětným převodem jako hledáček (P.apl)
    g.font = 'bold 22px sans-serif'; g.fillStyle = '#ff0'; [['APPLE JPEG (jako hledáček)', 0, 0], ['+ ' + film, W, 0], ['RAW', 0, H], ['+ ' + film, W, H]].forEach(([t, x, y]) => g.fillText(t, x + 12, y + 30));
    return o.toDataURL('image/jpeg', .9);
  }, film);
  fs.writeFileSync(path.join(out, path.basename(dng) + '_same_' + film + '.jpg'), Buffer.from(res.split(',')[1], 'base64')); console.log('errors', errs); await b.close();
})();
