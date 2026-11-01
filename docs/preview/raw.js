/* Qamera – vyvolání RAW / DNG (i iPhone ProRAW) přímo v prohlížeči. GPL-3.0.
   LibRaw (LGPL-2.1 / CDDL-1.0, https://www.libraw.org) přes libraw-wasm (ISC, https://github.com/ybouane/LibRaw-Wasm),
   JPEG XL dlaždice novějšího ProRAW přes jxl-oxide-wasm (MIT / Apache-2.0, https://github.com/tirr-c/jxl-oxide).
   Výstup: SDR fotka s filmovým ramenem světel (nic se neutne) + mapa světel (kolik ex. nad bílou) pro halation / bloom. */

export const RAW_EXT = /\.(dng|cr2|cr3|nef|nrw|arw|srf|sr2|raf|orf|rw2|pef|srw|x3f|3fr|iiq|erf|kdc|mrw|mos|rwl)$/i;
export const isRaw = f => RAW_EXT.test(f.name || '') || /x-adobe-dng|image\/x-.*raw|image\/dng/i.test(f.type || '');

const MAXS = 4096, HLS = 512; // fotka max 4096 px (jako export), mapa světel max 512 px
const sleep = () => new Promise(r => setTimeout(r, 0));

/* ---------- TIFF / DNG: jen čtení tagů (kvůli JPEG XL dlaždicím a datu) ---------- */
function tiff(u8) {
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength), le = u8[0] === 0x49;
  if (!((u8[0] === 0x49 && u8[1] === 0x49) || (u8[0] === 0x4d && u8[1] === 0x4d))) return null;
  const u16 = o => dv.getUint16(o, le), u32 = o => dv.getUint32(o, le), SZ = { 1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4, 16: 8 };
  const val = (ty, o) => ty === 3 ? u16(o) : ty === 4 || ty === 13 ? u32(o) : ty === 9 ? dv.getInt32(o, le) : ty === 5 ? u32(o) / u32(o + 4) : ty === 10 ? dv.getInt32(o, le) / dv.getInt32(o + 4, le) : ty === 11 ? dv.getFloat32(o, le) : ty === 12 ? dv.getFloat64(o, le) : ty === 8 ? dv.getInt16(o, le) : u8[o];
  const ifd = o => { const n = u16(o), t = {}; for (let i = 0; i < n; i++) { const e = o + 2 + i * 12, tag = u16(e), ty = u16(e + 2), c = u32(e + 4), sz = (SZ[ty] || 1) * c, at = sz > 4 ? u32(e + 8) : e + 8;
      if (ty === 2) { t[tag] = new TextDecoder().decode(u8.subarray(at, at + c)).replace(/\0.*$/, ''); continue; }
      const a = []; for (let k = 0; k < Math.min(c, 1 << 20); k++) a.push(val(ty, at + k * (SZ[ty] || 1))); t[tag] = a; }
    return { t, next: u32(o + 2 + n * 12) }; };
  const all = [], walk = (o, d) => { if (!o || o >= u8.length || d > 4 || all.length > 40) return; const { t, next } = ifd(o); all.push(t); (t[330] || []).forEach(s => walk(s, d + 1)); if (d === 0) walk(next, 0); };
  walk(u32(4), 0); let exif = null; if (all[0] && all[0][34665]) exif = ifd(all[0][34665][0]).t;
  return { ifds: all, exif };
}
const exifDate = s => { const m = /^(\d{4}):(\d\d):(\d\d) (\d\d):(\d\d):(\d\d)/.exec(s || ''); return m ? new Date(+m[1], m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : null; };

/* ---------- 3×3 matice ---------- */
const mul = (A, B) => A.map((r, i) => [0, 1, 2].map(j => r[0] * B[0][j] + r[1] * B[1][j] + r[2] * B[2][j]));
const mv = (A, v) => A.map(r => r[0] * v[0] + r[1] * v[1] + r[2] * v[2]);
function inv(m) { const [a, b, c] = m[0], [d, e, f] = m[1], [g, h, i] = m[2], A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g, det = a * A + b * B + c * C;
  return [[A / det, -(b * i - c * h) / det, (b * f - c * e) / det], [B / det, (a * i - c * g) / det, -(a * f - c * d) / det], [C / det, -(a * h - b * g) / det, (a * e - b * d) / det]]; }
const m3 = a => [a.slice(0, 3), a.slice(3, 6), a.slice(6, 9)];
const XYZ50_SRGB = [[3.1338561, -1.6168667, -0.4906146], [-0.9787684, 1.9161415, 0.0334540], [0.0719453, -0.2289914, 1.4052427]], D50 = [0.9642, 1, 0.8249];
/* kamera → lineární sRGB podle DNG (ForwardMatrix, jinak ColorMatrix) s vyvážením bílé AsShotNeutral */
function camToSrgb(t) {
  const n = t[50728] || [1, 1, 1], ill = [t[50778] && t[50778][0], t[50779] && t[50779][0]], pick = ill[1] === 21 || ill[1] === 23 || !t[50721] ? 2 : 1; // radši D65 sada
  const FM = t[pick === 2 ? 50965 : 50964] || t[50964] || t[50965], CM = t[pick === 2 ? 50722 : 50721] || t[50721];
  let M;
  if (FM) M = mul(XYZ50_SRGB, mul(m3(FM), [[1 / n[0], 0, 0], [0, 1 / n[1], 0], [0, 0, 1 / n[2]]]));
  else if (CM) { const c2x = inv(m3(CM)), w = mv(c2x, n), s = [D50[0] / w[0], D50[1] / w[1], D50[2] / w[2]]; M = mul(XYZ50_SRGB, mul([[s[0], 0, 0], [0, s[1], 0], [0, 0, s[2]]], c2x)); } // neutrál → bílá D50
  else return null;
  const k = mv(M, [n[0], n[1], n[2]])[1] || 1; return M.map(r => r.map(v => v / k)); // neutrál kamery = šedá s jasem 1
}

/* ---------- PNG 16 bit (výstup jxl-oxide) ---------- */
async function png16(u8) {
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength); let o = 8, W = 0, H = 0, bd = 8, ct = 2; const idat = [];
  while (o < u8.length) { const len = dv.getUint32(o), ty = String.fromCharCode(...u8.subarray(o + 4, o + 8)), d = u8.subarray(o + 8, o + 8 + len);
    if (ty === 'IHDR') { W = dv.getUint32(o + 8); H = dv.getUint32(o + 12); bd = u8[o + 16]; ct = u8[o + 17]; } else if (ty === 'IDAT') idat.push(d); else if (ty === 'IEND') break; o += 12 + len; }
  const ch = { 0: 1, 2: 3, 4: 2, 6: 4 }[ct] || 3, by = bd / 8, bpp = ch * by, stride = W * bpp;
  const raw = new Uint8Array(await new Response(new Blob(idat).stream().pipeThrough(new DecompressionStream('deflate'))).arrayBuffer()), out = new Uint8Array(H * stride);
  for (let y = 0; y < H; y++) { const f = raw[y * (stride + 1)], s = y * (stride + 1) + 1, d = y * stride, p = d - stride;
    for (let x = 0; x < stride; x++) { const a = x >= bpp ? out[d + x - bpp] : 0, b = y ? out[p + x] : 0, c = x >= bpp && y ? out[p + x - bpp] : 0, r = raw[s + x];
      out[d + x] = f === 0 ? r : f === 1 ? r + a : f === 2 ? r + b : f === 3 ? r + ((a + b) >> 1) : (() => { const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c); return r + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c); })(); } }
  const n = W * H * ch, px = new Uint16Array(n), max = by === 2 ? 65535 : 255; for (let i = 0; i < n; i++) px[i] = by === 2 ? (out[i * 2] << 8) | out[i * 2 + 1] : out[i];
  return { W, H, ch, px, max };
}

