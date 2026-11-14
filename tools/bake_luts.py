"""Pečení filmových LUT pro Qameru ze spektrafilmu (Andrea Volpato, https://github.com/andreavolpato/spektrafilm).

Spouští se lokálně (nebo v GitHub Actions), ne v appce:
    python tools/bake_luts.py --spektrafilm cesta/ke/spektrafilm/src [--size 33] [--only P400,G200]

Výstup do luts/:
  <KOD>.png   – LUT pro appku: N*N x N obrázek, řez podle modré vedle sebe (x = r + b*N, y = g), 8bit sRGB
  <KOD>.cube  – (s --cube) stejná LUT pro DaVinci / Premiere / Photoshop (s atribucí CC BY-SA 4.0 v hlavičce)
  films.json  – metadata (kód, profil filmu a tisku)

--log (film v2, doporučené): vstup = scénické lineární světlo (sRGB primárky) v log tvaru
  t = (log2(x / 0.18) + 8) / 14, tj. −8 … +6 EV kolem střední šedé; výstup = sRGB po tisku a skenu.
  Celý rozsah negativu (měkká světla, posun barev při pod/přeexpozici) je v LUT, výchozí výstupní
  komprese gamutu spektrafilmu zůstává (vzhled podle autora), černý a bílý bod jako sken v labu. Ukládá do luts/log/.
  Přesnost proti přímému spektrafilmu na fotkách ΔE2000 ~0,2 (33³).

--scanner frontier|noritsu (jen negativy): stejný log vstup, ale místo optického tisku na papír sken negativu
  jako v labu: spektrafilm (scan_film) dá surový negativ, převod je vlastní – hustota po kanálech, oranžová maska
  pryč a šedá neutrální (přímka z šedé škály −3…+3 EV), barevná matice skeneru (oddělení barviv, napasovaná na
  barevnou tabulku při −1/0/+1 EV, šedou nemění), S křivka a barevnost skeneru (Frontier: kontrastnější, teplá pleť,
  azurové stíny a nebe; Noritsu: měkčí, neutrálnější, víc kresby ve světlech). Vzhled skenerů je odhad podle typických
  skenů, ne měřený profil. Ukládá do luts/scan/<skener>/.

Vstup LUT (bez --log) = sRGB, výstup = sRGB. Prostorové a náhodné efekty (grain, halation, difúze, ostření)
jsou vypnuté – ty dělá shader Qamery živě. Automatická expozice je vypnutá, aby LUT nezávisela na obsahu.
Upečené LUT jsou odvozené dílo profilů spektrafilmu → licence CC BY-SA 4.0 (viz luts/SPEKTRAFILM_LICENSE.txt).
"""
import argparse, dataclasses, json, os, sys, time
import numpy as np

# kód v Qameře → (profil filmu, tiskový profil nebo None = sken diapozitivu)
FILMS = {
    'P160':    ('kodak_portra_160', 'kodak_portra_endura'),
    'P400':    ('kodak_portra_400', 'kodak_portra_endura'),
    'P800':    ('kodak_portra_800', 'kodak_portra_endura'),
    'E100':    ('kodak_ektar_100', 'kodak_endura_premier'),
    'G200':    ('kodak_gold_200', 'kodak_endura_premier'),
    'UM400':   ('kodak_ultramax_400', 'kodak_endura_premier'),
    'KC64':    ('kodak_kodachrome_64', None),
    'EC100':   ('kodak_ektachrome_100', None),
    'V3-50D':  ('kodak_vision3_50d', 'kodak_2383'),
    'V3-250D': ('kodak_vision3_250d', 'kodak_2383'),
    'V3-500T': ('kodak_vision3_500t', 'kodak_2383'),
    'V3-200T': ('kodak_vision3_200t', 'kodak_2383'),
    'VR200':   ('kodak_verita_200d', 'kodak_endura_premier'),
    'P800P':   ('kodak_portra_800_push2', 'kodak_portra_endura'),
    'E100C':   ('kodak_ektar_100', 'kodak_2383'),
    'P400C':   ('kodak_portra_400', 'kodak_2383'),
    'G200C':   ('kodak_gold_200', 'kodak_2383'),
    'P160C':   ('kodak_portra_160', 'kodak_2383'),  # film V2: Portra na kinový tisk (jen --log; skener 'kino' Honza zamítl – moc přebarvené)
    'C200':    ('fujifilm_c200', 'fujifilm_crystal_archive_typeii'),
    '400H':    ('fujifilm_pro_400h', 'fujifilm_crystal_archive_typeii'),
    'SX400':   ('fujifilm_xtra_400', 'fujifilm_crystal_archive_typeii'),
    'PV100':   ('fujifilm_provia_100f', None),
    'VEL':     ('fujifilm_velvia_100', None),
}
V2_LOG_ONLY = {'P400C', 'G200C', 'P160C'}
HEADER = ['Qamera film LUT {code} ({film})',
          'Derived from spektrafilm by Andrea Volpato',
          'https://github.com/andreavolpato/spektrafilm',
          'Licensed CC BY-SA 4.0 https://creativecommons.org/licenses/by-sa/4.0/',
          'Modified by Qamera (jendovyapky): baked to 3D LUT sRGB->sRGB, spatial effects off (grain, halation, diffusion).']


