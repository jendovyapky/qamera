const { chromium } = require('playwright-core');
(async () => { const b = await chromium.launch({ channel: 'chrome' });
  for (const host of ['dev.qamera.pages.dev', 'qamera.pages.dev']) { const p = await (await b.newContext({ serviceWorkers: 'block' })).newPage(); await p.route(/qamera\.pages\.dev/, async rt => { const u = new URL(rt.request().url()); const r = await fetch('http://localhost:8765' + u.pathname); rt.fulfill({ status: r.status, headers: { 'content-type': r.headers.get('content-type') || '' }, body: Buffer.from(await r.arrayBuffer()) }); }); const errs = []; p.on('pageerror', e => errs.push(e.message));
    await p.goto(`https://${host}/docs/preview/#nahled`); await p.waitForTimeout(2500);
    const r = await p.evaluate(async () => { const m = document.querySelector('link[rel=manifest]').href; const j = await (await fetch(m)).json(); const ic = document.querySelector('link[rel=apple-touch-icon]').href; const ok = (await fetch(ic)).ok;
      return { title: document.title, apple: document.querySelector('meta[name=apple-mobile-web-app-title]').content, m: j.name, icon0: j.icons[0].src, ic, ok, iconOk: (await fetch(new URL(j.icons[2].src, m))).ok }; });
    console.log(host, JSON.stringify(r), errs); await p.close(); }
  await b.close(); })();
