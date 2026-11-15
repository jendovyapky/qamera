// Filmový shader Qamery v Metalu – přepis FS a HS z docs/preview/index.html (WebGL), aby hledáček, fotka i klip šly stejným výpočtem.
// Hodnoty (uniformy) počítá web (Engine.render se zápisem do rec) a posílá je appce; pořadí v poli U = FilmShader.table.
// Souřadnice: vUv i textury mají počátek vlevo nahoře (ve WebGL vlevo dole) – výpočet nezávisí na směru osy y.
// Mimo hledáček z appky (web kreslí sám): hloubka, infra, dither / pixel art, zebra, vintage blesk, stará záře (gv 1).
#include <metal_stdlib>
using namespace metal;

#define uZoom U[0]
#define uTime U[1]
#define uStatic U[2]
#define uExp U[3]
#define uTemp U[4]
#define uTint U[5]
#define uCon U[6]
#define uSat U[7]
#define uStr U[8]
#define uHal U[9]
#define uBloom U[10]
#define uVig U[11]
#define uFade U[12]
#define uSharp U[13]
#define uShad U[14]
#define uHil U[15]
#define uGrain U[16]
#define uGFreq U[17]
#define uGSharp U[18]
#define uGChroma U[19]
#define uGClump U[20]
#define uGMot U[21]
#define uGN U[22]
#define uFCon U[23]
#define uFSat U[24]
#define uFFade U[25]
#define uChar U[26]
#define uFSoft U[27]
#define uBToe U[28]
#define uBWL U[29]
#define uTr U[30]
#define uSeed U[31]
#define uGlow U[32]
#define uPol U[33]
#define uLat U[34]
#define uHR U[35]
#define uFBlur U[36]
#define uGV U[37]
#define uFV U[38]
#define uNeg U[39]
#define uApl U[40]
#define uEst U[41]
#define uHV U[42]
#define uLut U[43]
#define uCover float2(U[44], U[45])
#define uRes float2(U[46], U[47])
#define uGE float3(U[48], U[49], U[50])
#define uSh float3(U[51], U[52], U[53])
#define uHi float3(U[54], U[55], U[56])
#define uBW float3(U[57], U[58], U[59])
#define uBTone float3(U[60], U[61], U[62])
#define uGSh float3(U[63], U[64], U[65])
#define uGMid float3(U[66], U[67], U[68])
#define uGHi float3(U[69], U[70], U[71])
#define uTrMs float3(U[72], U[73], U[74])
#define uTrSs float3(U[75], U[76], U[77])
#define uTrMr float3(U[78], U[79], U[80])
#define uTrSr float3(U[81], U[82], U[83])
#define uLF float3(U[84], U[85], U[86])
#define uHsl(i) float3(U[87+3*(i)], U[87+3*(i)+1], U[87+3*(i)+2])
#define HALK 1.4
#define HALG 1.7
#define BLOOMG 0.8
#define FLO -8.0
#define FHI 6.0

struct VO { float4 pos [[position]]; float2 uv; };
vertex VO qvert(uint vid [[vertex_id]]) {
    float2 p = float2(float(vid & 1u), float(vid >> 1u));
    VO o; o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0); o.uv = p; return o;
}
constexpr sampler SM(filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler S0(filter::linear, address::clamp_to_edge);
constant float HC[8] = { 0.0, 0.083, 0.166, 0.333, 0.5, 0.625, 0.75, 0.875 };

inline float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
inline float gmod(float x, float y) { return x - y * floor(x / y); }
inline float sq(float x) { return x * x; }
inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
inline uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
inline float hsh(float2 p, float seed) { int2 q = int2(floor(p)) + 65536; return float(pcg(uint(q.x) + pcg(uint(q.y) + pcg(uint(seed))))) * (1.0 / 4294967295.0); }
float vnoise(float2 p, float seed) { float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hsh(i, seed), hsh(i + float2(1, 0), seed), f.x), mix(hsh(i + float2(0, 1), seed), hsh(i + float2(1, 1), seed), f.x), f.y) * 2.0 - 1.0; }
float grainN(float2 p, float seed) {
    const float2x2 R1 = float2x2(float2(0.8, -0.6), float2(0.6, 0.8)), R2 = float2x2(float2(-0.47, -0.88), float2(0.88, -0.47)), R3 = float2x2(float2(0.31, 0.95), float2(-0.95, 0.31));
    return vnoise(R1 * p, seed) * 0.5 + vnoise(R2 * p * 1.37 + float2(5.2, 1.3), seed) * 0.32 + vnoise(R3 * p * 2.71 + float2(9.7, 3.1), seed) * 0.18; }
