// Hledáček × RAW fotka na Honzových souborech: snímek hledáčku (Apple Log převedený jako v CameraEngine → viewsrc.png) a DNG stejné scény.
// node tmatch.js FILM out_dir viewsrc.png foto.dng   → view_FILM.jpg, raw_FILM.jpg (výřez + srovnání na hledáček), rawold_FILM.jpg (postup 0.18.34)
const { chromium } = require('playwright-core');
const fs = require('fs'), path = require('path');
(async () => {
  const [film, out, vsrc, dng] = process.argv.slice(2);
  const b = await chromium.launch({ channel: 'chrome', args: ['--use-gl=angle'] });
  const p = await b.newPage({ serviceWorkers: 'block', viewport: { width: 1440, height: 900 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/__f/*', r => r.fulfill({ body: fs.readFileSync(r.request().url().endsWith('/0') ? vsrc : dng), contentType: 'application/octet-stream' }));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(4000);
  const res = await p.evaluate(async film => {
    const vb = await (await fetch('/__f/0')).blob(), view0 = await decodeTo(vb, 4096), view = cropAr(view0, .75, 1); view._sh = true;
    CAM.nat = CAM.nlog = true; LIVE.canvas = view0; const mean = liveMean(), ref = viewRef(.75, 1); CAM.nat = CAM.nlog = false;
    globalThis.__qRawMean = mean;
    const m = await import('./raw.js'), d = await m.developRaw(new File([await (await fetch('/__f/1')).blob()], 'x.dng', { type: 'image/x-adobe-dng' }), () => {});
    const old0 = cropAr(d.canvas, .75, 1), full = cropLikeView(d.canvas, .75, 1, view0.width / view0.height), gains = matchGains(ref, full); applyGains(full, gains);
    const sm = c => { const k = 1500 / Math.max(c.width, c.height), s = mk(Math.round(c.width * k), Math.round(c.height * k)); s.getContext('2d').drawImage(c, 0, 0, s.width, s.height); if (c._sh) s._sh = true; return s; };
    const rn = (c, P) => { if (!util.e || util.e.dead) utilReset(); return copyCanvas(utilRender(c, P, c.width, c.height, { seed: 7 })).toDataURL('image/jpeg', .92); };
    const Pn = Object.assign(DEF(), { film }), Po = Object.assign(DEF(), { film, apl: -.5, grv: 1 });
    const v = sm(view), f = sm(full), o = sm(old0);
    return { mean, gains, view: rn(v, Pn), raw: rn(f, Pn), rawold: rn(o, Po), viewold: rn(v, Po), rawplain: f.toDataURL('image/jpeg', .92), viewplain: v.toDataURL('image/jpeg', .92) };
  }, film);
  for (const k of ['view', 'raw', 'rawold', 'viewold', 'rawplain', 'viewplain']) fs.writeFileSync(path.join(out, k + '_' + film + '.jpg'), Buffer.from(res[k].split(',')[1], 'base64'));
  console.log('mean', res.mean, 'gains', res.gains, 'chyby', errs); await b.close();
})();