/* ---------- vyvolání: automatická expozice, filmové rameno světel, mapa světel ---------- */
const SRGB = (() => { const t = new Uint8ClampedArray(4097); for (let i = 0; i <= 4096; i++) { const v = i / 4096; t[i] = Math.round(255 * (v <= .0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - .055)); } return t; })();
async function develop(W, H, get, onStep, baseline = 0) {
  // expozice: geometrický průměr jasu → střední šedá (jako foťák); nikdy tmavěji než bílý bod senzoru → přepálená bílá zůstane bílá
  let ls = 0, ln = 0; const step = Math.max(1, Math.floor(Math.sqrt(W * H / 40000))), px = [0, 0, 0];
  for (let y = 0; y < H; y += step) for (let x = 0; x < W; x += step) { get(x, y, px); const Y = .2126 * px[0] + .7152 * px[1] + .0722 * px[2]; ls += Math.log2(Math.max(Y, 1e-5)); ln++; }
  const ev = Math.max(0, Math.min(4.5, Math.log2(.17) - ls / ln)), g = Math.pow(2, Number.isFinite(ev) ? ev : baseline);
  const c = document.createElement('canvas'); c.width = W; c.height = H; const cg = c.getContext('2d'), id = cg.createImageData(W, H), d = id.data;
  const hk = Math.min(1, HLS / Math.max(W, H)), hw = Math.max(1, Math.round(W * hk)), hh = Math.max(1, Math.round(H * hk)), hv = new Float32Array(hw * hh), hn = new Float32Array(hw * hh);
  for (let y = 0; y < H; y++) { const hy = Math.min(hh - 1, (y * hk) | 0);
    for (let x = 0; x < W; x++) { get(x, y, px); const clip = Math.max(px[0], px[1], px[2]) > .985; let r = Math.max(0, px[0] * g), gg = Math.max(0, px[1] * g), b = Math.max(0, px[2] * g); const m = Math.max(r, gg, b);
      if (m > .55) { const f = .55 + .45 * (1 - Math.exp(-(m - .55) / .45)), k = f / m, w = Math.min(1, Math.max(0, (m - 1) / 6)); // měkké rameno; hodně přepálené světlo jde do bílé jako na filmu
        r = r * k * (1 - w) + f * w; gg = gg * k * (1 - w) + f * w; b = b * k * (1 - w) + f * w; }
      const i = (y * W + x) * 4; d[i] = SRGB[Math.min(4096, (r * 4096) | 0)]; d[i + 1] = SRGB[Math.min(4096, (gg * 4096) | 0)]; d[i + 2] = SRGB[Math.min(4096, (b * 4096) | 0)]; d[i + 3] = 255;
      const hi = hy * hw + Math.min(hw - 1, (x * hk) | 0); hv[hi] += Math.max(m > 1 ? Math.min(1, Math.log2(m) / 3) : 0, clip ? .5 : 0); hn[hi]++; } // ořezaný senzor = aspoň 1,5 EV nad bílou
    if (y % 256 === 0) { onStep && onStep(.75 + .2 * y / H, 'Vyvolávám'); await sleep(); } }
  cg.putImageData(id, 0, 0);
  const hc = document.createElement('canvas'); hc.width = hw; hc.height = hh; const hg = hc.getContext('2d'), hd = hg.createImageData(hw, hh);
  let any = 0; for (let i = 0; i < hw * hh; i++) { const v = hn[i] ? hv[i] / hn[i] : 0; any += v; hd.data[i * 4] = hd.data[i * 4 + 1] = hd.data[i * 4 + 2] = Math.round(v * 255); hd.data[i * 4 + 3] = 255; }
  hg.putImageData(hd, 0, 0);
  return { canvas: c, hl: any > 0 ? hc : null, ev };
}
function orient(c, o) { if (!o || o === 1) return c; const sw = o >= 5, n = document.createElement('canvas'); n.width = sw ? c.height : c.width; n.height = sw ? c.width : c.height; const g = n.getContext('2d');
  const T = { 2: [-1, 0, 0, 1, c.width, 0], 3: [-1, 0, 0, -1, c.width, c.height], 4: [1, 0, 0, -1, 0, c.height], 5: [0, 1, 1, 0, 0, 0], 6: [0, 1, -1, 0, c.height, 0], 7: [0, -1, -1, 0, c.height, c.width], 8: [0, -1, 1, 0, 0, c.width] }[o];
  if (!T) return c; g.setTransform(...T); g.drawImage(c, 0, 0); c.width = 0; return n; }

