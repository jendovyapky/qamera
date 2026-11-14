// capGet: první dva pokusy o soubor ze serveru appky spadnou (jako po uspání iOS) → most dostane {kind:'server'} a třetí pokus projde
const { chromium } = require('playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'chrome' });
  const p = await b.newPage({ serviceWorkers: 'block' });
  let n = 0; await p.route('**/__cap/x.bin', r => (++n <= 2 ? r.abort('connectionreset') : r.fulfill({ body: 'hello' })));
  await p.goto('http://localhost:8765/docs/preview/#nahled'); await p.waitForTimeout(2500);
  const res = await p.evaluate(async () => { const msgs = []; window.webkit = { messageHandlers: { qamera: { postMessage: m => msgs.push(m.kind) } } };
    const bl = await capGet('/__cap/x.bin'); return [await bl.text(), msgs]; });
  console.log(res, 'pokusů', n); await b.close();
})();