float3 cellN(float2 i, float seed) { int2 q = int2(i) + 65536; uint h = pcg(uint(q.x) + pcg(uint(q.y) + pcg(uint(seed) + 977u))); uint h2 = pcg(h), h3 = pcg(h2);
    return (float3(float(h), float(h2), float(h3)) * (1.0 / 4294967295.0) - 0.5) * 3.4641; }
float3 negGrain(float2 vUv, constant float* U) {
    float t = uStatic > 0.5 ? 0.0 : floor(uTime * 24.0);
    float2 p = vUv * float2(uRes.x / uRes.y, 1.0) * uGN + float2(gmod(t * 37.0, 911.0), gmod(t * 91.0, 673.0)); float2 i = floor(p), f = fract(p);
    float3 n = mix(mix(cellN(i, uSeed), cellN(i + float2(1, 0), uSeed), f.x), mix(cellN(i + float2(0, 1), uSeed), cellN(i + float2(1, 1), uSeed), f.x), f.y) * 1.5;
    return float3(n.r + n.g * 0.12 + n.b * 0.1, n.g + n.r * 0.10 + n.b * 0.12, n.b + n.g * 0.1 + n.r * 0.1) * uGE; }
float3 rgb2hsv(float3 c) { float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0); float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r)); float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x); }
float3 hsv2rgb(float3 c) { float3 p = abs(fract(c.xxx + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0); return c.z * mix(float3(1.0), clamp(p - 1.0, float3(0.0), float3(1.0)), c.y); }
inline float shd1(float v) { return min(v, 0.62) + 0.36 * (1.0 - exp(-max(v - 0.62, 0.0) / 0.36)); }
float3 unShoulder(float3 x) { float m = max(x.r, max(x.g, x.b)); if (m <= 0.55) return x; float fm = min(m, 0.985);
    float n = 0.55 - 0.45 * log(max(1.0 - (fm - 0.55) / 0.45, 1e-4)); return x * (n / m); }
float3 shTone(float3 x, constant float* U, float gShL) { if (uShad == 0.0 && uHil == 0.0) return x; float lg = mix(log2(max(luma(x), 1e-5) / 0.18), gShL, 0.7);
    float ws = 1.0 - ss(-4.5, 0.3, lg), wh = ss(0.0, 3.2, lg); return x * exp2(uShad * ws * 1.6 + uHil * wh * 1.8); }
float3 skinWarm(float3 c) { float3 h = rgb2hsv(clamp(c, float3(0.0), float3(1.0))); float d = abs(h.x - 0.065); d = min(d, 1.0 - d);
    float w = max(0.0, 1.0 - d / 0.055) * ss(0.1, 0.28, h.y) * (1.0 - ss(0.7, 0.95, h.y)) * ss(0.08, 0.3, h.z);
    if (w <= 0.0) return c; h.x = fract(mix(h.x, 0.058, 0.35 * w)); h.y = clamp(h.y * (1.0 + 0.1 * w), 0.0, 1.0); h.z *= 1.0 - 0.035 * w; return hsv2rgb(h); }
float aplEv(float lg) { return min(2.4, 2.2 * exp2(-(lg + 7.6) / 1.8)) * (1.0 - ss(-4.6, -2.7, lg)) - 0.22 * exp(-sq((lg + 1.8) / 0.8)) + 1.2 * ss(-0.3, 1.0, lg); }
float aplSat(float lg) { return lg < -5.0 ? mix(0.5, 0.6, ss(-7.0, -5.0, lg)) : mix(0.6, 0.75, ss(-4.5, -2.0, lg)); }
float3 aplInv(float3 x, float k) { float L = max(luma(x), 1e-5), lg = log2(L);
    x = max(float3(L) + (x - float3(L)) * mix(1.0, aplSat(lg), k), float3(0.0)); return x * exp2(aplEv(lg) * k); }
float3 aplFwd(float3 x, float k) { float lx = log2(max(luma(x), 1e-5)), lg = lx; lg = lx - aplEv(lg) * k; lg = lx - aplEv(lg) * k; lg = lx - aplEv(lg) * k;
    x *= exp2(-aplEv(lg) * k); float L = max(luma(x), 1e-5); return max(float3(L) + (x - float3(L)) / mix(1.0, aplSat(lg), k), float3(0.0)); }
inline float3 lut3(texture3d<float> lut, float3 t) { return lut.sample(S0, clamp(t, float3(0.0), float3(1.0)) * (32.0 / 33.0) + 0.5 / 33.0).rgb; }
float3 filmLog(float3 lin, float2 vUv, constant float* U, texture3d<float> lut, float gShL, thread float& gLgT) {
    float3 x = unShoulder(max(lin * exp2(-uExp), float3(0.0)));
    if (uApl > 0.0) x = aplInv(x, uApl); else if (uApl < 0.0) x = aplFwd(x, -uApl);
    x = shTone(x * exp2(uExp), U, gShL);
    x = max(mix(float3(luma(x)), x, 1.0 + uSat), float3(0.0));
    float3 lg = log2(max(x, float3(1e-6)) / 0.18) * (1.0 + uCon * 0.5);
    if (uGE.g > 0.0) { float gm = dot(lg, float3(0.3, 0.5, 0.2)); lg += negGrain(vUv, U) * (1.0 + 0.75 * ss(-1.3, -3.6, gm)) * (1.0 - 0.8 * ss(3.0, 5.0, gm)); }
    gLgT = dot(lg, float3(0.3, 0.5, 0.2)); float3 t = clamp((lg - FLO) / (FHI - FLO), float3(0.0), float3(1.0));
    float3 o = lut3(lut, t); return uNeg > 0.5 ? skinWarm(o) : o; }
float3 lookOf(float3 s, float2 vUv, constant float* U, texture3d<float> lut, float gShL) {
    float3 l = pow(max(s, float3(0.0)), float3(2.2)) * exp2(uExp) * float3(1.0 + uTemp * 0.22, 1.0 + uTint * 0.1, 1.0 - uTemp * 0.22);
    float3 c = pow(l / (1.0 + l * 0.06 * uStr), float3(1.0 / 2.2));
    c = (c - 0.5) * (1.0 + uCon * 0.55) + 0.5; c = mix(float3(luma(c)), c, 1.0 + uSat); float3 f = c; float dummy = 0.0;
    if (uLut > 0.5) f = uFV > 1.5 ? filmLog(l, vUv, U, lut, gShL, dummy) : lut3(lut, f);
    if (uBW.r + uBW.g + uBW.b > 0.01) f = float3(dot(clamp(f, float3(0.0), float3(1.0)), uBW)) * uBTone;
    return clamp(mix(c, f, uStr), float3(0.0), float3(1.0)); }

fragment float4 qfilm(VO in [[stage_in]], constant float* U [[buffer(0)]], texture2d<float> tex [[texture(0)]], texture2d<float> curve [[texture(1)]],
                      texture3d<float> lut [[texture(2)]], texture2d<float> hlT [[texture(3)]]) {
    float2 vUv = in.uv, q = vUv - 0.5;
    float2 uv = q * uCover / uZoom + 0.5;
    float2 tsz0 = float2(tex.get_width(), tex.get_height());
    float3 col = tex.sample(SM, uv).rgb;
    if (uSharp > 0.0) { float2 px = 1.0 / tsz0; float3 bl = (tex.sample(SM, uv + float2(px.x, 0)).rgb + tex.sample(SM, uv - float2(px.x, 0)).rgb + tex.sample(SM, uv + float2(0, px.y)).rgb + tex.sample(SM, uv - float2(0, px.y)).rgb) * 0.25;
        col += (col - bl) * uSharp * 1.5; }
    if (uFBlur > 0.0) col = mix(col, tex.sample(SM, uv, level(max(0.0, log2(tsz0.y * 0.0007)))).rgb, uFBlur);
    col = mix(col, (col - uTrMs) / max(uTrSs, float3(0.03)) * uTrSr + uTrMr, uTr);
    float3 lin = pow(max(col, float3(0.0)), float3(2.2)) * exp2(uExp);
    float gShL = 0.0, gLgT = 0.0, gLgD = 0.0;
    if (uShad != 0.0 || uHil != 0.0) { float3 bc = pow(max(tex.sample(SM, uv, level(max(0.0, log2(tsz0.y * 0.012)))).rgb, float3(0.0)), float3(2.2));
        if (uFV > 1.5) bc = unShoulder(bc); gShL = log2(max(luma(bc * exp2(uExp)), 1e-5) / 0.18); }
    lin *= float3(1.0 + uTemp * 0.22, 1.0 + uTint * 0.1, 1.0 - uTemp * 0.22);
    if (uFV < 1.5) lin = shTone(lin, U, gShL);
    lin *= uLF;
    if (uPol > 0.0) { float sk = ss(0.04, 0.3, (lin.b - max(lin.r, lin.g)) / (lin.b + 0.02)); lin *= mix(float3(1.0), float3(0.48, 0.56, 0.78), sk * uPol);
        float pl = luma(lin); lin = max(mix(float3(pl), lin, 1.0 + 0.2 * uPol), float3(0.0)); lin *= 1.0 - 0.12 * uPol * ss(0.5, 1.3, pl); }
    if (uLat != 0.0) {
        float t = 0.012, s2 = 0.015, g = exp2(uLat), mm = 0.18 * g;
        float3 m = lin * g, d = m * m / (m + t); d /= 1.0 + d * s2; float dm = mm * mm / (mm + t); dm /= 1.0 + dm * s2;
        float3 d0 = lin * lin / (lin + t); d0 /= 1.0 + d0 * s2; float b0 = 0.0324 / 0.192; b0 /= 1.0 + b0 * s2;
        lin *= (d / dm) / max(d0 / b0, float3(1e-5));
        float un = max(-uLat, 0.0), ov = max(uLat, 0.0), ll = luma(lin);
        lin += float3(0.004, 0.008, 0.007) * un * (1.0 - ss(0.0, 0.2, ll));
        lin = max(mix(float3(ll), lin, 1.0 - 0.07 * un + 0.04 * ov), float3(0.0)); }
    /* halation (gv 2): práh z mapy světel, rozmazání třemi prstenci vzorků, záře kolem minus světlo samo */
    if (uGV > 1.5 && uHal > 0.001) {
        float2 tsz = float2(hlT.get_width(), hlT.get_height()), ak = float2(tsz.y / tsz.x, 1.0); float hr = 0.0;
        float L1 = log2(max(1.0, 0.005 * uHR * tsz.y)), L2 = log2(max(1.0, 0.012 * uHR * tsz.y)), L3 = log2(max(1.0, 0.026 * uHR * tsz.y));
        float jr = hsh(floor(uv * tsz), uSeed) * 0.6283;
        for (int i = 0; i < 10; i++) { float a = float(i) * 0.6283 + jr; float2 d = float2(cos(a), sin(a)) * ak, e = float2(cos(a + 0.314), sin(a + 0.314)) * ak;
            hr += hlT.sample(SM, uv + d * 0.007 * uHR, level(L1)).a * 0.55 + hlT.sample(SM, uv + e * 0.017 * uHR, level(L2)).a * 0.35 + hlT.sample(SM, uv + d * 0.036 * uHR, level(L3)).a * 0.16; }
        hr /= 10.0; float self = hlT.sample(SM, uv, level(0.0)).a;
        float hl = max(hr - self, 0.0) * HALK;
        if (uHV > 1.5) { hl *= 0.5; if (uEst > 0.5) { float cov = hlT.sample(SM, uv, level(L3 + 1.5)).a; hl *= 1.0 - ss(0.04, 0.22, cov); } }
        float3 hcol = float3(1.0, 0.2, 0.04) * exp2(uExp);
        lin += hcol * hl * HALG * uHal / (1.0 + luma(lin) * 5.0); }
    if (uGV > 1.5) { float3 h1 = hlT.sample(SM, uv, level(2.0)).rgb, h2 = hlT.sample(SM, uv, level(3.5)).rgb, h3 = hlT.sample(SM, uv, level(5.0)).rgb;
        float3 bl = (h1 * 0.5 + h2 * 0.8 + h3 * 1.0) * uBloom * BLOOMG * exp2(uExp); lin += bl * (uEst > 0.5 ? 0.4 : 1.0) / (1.0 + lin); }
    float3 c = pow(max(lin / (1.0 + lin * 0.06 * uStr), float3(0.0)), float3(1.0 / 2.2));
    c = (c - 0.5) * (1.0 + uCon * 0.55) + 0.5;
    float l = luma(c); c = mix(float3(l), c, 1.0 + uSat);
    float3 f = c; float fl = clamp(luma(f), 0.0, 1.0);
    if (uBW.r + uBW.g + uBW.b > 0.01 && uBWL < 0.5) {
        float y = clamp(dot(clamp(f, float3(0.0), float3(1.0)), uBW), 0.0, 1.0); y = (y - 0.5) * uFCon + 0.5; y = mix(y, y * y * (3.0 - 2.0 * y), clamp(uFCon - 0.9, 0.0, 0.6));
        y = uBToe + clamp(y, 0.0, 1.0) * (1.0 - uBToe - uFFade * 0.4); f = float3(y) * uBTone; fl = y;
    } else if (uLut > 0.5 && uFV > 1.5) { f = filmLog(lin, vUv, U, lut, gShL, gLgT); gLgD = gLgT;
    } else if (uLut > 0.5) { f = lut3(lut, f);
        float fq = clamp(luma(f), 0.0, 1.0); f = mix(float3(fq), f, 1.0 + (uFSat - 1.0) * uChar); f = (f - 0.5) * (1.0 + (uFCon - 1.0) * uChar) + 0.5;
        f += uSh * (1.0 - fq) * (1.0 - fq) * 1.6 * uChar; f *= mix(float3(1.0), mix(float3(1.0), uHi, uChar), ss(0.15, 1.0, fq)); f = uFFade * uChar + f * (1.0 - uFFade * uChar * 1.2);
    } else {
        f = mix(float3(fl), f, uFSat); f = (f - 0.5) * uFCon + 0.5; f = mix(f, f * f * (3.0 - 2.0 * f), 0.25 * (uFCon - 0.85));
        f += uSh * (1.0 - fl) * (1.0 - fl) * 1.6; f *= mix(float3(1.0), uHi, ss(0.15, 1.0, fl)); f = uFFade + f * (1.0 - uFFade * 1.4); }
    if (uFSoft > 0.0) f = mix(f, (f - 0.5) * 0.66 + 0.53, uFSoft);
    c = mix(c, f, uStr);
    if (uGlow > 0.0 && uGV > 1.5) { float3 dg = lookOf(tex.sample(SM, uv, level(4.6)).rgb, vUv, U, lut, gShL); float gw = ss(0.4, 0.95, luma(dg));
        c = mix(c, 1.0 - (1.0 - c) * (1.0 - dg * 0.85 * gw), uGlow * 0.6); c = mix(c, c * 0.96 + 0.025, uGlow * 0.15); }
    c = clamp(c, float3(0.0), float3(1.0));
    c = float3(curve.sample(S0, float2(c.r, 0.5)).r, curve.sample(S0, float2(c.g, 0.5)).g, curve.sample(S0, float2(c.b, 0.5)).b);
    float3 h = rgb2hsv(c); float3 adj = float3(0.0);
    for (int i = 0; i < 8; i++) { float d = abs(h.x - HC[i]); d = min(d, 1.0 - d); float w = max(0.0, 1.0 - d / 0.09) * ss(0.04, 0.2, h.y); adj += uHsl(i) * w; }
    h.x = fract(h.x + adj.x * 0.08); h.y = clamp(h.y * (1.0 + adj.y), 0.0, 1.0); h.z = clamp(h.z * (1.0 + adj.z * 0.5), 0.0, 1.0);
    c = hsv2rgb(h);
    float L = luma(c);
    c += uGSh * (1.0 - ss(0.0, 0.45, L)) + uGMid * (1.0 - abs(L - 0.5) * 2.0) * 0.8 + uGHi * ss(0.55, 1.0, L);
    c = c * (1.0 - uFade * 0.22) + uFade * 0.1;
    float ar = uRes.x / uRes.y; float2 vq = q * float2(ar > 1.0 ? ar : 1.0, ar > 1.0 ? 1.0 : 1.0 / ar);
    c *= mix(1.0, ss(0.95, 0.2, length(vq) * 1.15), uVig);
    if (uGrain > 0.0) {
        float2 gp = vUv * float2(ar, 1.0) * uGFreq;
        float t = uStatic > 0.5 ? 0.0 : floor(uTime * 24.0);
        float2 jit = float2(hsh(float2(t, 17.0), uSeed), hsh(float2(t, 71.0), uSeed)) * 997.0;
        float clump = mix(1.0, 0.45 + 1.1 * (vnoise(gp * 0.21 + jit * 0.7, uSeed) * 0.5 + 0.5), uGClump);
        float nm = grainN(gp + jit, uSeed);
        float3 nc = float3(grainN(gp * 1.09 + jit + 11.0, uSeed), grainN(gp * 0.93 + jit + 23.0, uSeed), grainN(gp * 1.04 + jit + 37.0, uSeed));
        float3 n = mix(float3(nm), nc, uGChroma) * clump;
        n = sign(n) * pow(abs(n) * 1.25, float3(1.0 / uGSharp));
        float w = (1.0 - ss(0.6, 1.0, L) * 0.75) * (0.5 + 0.5 * ss(0.0, 0.22, L));
        if (uNeg > 0.5) w = (0.3 + 1.05 * exp(-sq((gLgD + 0.6) / 2.3)) + 0.55 * ss(-2.5, -6.0, gLgD)) * (1.0 - ss(2.5, 5.5, gLgD) * 0.7);
        c += n * uGrain * 0.13 * w + (hsh(in.pos.xy + jit * 3.1, uSeed) - 0.5) * uGrain * 0.006;
        if (uGMot > 0.0) { float2 mp = vUv * float2(ar, 1.0) * 2.3; c += float3(vnoise(mp + 3.0, uSeed), vnoise(mp + 17.0, uSeed), vnoise(mp + 29.0, uSeed)) * 0.045 * uGMot * uGrain; }
    }
    if (uBW.r + uBW.g + uBW.b > 0.01 && uStr > 0.001) c = mix(c, float3(dot(c, float3(0.299, 0.587, 0.114))) * uBTone, clamp(uStr, 0.0, 1.0));
    return float4(clamp(c, float3(0.0), float3(1.0)), 1.0);
}

/* mapa světel (HS): 4×4 vzorky na pixel; zdroj z kamery appky v logu (H[3] = 1) = jas z inverze ramene jako u RAW */
fragment float4 qhi(VO in [[stage_in]], constant float* H [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float3 acc = float3(0.0); float ea = 0.0; float2 ts = float2(H[0], H[1]);
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
        float3 c = src.sample(SM, in.uv + (float2(float(x), float(y)) - 1.5) * 0.25 * ts, level(H[2])).rgb;
        float v = max(c.r, max(c.g, c.b)) * 0.6 + luma(c) * 0.55;
        float e = ss(0.86, 0.995, v); e *= e;
        if (H[3] > 0.5) { float m = pow(max(max(c.r, max(c.g, c.b)), 0.0), 2.2), fm = min(m, 0.985); float n = m <= 0.55 ? m : 0.55 - 0.45 * log(max(1.0 - (fm - 0.55) / 0.45, 1e-4));
            e = n > 2.0 ? clamp((0.25 + log2(n / 2.0) / 3.0) * 1.5, 0.0, 1.0) : 0.0; }
        acc += c * e; ea += e; }
    return float4(acc / 16.0, ea / 16.0);
}
