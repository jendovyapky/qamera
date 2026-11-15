# Přibalí do appky (ios/Web) všechno, co web jinak stahuje z internetu: fonty Google, transformers.js + onnxruntime (wasm),
# model hloubky Depth Anything V2 Small (q8) a qrcode.js. Spouští se v GitHub Actions před sestavením appky.
# python tools/offline.py ios/Web
import os, re, sys, urllib.request

root = sys.argv[1]
off = os.path.join(root, 'offline')
UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'

def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()

def save(rel, data):
    p = os.path.join(off, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(data)
    print(f'{rel}: {len(data) // 1024} kB')

# 1) fonty: CSS z Google Fonts (woff2 pro Safari), soubory vedle, odkazy relativně
FONTS = 'https://fonts.googleapis.com/css2?family=Doto:wght@500;700;900&family=Geist:wght@300..700&family=Geist+Mono:wght@400;500;600&family=Silkscreen:wght@400;700&display=swap'
css = get(FONTS).decode('utf-8')
urls = sorted(set(re.findall(r'url\((https://fonts\.gstatic\.com/[^)]+)\)', css)))
assert urls, 'žádné fonty'
for i, u in enumerate(urls):
    name = f'f{i}.woff2'
    save('fonts/' + name, get(u))
    css = css.replace(u, name)
save('fonts/fonts.css', css.encode('utf-8'))

# 2) transformers.js 3.7.1 + wasm onnxruntime (výchozí wasmPaths ukazuje na stejnou složku jsDelivr)
TF = 'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.7.1/dist/'
for f in ['transformers.min.js', 'ort-wasm-simd-threaded.jsep.mjs', 'ort-wasm-simd-threaded.jsep.wasm']:
    save('tf/' + f, get(TF + f))

# 3) model hloubky (na iPhonu se používá jen q8 přes WASM)
HF = 'https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/main/'
for f in ['config.json', 'preprocessor_config.json', 'onnx/model_quantized.onnx']:
    save('models/onnx-community/depth-anything-v2-small/' + f, get(HF + f))

# 4) QR kód receptů
save('qrcode.min.js', get('https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js'))

# 5) stránka v appce bere fonty z balíčku
ix = os.path.join(root, 'docs', 'preview', 'index.html')
s = open(ix, encoding='utf-8').read()
link = f'<link rel="stylesheet" href="{FONTS}">'
assert s.count(link) == 1, 'odkaz na fonty nenalezen'
s = s.replace(link, '<link rel="stylesheet" href="../../offline/fonts/fonts.css">')
s = s.replace('<link rel="preconnect" href="https://fonts.googleapis.com">\n', '').replace('<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n', '')
open(ix, 'w', encoding='utf-8', newline='\n').write(s)
print('offline ok')
