const { chromium } = require('playwright-core');
const fs = require('fs');
// syntetická scéna jako Honzův snímek: tmavý stůl, červeně podsvícená klávesnice (sytá červená, kanál R ořezaný), LED pásek, šedý monitor
const scene = () => { const c = document.createElement('canvas'); c.width = 900; c.height = 1200; const g = c.getContext('2d');
  g.fillStyle = '#120b0a'; g.fillRect(0, 0, 900, 1200);
  g.fillStyle = '#20252c'; g.fillRect(0, 0, 820, 480); g.fillStyle = '#ffffff'; for (let i = 0; i < 9; i++) g.fillRect(40, 60 + i * 45, 300 + (i * 97) % 380, 5);
  const cols = ['#ffffff', '#ff4040', '#ffd040', '#ff60ff', '#40a0ff', '#ffffff'];
  for (let i = 0; i < 30; i++) { g.fillStyle = cols[i % cols.length]; g.beginPath(); g.ellipse(30 + i * 27, 510, 8, 11, 0, 0, 7); g.fill(); }
  g.fillStyle = '#5a0a04'; g.fillRect(0, 540, 900, 300); g.fillStyle = '#ff2a10'; g.fillRect(380, 560, 110, 140); g.fillRect(560, 560, 110, 180);
  for (let r = 0; r < 6; r++) for (let k = 0; k < 14; k++) { g.fillStyle = '#ff1e08'; g.fillRect(60 + k * 34, 830 + r * 48, 26, 6); g.fillStyle = '#ff6a20'; g.fillRect(60 + k * 34, 836 + r * 48, 26, 3); }
  return c; };
(async () => {
  const b = await chromium.launch({ channel: 'chrome' }); const shots = {};
  for (const [name, path] of [['dev', 'index.html']]) {
    const c = await b.newContext({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' }), p = await c.newPage();
    await p.addInitScript(() => localStorage.setItem('qamera.newsSeen', '"9"'));
    await p.goto('http://localhost:8765/docs/preview/' + path); await p.waitForTimeout(5000);
    shots[name] = await p.evaluate(src => { const sc = eval(src)(), P = DEF(); P.film = 'P160'; const out = utilRender(sc, P, 450, 600, {}); const k = document.createElement('canvas'); k.width = 900; k.height = 600; const g = k.getContext('2d'); g.drawImage(sc, 0, 0, 450, 600); g.drawImage(out, 450, 0, 450, 600); return k.toDataURL('image/jpeg', .9); }, '(' + scene.toString() + ')');
    fs.writeFileSync(`led_${name}.jpg`, Buffer.from(shots[name].split(',')[1], 'base64')); await c.close();
  }
  await b.close();
})();