/* ---------- ProRAW s JPEG XL dlaždicemi (DNG 1.7) – vlastní cesta, LibRaw je neumí ---------- */
let JXL = null;
async function jxlPath(u8, info, raw, onStep) {
  if (!JXL) { onStep && onStep(.05, 'Načítám dekodér JPEG XL'); const m = await import('../../vendor/jxl-oxide-wasm/jxl_oxide_wasm.js'); await m.default(); JXL = m; }
  const t = raw, W = t[256][0], H = t[257][0], tw = (t[322] || [W])[0], th = (t[323] || [H])[0], offs = t[324] || t[273], cnt = t[325] || t[279], spp = (t[277] || [3])[0];
  const bl = t[50714] ? t[50714].reduce((a, b) => a + b, 0) / t[50714].length : 0, wl = (t[50717] || [65535])[0], sc = 1 / Math.max(1, wl - bl);
  const ds = Math.max(1, Math.ceil(Math.max(W, H) / MAXS)), w = Math.ceil(W / ds), h = Math.ceil(H / ds), buf = new Float32Array(w * h * 3), nn = new Uint8Array(w * h);
  const across = Math.ceil(W / tw);
  for (let i = 0; i < offs.length; i++) { const img = new JXL.JxlImage(); img.feedBytes(u8.subarray(offs[i], offs[i] + cnt[i])); if (!img.tryInit()) { img.free(); throw new Error('JPEG XL dlaždice se nepovedla'); }
    const p = await png16(img.render().encodeToPng()); img.free(); // encodeToPng výsledek renderu spotřebuje
    const x0 = (i % across) * tw, y0 = Math.floor(i / across) * th, ch = p.ch, k = p.max === 255 ? 257 : 1;
    for (let y = 0; y < p.H && y0 + y < H; y++) { const Y = ((y0 + y) / ds) | 0; for (let x = 0; x < p.W && x0 + x < W; x++) { const X = ((x0 + x) / ds) | 0, j = Y * w + X, s = (y * p.W + x) * ch;
      for (let c = 0; c < 3; c++) buf[j * 3 + c] += (p.px[s + Math.min(c, ch - 1)] * k - bl) * sc; nn[j]++; } }
    onStep && onStep(.1 + .6 * (i + 1) / offs.length, `Dekóduji ${i + 1} / ${offs.length}`); await sleep(); }
  const M = camToSrgb(t) || [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
  const get = (x, y, o) => { const j = y * w + x, n = nn[j] || 1, r = buf[j * 3] / n, g = buf[j * 3 + 1] / n, b = buf[j * 3 + 2] / n;
    o[0] = M[0][0] * r + M[0][1] * g + M[0][2] * b; o[1] = M[1][0] * r + M[1][1] * g + M[1][2] * b; o[2] = M[2][0] * r + M[2][1] * g + M[2][2] * b; };
  void spp; const out = await develop(w, h, get, onStep, (info.ifds[0][50730] || t[50730] || [0])[0]);
  out.canvas = orient(out.canvas, (info.ifds[0][274] || [1])[0]); if (out.hl) out.hl = orient(out.hl, (info.ifds[0][274] || [1])[0]); return out;
}

/* ---------- vše ostatní (DNG z foťáků a Androidu, ProRAW se starší kompresí, CR2/NEF/ARW…) přes LibRaw ---------- */
async function librawPath(u8, onStep) {
  onStep && onStep(.05, 'Načítám dekodér RAW');
  const LibRaw = (await import('../../vendor/libraw-wasm/index.js')).default, lr = new LibRaw();
  try {
    const info = tiff(u8), big = info && info.ifds.some(t => t[254] && t[254][0] === 0 && t[256] && Math.max(t[256][0], t[257][0]) > MAXS * 1.25);
    onStep && onStep(.15, 'Dekóduji RAW');
    await lr.open(u8.slice(), { outputBps: 16, noAutoBright: true, useCameraWb: true, outputColor: 1, halfSize: !!big, highlight: 0, userQual: big ? 0 : 3 });
    const meta = await lr.metadata().catch(() => ({})); onStep && onStep(.6, 'Dekóduji RAW');
    const im = await lr.imageData(); if (!im || !im.data) throw new Error('RAW se nepodařilo dekódovat');
    let W = im.width, H = im.height; const C = im.colors || 3, D = im.data, mx = im.bits === 8 ? 255 : 65535, ds = Math.max(1, Math.ceil(Math.max(W, H) / MAXS));
    const w = Math.ceil(W / ds), h = Math.ceil(H / ds);
    // libraw-wasm vždy vrací výstup s gamou BT.709 (0,45 / 4,5) – nastavení gamm ignoruje → zpět do lineárního světla tabulkou
    const LIN = new Float32Array(mx + 1); for (let i = 0; i <= mx; i++) { const v = i / mx; LIN[i] = v < .081 ? v / 4.5 : Math.pow((v + .099) / 1.099, 1 / .45); }
    const get = ds === 1 ? (x, y, o) => { const i = (y * W + x) * C; o[0] = LIN[D[i]]; o[1] = LIN[D[i + 1]]; o[2] = LIN[D[i + 2]]; }
      : (x, y, o) => { let r = 0, g = 0, b = 0, n = 0; for (let yy = y * ds; yy < Math.min(H, y * ds + ds); yy++) for (let xx = x * ds; xx < Math.min(W, x * ds + ds); xx++) { const i = (yy * W + xx) * C; r += LIN[D[i]]; g += LIN[D[i + 1]]; b += LIN[D[i + 2]]; n++; } o[0] = r / n; o[1] = g / n; o[2] = b / n; };
    const out = await develop(w, h, get, onStep); out.meta = meta; return out;
  } finally { lr.dispose(); }
}

/* hlavní vstup: soubor → { canvas (≤ 4096 px, sRGB), hl (mapa světel ≤ 512 px nebo null), date, label } */
export async function developRaw(file, onStep) {
  const u8 = new Uint8Array(await file.arrayBuffer()), info = tiff(u8);
  const raw = info && info.ifds.find(t => t[254] && t[254][0] === 0 && t[259]) || (info && info.ifds.find(t => t[259] && (t[259][0] === 52546 || t[259][0] === 7) && t[262] && (t[262][0] === 34892 || t[262][0] === 32803)));
  const date = info && (exifDate(info.exif && info.exif[36867]) || exifDate(info.ifds[0][306])), label = info ? [info.ifds[0][271], info.ifds[0][272]].filter(Boolean).join(' ') : '';
  let out;
  if (raw && raw[259][0] === 52546) out = await jxlPath(u8, info, raw, onStep);
  else out = await librawPath(u8, onStep);
  onStep && onStep(1, 'Hotovo');
  return { canvas: out.canvas, hl: out.hl, date: date || (out.meta && out.meta.timestamp) || null, label: label || (out.meta ? [out.meta.camera_make, out.meta.camera_model].filter(Boolean).join(' ') : ''), ev: out.ev };
}