LOG_LO, LOG_HI = -8.0, 6.0  # rozsah log vstupu v EV kolem šedé 0,18 – stejné konstanty jsou v shaderu (FLO, FHI)


def log_identity(n):
    t = identity(n)
    return .18 * 2 ** (t * (LOG_HI - LOG_LO) + LOG_LO)


def bake_log(film, prt, n, simulate, init_params):
    p = init_params(film, prt or 'kodak_portra_endura')
    p.io.input_color_space = 'sRGB'; p.io.input_cctf_decoding = False
    p.io.output_color_space = 'sRGB'; p.io.output_cctf_encoding = True
    p.io.scan_film = prt is None
    p.camera.auto_exposure = False
    p.scanner.white_correction = True; p.scanner.black_correction = True  # sken jako v labu: bílá papíru → 0,98, černá → 0,01 (pevné z profilu, ne z fotky)
    p.debug.deactivate_spatial_effects = True; p.debug.deactivate_stochastic_effects = True
    p.film_render.grain.active = False; p.film_render.halation.active = False
    p.io.output_gamut_compress = dataclasses.replace(p.io.output_gamut_compress, algorithm='off')  # komprese stahovala bílou na 225 a ubírala sytost
    return np.clip(np.asarray(simulate(log_identity(n), p), dtype=np.float64).reshape(n, n, n, 3), 0, 1)


SCANNERS = {  # kontrast g (sklon S křivky), maximum, sytost, tóny v EV na kanál (R, G, B) ve stínech / středu / světlech
    'frontier': dict(g=1.18, top=.94, sat=1.04, sh=(-.10, .03, .02), mid=(.05, .02, -.05), hi=(-.02, .03, -.01)),
    # kino = gradace jako film na kinovém tisku / filmová videa: kontrast, azurové stíny, teplá světla, nebe do tyrkysové, zeleň méně žlutá
    'kino':     dict(g=1.36, top=.97, sat=1.12, sh=(-.14, .0, .10), mid=(.03, -.04, .0), hi=(.10, .03, -.12), hue=[(215, 40, -10, 1.0), (75, 35, 8, .9), (130, 40, 6, .95)]),
    'noritsu':  dict(g=1.02, top=.96, sat=1.0, sh=(.02, -.02, .04), mid=(.04, -.01, -.01), hi=(-.02, 0., 0.)),
}


def neg_params(film, init_params):
    p = init_params(film, 'kodak_portra_endura')
    p.io.input_color_space = 'sRGB'; p.io.input_cctf_decoding = False
    p.io.output_color_space = 'sRGB'; p.io.output_cctf_encoding = False
    p.io.scan_film = True; p.camera.auto_exposure = False
    p.debug.deactivate_spatial_effects = True; p.debug.deactivate_stochastic_effects = True
    p.film_render.grain.active = False; p.film_render.halation.active = False
    p.io.output_gamut_compress = dataclasses.replace(p.io.output_gamut_compress, algorithm='off')
    return p


