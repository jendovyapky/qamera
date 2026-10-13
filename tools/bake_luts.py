"""Pečení filmových LUT pro Qameru ze spektrafilmu (Andrea Volpato, https://github.com/andreavolpato/spektrafilm).

Spouští se lokálně (nebo v GitHub Actions), ne v appce:
    python tools/bake_luts.py --spektrafilm cesta/ke/spektrafilm/src [--size 33] [--only P400,G200]

Výstup do luts/:
  <KOD>.png   – LUT pro appku: N*N x N obrázek, řez podle modré vedle sebe (x = r + b*N, y = g), 8bit sRGB
  <KOD>.cube  – (s --cube) stejná LUT pro DaVinci / Premiere / Photoshop (s atribucí CC BY-SA 4.0 v hlavičce)
  films.json  – metadata (kód, profil filmu a tisku)

Vstup LUT = sRGB, výstup = sRGB. Prostorové a náhodné efekty (grain, halation, difúze, ostření)
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
    'C200':    ('fujifilm_c200', 'fujifilm_crystal_archive_typeii'),
    '400H':    ('fujifilm_pro_400h', 'fujifilm_crystal_archive_typeii'),
    'SX400':   ('fujifilm_xtra_400', 'fujifilm_crystal_archive_typeii'),
    'PV100':   ('fujifilm_provia_100f', None),
    'VEL':     ('fujifilm_velvia_100', None),
}
HEADER = ['Qamera film LUT {code} ({film})',
          'Derived from spektrafilm by Andrea Volpato',
          'https://github.com/andreavolpato/spektrafilm',
          'Licensed CC BY-SA 4.0 https://creativecommons.org/licenses/by-sa/4.0/',
          'Modified by Qamera (jendovyapky): baked to 3D LUT sRGB->sRGB, spatial effects off (grain, halation, diffusion).']


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
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), '..', 'luts'))
    a = ap.parse_args()
    if a.spektrafilm: sys.path.insert(0, a.spektrafilm)
    SOFTEN_SET(a.soften)
    from spektrafilm import init_params, simulate
    from PIL import Image
    os.makedirs(a.out, exist_ok=True)
    meta = []
    for code, (film, prt) in FILMS.items():
        if a.only and code not in a.only.split(','): continue
        t = time.time(); lut = bake(code, film, prt, a.size, simulate, init_params); n = a.size
        img = np.zeros((n, n * n, 3), np.uint8)  # y = g, x = r + b*n
        for b in range(n): img[:, b * n:(b + 1) * n] = np.round(lut[b] * 255)
        Image.fromarray(img).save(os.path.join(a.out, f'{code}.png'), optimize=True)
        if a.cube:
          with open(os.path.join(a.out, f'{code}.cube'), 'w', encoding='ascii') as f:
            f.write(''.join(f'# {h.format(code=code, film=film)}\n' for h in HEADER))
            f.write(f'TITLE "Qamera {code}"\nLUT_3D_SIZE {n}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n')
            for v in lut.reshape(-1, 3): f.write(f'{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n')
        meta.append({'code': code, 'film': film, 'print': prt, 'size': n, 'soften': SOFTEN})
        print(f'{code:8s} {film:24s} {time.time() - t:5.1f} s', flush=True)
    path = os.path.join(a.out, 'films.json')
    old = json.load(open(path, encoding='utf-8')) if os.path.exists(path) else []
    keep = [m for m in old if m['code'] not in {x['code'] for x in meta}]
    json.dump(sorted(keep + meta, key=lambda m: list(FILMS).index(m['code'])), open(path, 'w', encoding='utf-8'), indent=1)


if __name__ == '__main__':
    main()