def bake_scan(film, n, scanner, simulate, init_params):
    import colour
    p = neg_params(film, init_params)
    neg = lambda x: np.maximum(np.asarray(simulate(x, p), np.float64), 1e-5)
    # šedá škála → přímka hustoty po kanálech (oranžová maska a různé gamy vrstev)
    ev = np.linspace(-3, 3, 13); le = np.log10(.18 * 2.0 ** ev)
    D = -np.log10(neg(((.18 * 2.0 ** ev)[:, None] * np.ones(3))[None])[0])
    fit = [np.polyfit(le, D[:, c], 1) for c in range(3)]
    lin_log = lambda N: np.stack([(-np.log10(N[..., c]) - fit[c][1]) / fit[c][0] for c in range(3)], -1)
    # barevná matice skeneru z barevné tabulky (jen odchylky od průměru kanálů → šedá zůstane)
    cc = colour.CCS_COLOURCHECKERS['ColorChecker24 - After November 2014']
    lin = np.array([colour.XYZ_to_sRGB(colour.xyY_to_XYZ(v), apply_cctf_encoding=False) for v in cc.data.values()]).clip(1e-4, None)
    X = np.concatenate([lin * k for k in (.5, 1, 2)])[None]
    L = lin_log(neg(X)[0]); T = np.log10(X[0])
    M = np.linalg.lstsq(L - L.mean(1, keepdims=True), T - T.mean(1, keepdims=True), rcond=None)[0].T
    # LUT: log vstup → negativ → sken
    s = SCANNERS[scanner]
    L = lin_log(neg(log_identity(n)))
    m0 = L.mean(-1, keepdims=True); L = m0 + (L - m0) @ M.T
    lg = (L - np.log10(.18)) / np.log10(2)
    m = lg.mean(-1, keepdims=True)
    ws = 1 - np.clip((m + 3) / 3, 0, 1); wh = np.clip((m - .5) / 2.5, 0, 1); wm = np.clip(1 - ws - wh, 0, 1)
    lg = lg + ws * np.array(s['sh']) + wm * np.array(s['mid']) + wh * np.array(s['hi'])
    o = -np.log(s['top'] / .18 - 1)
    y = s['top'] / (1 + np.exp(-(s['g'] * lg + o)))  # S křivka jako papír: šedá → 0,18, pata a rameno
    l = y @ [.2126, .7152, .0722]
    y = np.clip(l[..., None] + (y - l[..., None]) * s['sat'], 0, 1)
    y = np.where(y <= .0031308, y * 12.92, 1.055 * np.power(y, 1 / 2.4) - .055)
    return hue_adj(np.clip(y, 0, 1), s.get('hue', [])).reshape(n, n, n, 3)


def hue_adj(e, hs):  # posun odstínu a sytosti po barvách (střed °, šířka °, posun °, násobek sytosti) na sRGB
    if not hs: return e
    import colour
    hsv = colour.RGB_to_HSV(e); h = hsv[..., 0] * 360
    for c, wd, sh, sm in hs:
        d = (h - c + 180) % 360 - 180; w = np.clip(1 - np.abs(d) / wd, 0, 1) ** 1.5 * np.clip(hsv[..., 1] / .15, 0, 1)
        h = h + sh * w; hsv[..., 1] = np.clip(hsv[..., 1] * (1 + (sm - 1) * w), 0, 1)
    hsv[..., 0] = (h % 360) / 360
    return np.clip(colour.HSV_to_RGB(hsv), 0, 1)


def identity(n):
    g = np.linspace(0, 1, n, dtype=np.float64)
    b, gg, r = np.meshgrid(g, g, g, indexing='ij')  # pořadí: b nejpomalejší, r nejrychlejší (jako .cube)
    return np.stack([r, gg, b], -1).reshape(n * n, n, 3)  # řádky = (b, g), sloupce = r


def bake(code, film, prt, n, simulate, init_params):
    p = init_params(film, prt or 'kodak_portra_endura')
    p.io.input_color_space = 'sRGB'; p.io.input_cctf_decoding = True
    p.io.output_color_space = 'sRGB'; p.io.output_cctf_encoding = True
    p.io.scan_film = prt is None
    p.camera.auto_exposure = False
    p.debug.deactivate_spatial_effects = True; p.debug.deactivate_stochastic_effects = True
    p.film_render.grain.active = False; p.film_render.halation.active = False
    p.settings.use_enlarger_lut = False; p.settings.use_scanner_lut = False
    p.io.output_gamut_compress = dataclasses.replace(p.io.output_gamut_compress, algorithm='off')  # komprese rozsahu ubírala sytost a stahovala bílou → filmy vypadaly stejně
    out = np.clip(np.asarray(simulate(identity(n), p), dtype=np.float64).reshape(n, n, n, 3), 0, 1)  # [b, g, r, c]
    return normalize_white(out, n)


SOFTEN = 0.0  # zjemnění tónové křivky (staré pečení 0.5 smazávalo rozdíly mezi filmy), teď vypnuto


def normalize_white(lut, n, target=.95):
    """Jen zesílení podle neutrální bílé (bílá papíru → ~0.95); křivka, barva bílé a černé filmu zůstávají."""
    w = lut[n - 1, n - 1, n - 1].mean()
    out = np.clip(lut * (target / max(w, .05)), 0, 1)
    return soften_tone(out, n) if SOFTEN else out


def soften_tone(lut, n):
    """Zjemní tónovou křivku: tisk ze spektrafilmu silně stahuje stíny (vstup 48/255 → ~15) a bílou drží kolem 205.
    Každý kanál výstupu se přemapuje g(y) = s·N⁻¹(y) + (1−s)·y, kde N je průměrná neutrální křivka LUT.
    Neutrály se tak posunou napůl k lineární odezvě, barevné posuny a sytost filmu vůči neutrálům zůstanou."""
    x = np.linspace(0, 1, n)
    N = np.maximum.accumulate(np.array([lut[i, i, i].mean() for i in range(n)]))
    N = N + np.arange(n) * 1e-7  # ostře rostoucí kvůli interpolaci
    return np.clip(SOFTEN * np.interp(lut, N, x) + (1 - SOFTEN) * lut, 0, 1)


def SOFTEN_SET(v):
    global SOFTEN
    SOFTEN = v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spektrafilm', default=None, help='cesta k spektrafilm/src (když není nainstalovaný)')
    ap.add_argument('--size', type=int, default=33)
    ap.add_argument('--soften', type=float, default=SOFTEN, help='zjemnění tónové křivky 0–1 (viz soften_tone)')
    ap.add_argument('--only', default='')
    ap.add_argument('--cube', action='store_true', help='uložit i .cube (appka si .cube umí vyrobit sama při exportu)')
    ap.add_argument('--log', action='store_true', help='film v2: log vstup ze scénického světla → luts/log/')
    ap.add_argument('--scanner', default=None, choices=list(SCANNERS), help='sken negativu místo tisku → luts/scan/<skener>/')
    ap.add_argument('--out', default=None)
    a = ap.parse_args()
    a.out = a.out or os.path.join(os.path.dirname(__file__), '..', 'luts', *(['scan', a.scanner] if a.scanner else ['log'] if a.log else []))
    if a.spektrafilm: sys.path.insert(0, a.spektrafilm)
    SOFTEN_SET(a.soften)
    from spektrafilm import init_params, simulate
    from PIL import Image
    os.makedirs(a.out, exist_ok=True)
    meta = []
    for code, (film, prt) in FILMS.items():
        if a.only and code not in a.only.split(','): continue
        if a.scanner and prt is None: continue  # diapozitiv se skenuje rovnou jako pozitiv
        if code in V2_LOG_ONLY and (a.scanner or not a.log): continue  # film V2 má jen log LUT
        t = time.time(); n = a.size
        lut = bake_scan(film, n, a.scanner or prt, simulate, init_params) if a.scanner or prt == 'kino' else bake_log(film, prt, n, simulate, init_params) if a.log else bake(code, film, prt, n, simulate, init_params)
        img = np.zeros((n, n * n, 3), np.uint8)  # y = g, x = r + b*n
        for b in range(n): img[:, b * n:(b + 1) * n] = np.round(lut[b] * 255)
        Image.fromarray(img).save(os.path.join(a.out, f'{code}.png'), optimize=True)
        if a.cube:
          with open(os.path.join(a.out, f'{code}.cube'), 'w', encoding='ascii') as f:
            f.write(''.join(f'# {h.format(code=code, film=film)}\n' for h in HEADER))
            f.write(f'TITLE "Qamera {code}"\nLUT_3D_SIZE {n}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n')
            for v in lut.reshape(-1, 3): f.write(f'{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n')
        meta.append({'code': code, 'film': film, 'print': prt, 'size': n, **({'input': 'log2(x/0.18) -8..+6 EV', **({'scanner': a.scanner} if a.scanner else {})} if a.log or a.scanner else {'soften': SOFTEN})})
        print(f'{code:8s} {film:24s} {time.time() - t:5.1f} s', flush=True)
    path = os.path.join(a.out, 'films.json')
    old = json.load(open(path, encoding='utf-8')) if os.path.exists(path) else []
    keep = [m for m in old if m['code'] not in {x['code'] for x in meta}]
    json.dump(sorted(keep + meta, key=lambda m: list(FILMS).index(m['code'])), open(path, 'w', encoding='utf-8'), indent=1)


if __name__ == '__main__':
    main()
