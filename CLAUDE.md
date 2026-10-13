# Qamera – poznámky pro Clauda

**Qamera** – webová aplikace (PWA) na focení a úpravu fotek přímo v mobilu, zaměřená na **film a vintage**:
emulace starých filmů (Kodak, Fuji…), filmové zrno, halace, barvy, saturace. Na mobilu rychlá a jednoduchá
ve stylu **Prequel**, na PC se používá spíš jako **Lightroom**. Celá v **češtině**, majitel je Honza.

- Plán: https://qamera.jendovyapky.eu (Cloudflare Pages), repo `jendovyapky/qamera` (**veřejné, GPL-3.0**)
- Další appky ze stejné rodiny: Mraq (`jendovyapky/pocasi`, mraq.jendovyapky.eu), Klapqa (`jendovyapky/klapqa`, privátní).
  Z nich brát vizuální inspiraci: maskoti s **tečkovýma robotíma očima** (font Doto, styl Cozmo/RoboEyes), úvodní animace,
  zrnité gradienty, fonty Geist / Geist Mono / Doto. Jak je dělaný maskot a intro: viz `CLAUDE.md` a `mraq.js` / `intro.js` v repu `pocasi`.

## Stav
- [x] Zadání a rozhodnutí (tento soubor), inspirace v `docs/inspo/`
- [x] Repo `jendovyapky/qamera` + Cloudflare Pages projekt `qamera` (qamera.pages.dev, produkce = `main`, náhledy větví, **zatím bez odkazu z rozcestníku jendovyapky.eu**)
- [ ] Fáze 1: klikací HTML náhled hlavních obrazovek (zlatý standard pro vzhled a motion, schvaluje Honza) – hotový v `docs/preview/index.html`, screenshoty v `docs/screens/`, **čeká na schválení**. Kořenový `index.html` zatím jen přesměrovává na náhled.
  - Git na Honzově PC: GitHub účet **jendovyapky** je v Git Credential Manageru vedle `lichicks`; repo má v remote URL `jendovyapky@` → push jde pod správným účtem.
- [x] Fáze 2: `tools/bake_luts.py` peče 16 filmů ze spektrafilmu do `luts/*.png` (33³, sRGB→sRGB, `--soften 0.5` zjemní tiskovou křivku – originál moc stahoval stíny). Shader je načte jako 3D texturu (jen přes http/https, z disku zůstává jednoduchý shader). Pečení lokálně: Python 3.13 venv, spektrafilm z gitu, chybějící `exiv2/rawpy/lensfunpy/pyfftw` stačí jako prázdné stuby.
- [x] Export fotky v plném rozlišení (max 4096 px, i s rámem a datumovkou), sdílení na mobilu / stažení na PC; export blob karty; .cube / JSON / XMP z Film scanu.
- [x] Hloubka (Depth Anything V2 Small přes transformers.js 3.7.1 z jsDelivr, WebGPU fp16 → WASM q8): Bokeh (ťuknutí = ostření), Mlha, 3D paralaxa, Mapa. Mapa se ukládá do IndexedDB.
- [x] Datumovka (sedmisegment, 3 formáty, 3 barvy), Rám: Glow / Negativ / Instant. Jednorázovka a role se ukládají, arch je položka galerie se zoomem. `sw.js` (VERSION) pro offline.
- [ ] Další: skutečná appka mimo `docs/preview` (rozdělení do modulů), ladění na iPhonu/Androidu, dlaždicový export nad 4096 px, video.

## Přísná pravidla
- **Nikdy nesahat na nic, co souvisí se studiem** (`studiodepo.cz`, repozitáře DEPO / depo-app, studiový Cloudflare).
  Projekty pod `jendovyapky` drž úplně oddělené.
- **Na rozcestník jendovyapky.eu Qameru nepřidávat**, dokud Honza neřekne. Subdoménu a vlastní Pages projekt používat smíš.
- Platby, hesla a API klíče zadává Honza sám. Když je potřeba přístup (GitHub, Cloudflare, Webglobe, Google Drive…), řekni.
- Nikde nepoužívat slogan „appky pro líný lidi“.
- **Kód ani modely z `EtonMu/deep-analog` nepoužívat** – licence „All rights reserved“ + patent pending, váhy nejsou veřejné.
  Funkci (reference → film/LUT + export) stavíme **vlastní** z veřejných metod (viz Reference match).
- Po větší změně zvýšit `VERSION` v `sw.js`, ať se telefonům stáhne nová verze.
- Pokud Claude usoudí, že nějaký nástroj / postup dá lepší výsledek, **řekne to předem**.

## Rozhodnutí z připomínek (náhled 0.4)
- **Kamera:** žádná clona (nejde ovládat). ISO = **push/pull** filmu (nad citlivostí víc kontrastu a grainu, pod ní měkčí). Čas = **AUTO → long exposure** 1/4 s … 15 s.
  Gesta v hledáčku: nahoru/dolů = EV (zaklapne na nule, dvojklik na pilulku EV = reset), doprava = delší čas, HUD s pixelovou ikonou. Spoušť během odpočtu / expozice ruší.
- **Hledáček = přesně výsledná fotka** (poměr podle formátu: 3:4 výchozí, 9:16, 35 mm, half, 6×6, 6×7; formát přepíná štítek v hledáčku i FORMÁT v displeji). Žádné šedé masky.
- Typografie ovládání kamery **Silkscreen** (pixelový font k pixelovým ikonám), spoušť a úchyt v pixel/dither stylu. Expozimetr = zebra (ikona v hledáčku).
- **Oblíbené filmy** (srdíčko) jsou ve výběru první. **Film scan** (místo Reference) uloží vlastní film použitelný jako filtr i ve foťáku.
- **Recepty** = uložený vzhled, sdílení odkazem a QR (#recept=…), použití i ve foťáku.
- Efekty: **Soft glow** (difúze, výchozí podle filmu), **Dither**, **Pixel art**, **Glow rám** (ambilight okraj), **IR** film (Aerochrome). **Double** je efekt v editoru (prolnutí / silueta jedné fotky vyplněná druhou, tmavé pozadí jako Klapqa) a „double ve foťáku“ (duch prvního snímku).
- **Blob karta:** tmavé tečkované pozadí jako Klapqa; tvary podle `docs/inspo/blob inspo*` (rozlitý rám, hvězdy, jiskry, kytky, puntíky, vlnovky, známka, měkký rám, vzory), **Obrátit**, **Krytí**, **+** nakreslit vlastní, **kostka** = náhodný tvar.
- **Blob v2:** Krytí nahradil **Dissolve** (okraj tvaru se rozpadá do zrnitých teček, inspo `dissolve effect*`), prolnutí NORMÁL / SCREEN / GLOW, **Velikost** tvaru, **presety** bloba, kreslený tvar se sám uzavře a vyhladí.
- **Glow rám** = fotka jako obrazovka v tmavé místnosti, světlo z krajů se rozlévá do okolí (inspo `glow background efekt.mp4`), fotku nerozmazávat.
- Kamera: ikona foťáku v hledáčku zapíná skutečnou kameru (žádná pilulka DEMO/ŽIVĚ); nad oběma kolečky proužek (EV / ZOOM); ISO a EV pilulky v hledáčku jen při schovaném ovládání.
- Efekty v editoru neopakují to, co je v Úpravách. Vlastní filmy: podržení = přejmenovat / smazat. Galerie: filtr podle filmu (čipy).
- **Ikona appky = tečkové Q** (návrh C, `icons/`: icon.svg, maskable, PNG 180/192/512, favicon), `manifest.webmanifest` v kořeni. Ostatní návrhy v `docs/ikona/`.
- Náhled ukládá fotky do IndexedDB (originál JPEG + úpravy JSON + hloubková mapa). Recepty, vlastní filmy, oblíbené, skryté filmy, presety bloba, jednorázovka a role jsou v localStorage / IndexedDB.

## Rozhodnutí z připomínek (náhled 0.6–0.7)
- **Efekty s nastavením (Double, Dither, Pixel art, Rám, Hloubka, Datumovka) se otevírají v panelu místo mřížky efektů** (šipka zpět, Vypnout vpravo). Vysouvací okno jen na výběr fotek.
- **Zarovnání všude:** přepínače v panelech na celou šířku s rovnoměrnými tlačítky, řádky barev mají popisek ve stejném sloupci jako posuvníky, hlavička panelu symetrická. Textové pole a tlačítko vedle sebe stejně vysoké (focus jen okrajem uvnitř). Honza na to je citlivý – kontrolovat screenshoty.
- Kostka u blobu = jeden náhodný slot (tvar i parametry), ne nový tvar pokaždé. Dvojťuk na fotku v blobu = vycentrovat.
- **Moje filmy** (ikona filmu v čipech galerie / menu): náhled každého filmu, podržení = před/po, oko = skrýt z výběru, srdíčko = oblíbený.
- Jednorázovka: před vyvoláním se ptá na název, arch bez kroužků, uloží se do galerie.
- **0.7.1:** pryč 3D paralaxa, rám Negativ a Datumovka (Honzovi se nelíbí, blob stačí). Blob: paleta jen po filmu, dole Text zap/vyp · Uložit blob · Export. Všude „Export“ místo „Sdílet“ (u obrázků). Hloubka: když telefon nestíhá živě (>45 ms), přepočet až po puštění posuvníku s načítáním; ukazatel načítání jen skutečné fáze (MB stahování / z telefonu / příprava / výpočet). Fotky v paměti max 2048 px (iPhone 13 padal), export dekóduje originál z IndexedDB. Velké tlačítko „Zapnout kameru“ v hledáčku, dokud se uživatel nezeptal.
- **0.7.2 / iOS 26 „brada“:** nainstalovaná appka nesahá ke spodnímu okraji (chyba iOS, neroztahovat přes `lvh` – pak se obsah ořízne). Pás dole kreslí pozadí `<html>`, proto `chinColor()` ho barví podle prvku úplně dole. Model hloubky se po výpočtu hned uvolní (`dispose`), příště se načte z cache. Film scan má Vypnout. Kostka u blobu jen vpravo nahoře.
- **Film scan = vlastní obrazovka** (ne efekt v editoru): otevírá se z „+“ ve výběru filmu ve foťáku, z karty „+“ na konci Mých filmů a z menu. Náhled na aktuálním záběru kamery, síla přenosu se uloží do filmu. Export .cube / JSON vlastního filmu = podržet film.
- **0.8:** stavový řádek `black` (ne `black-translucent`) – iOS 26 jinak zkrátí okno nainstalované appky o výšku stavového řádku (WebKit bug 301108) a dole zůstane pás; `chinColor` zrušený. iPad = mobilní rozhraní ve sloupci 600 px uprostřed. Chyby JS se ukážou jako toast (Honza pošle screenshot).
- **PC verze = skutečná appka:** na počítači (ne dotyk, šířka > 700) se otevře rovnou Lightroom rozložení přes celé okno (`body.pcapp`); náhled s telefonem přes tlačítko Mobil nebo `#nahled`. Import (tlačítko, + v pásu, přetažení), Export fotky / .cube, ořez (C + tažení, kolečko), Rám, Hloubka, Styl, Flash, Film scan v okně, Del = smazat.
- Rám = jen **Glow** (+ síla glow, poměr, prostor); Instant zrušený. Hloubka: režimy Bokeh / Mlha / **Halation** (záře jen u vzdálených světel) / Mapa; na iOS model přes WASM (WebGPU + WebGL na iPhonu 13 došla paměť), při ztrátě WebGL obnova v úsporném režimu. **Blesk** = vyp / bílý / vintage (teplé tvrdé světlo, i jako „Flash“ v Úpravách; přední kamera svítí displejem v barvě).
- Moje filmy: vlastní ukázková fotka (Vyfotit / Z galerie – telefon i Qamera). Film scan: výběr i pro „Tvůj záběr“, ťuknutí na náhled = celá obrazovka (zavřít křížkem nebo přejetím do strany).
- **Spodní pás na iOS 26 vyřešený** (Honza ověřil): stavový řádek `black` + **appku smazat z plochy a přidat znovu** (iOS čte meta jen při přidání). Při změně těchto meta vždycky připomenout.
- PC: rozložení se přizpůsobuje oknu (clamp sloupců, schovávání nápovědy kláves), miniatury i galerie podle ořezu (`phAr`). Double, Blob karta a Recepty se na PC otevřou v telefonním rozhraní v okně (Hotovo / Esc).
- **0.9:** PC má Double (pravý panel), Blob kartu (přes střed + pravý panel, stejné ovládací prvky se přesunou z mobilní obrazovky) a Recepty (levý panel: uložit, použít, odkaz, smazat) nativně – telefon v okně už se nepoužívá. Nové tvary blobu podle `blob inspo V2*` (padající hvězda s dírou, řetěz jisker, jiskry na stoncích, 3 hvězdy, had, mřížka kytek, půlkopretina, obrysové kytky, pole kopretin, smyčky). **Kopírovat / vložit úpravy** (jen podržením fotky v galerii, na PC Ctrl+Shift+C/V i na víc fotek přes Ctrl+klik v pásu). Ořez: posun podle poměru stran (`cropCover`).
- **0.10:** PC pravé tlačítko na fotce v pásu = stejná nabídka jako podržení v mobilu (Upravit, Export, Kopírovat/Vložit úpravy, Vybrat, Blob karta, Smazat; s výběrem Ctrl+klik pro všechny vybrané). Mobil: podržení → „Vybrat víc fotek“ (lišta: Zrušit · Další = arch / vložit úpravy / smazat · Export). **Export = okno se skutečným postupem** (originál → film → JPEG pro každou fotku, Zrušit); mobil pak „Uložit N fotek“ (sdílení potřebuje čerstvé ťuknutí), PC stáhne JPEG nebo ZIP (vlastní ZIP bez komprese). **Narovnání horizontu** (ikona v Ořezu, tlačítko na PC): projekční profily hran −15…15°; otáčení v shaderu je teď bez zkosení. PC: Shift nad filmem = dočasný náhled. Žlutá tečka = upravená, ještě neexportovaná fotka (`ph.dirty`, v IndexedDB).
- **0.11:** **IR** = barevné infra jako přestavěný foťák (inspo `infrared inspo.webp`: zeleň růžovobílá, nebe/voda tyrkysové, okolí pudrově růžové), **IR400** = ČB infra ve stylu Rollei Infrared 400 + R72 (Woodův efekt: zeleň bílá, nebe a voda černé). Blob: **tvar z fotky** (ikona foťáku vedle +: vyfotit / telefon / galerie → maska podle jasu, Otsu, práh, vyhlazení, obrátit; náhled černě na bílém), vlastní tvary se pamatují (podržet = smazat), **MIX** v paletě = víc barev, tvary se náhodně obarví (zapne Obrátit), tvary V3 (hvězdy, mřížka hvězd, mraky, list, paprsky, kvítky, spirála, korál, srdce, obrysové hvězdice). Export karty = **PNG s průhledným pozadím**. Mřížka efektů 4 sloupce na celou šířku. `blob inspo V3 5.png` je prázdný soubor.
- **0.13:** z efektů z hloubky zůstal jen **LiDAR** (Fisheye, Layers a návrhy prism/halftone/thermal/déšť/pod vodou… Honza zamítl – kód smazaný). LiDAR: 3D mračno bodů (`lidarRender`), Otočení/Náklon i **tažením po fotce** (`lidarDrag`), styl Foto/Sken, 4 s video smyčka. Efekty = 8 dlaždic (4 sloupce).
- **Blob V4** (`blob inspo V4*`): tvary kreslené **tahem tuše** (`ink()` – chvění, proměnlivá tloušťka, zúžené konce; Honza chce ruční/cartoon nedokonalosti, ne „clean“ geometrii). Ptáci, vlaštovky, dráty, stonky, máky, souhvězdí, blesky, vázy z 19 (každá zvlášť, stonky až na dno). **Postavy = Honzovo SVG** (`docs/inspo/figures-tetovani.svg`, `FIG_D`). Kategorie tvarů (VŠE/ZÁKLAD/HVĚZDY/KYTKY/PTÁCI/VZORY/IKONY/MOJE). Po připomínkách: vázy jen u „balls 3“, ostatní vázy = jen kytky se stonky ke spodnímu okraji (`nov`); tulipány a kytice smazané; vykřičníky původní; přehrávač minimalistický (malý, čistý); V4 18 = **špendlík** (`pin`). `V4 6.png` a `V4 18.png` jsou prázdné.
- Telefon na šířku zůstává v mobilním rozložení (`pointer:coarse`). Kamera: ikona zmizí po povolení, appka si pamatuje zapnutí, DEMO scéna v menu.
- **Arch** (ne „kontaktní arch“): z role, z dneška (od půlnoci) nebo výběrem fotek. **Jednorázovka** = filtr na den s oknem od–do, ráno vyvolání → arch.

## Licence a poděkování (povinné)
Qamera je **GPL-3.0** (veřejné repo) – kvůli Spektrafilmu. V appce musí být obrazovka **„O appce / Poděkování“**, kde jsou klikací:
> **Spektrafilm for Android** by **Akshay Sharma** — https://github.com/thetechgeekko/Spektrafilm-android
> Film modeling powered by **spektrafilm** (Andrea Volpato) — https://github.com/andreavolpato/spektrafilm

- **Filmové LUT** upečené ze spektrafilmu jsou podle `SPEKTRAFILM_LICENSE.txt` pod **CC BY-SA 4.0** (ne GPL). Ve složce `luts/`
  musí ležet kopie té licence (beze změn) + `CHANGELOG.txt` se změnami oproti originálním profilům. Platí i pro LUT/presety,
  které z appky exportuje uživatel, pokud v sobě nesou film → do exportu dát hlavičku s atribucí a licencí.
- Depth model: jen **Depth Anything V2 Small** (Apache-2.0). Base/Large jsou nekomerční (CC-BY-NC) → nepoužívat.
- Port barevného přenosu z `pengbo-learn/python-color-transfer` (MIT) – zachovat copyright v hlavičce souboru.
- Názvy filmů: **vlastní kódy**, ne ochranné známky v názvu (Kodak/Fuji jen popisně, „ve stylu“). Viz Filmy.

## Zadání od Honzy (shrnutí)
- Focení i úprava v mobilu. **Jednoduché UI** pro rychlý edit a používání filmů/filtrů; přepínač **Advanced** s pokročilými funkcemi.
- Úpravy: barvy, saturace, filmový šum/zrno, **emulace starých filmů** (Kodak barvy, Fuji…), halace. Vintage, film.
- Mobil = styl Prequel. PC = styl Lightroom (postranní panely, histogram, klávesové zkratky).
- **Slow shutter efekt při focení.**
- Funkce jako deep-analog: vložíš **referenci**, appka předělá tvoji fotku do jejího stylu / filmu; export **LUT (.cube), JSON preset, Adobe preset**.
- **Expensive motion design** je základ.
- **Zablokované přibližování stránky** (jako ve všech Honzových appkách), ALE **pinch zoom při ořezu** v editu a **zoom při focení** zůstává.
- **Depth efekt jen jako efekt v editu** (ne v kameře).
- Honza chce průběžné screenshoty / HTML náhledy důležitých věcí a **nápady do budoucna klidně dál navrhovat**.
- Hotfixy chce dělat i **z mobilu na dálku** (Claude Code v appce/na webu nad tímhle repem).

## Inspirace (`docs/inspo/`)
- `kamera-dialy.jpg` – hlavní vzor kamery: oranžovo-žluté „LCD“ (clona / ISO / čas, EV, expozimetr −3…+3, MODE MATRIX),
  pod ním dvě **otočná kolečka** (ISO a čas) s tečkovanou stupnicí a červeným „A“, dole přepínač režimu (žlutý), velká bílá spoušť, kulatá tlačítka GRID / RESET / SET. Font displeje = segmentový/pixelový.
- `kamera-ui.png` – minimalistický hledáček se zaoblenými rohy, pilulky v náhledu (zoom „1×“, ISO, EV), řada ikon pod ním (ostření, samospoušť, blesk, otočení), dole film vlevo, spoušť jako pilulka, galerie vpravo.
- `vyber-filmu.png` – výběr filmu jako **vodorovný karusel ikon fotoaparátů/kazet**, vybraný uprostřed větší s názvem nahoře (kód + drobný „chemický“ podtitul), šipka ↓ pro rozbalení.
- `galerie.jpg` – tmavá galerie: nahoře **„role“ jako skleněné karty** s barevnými objekty uvnitř, pod tím masonry 2 sloupce, dole plovoucí skleněné vyhledávání „Find or create anything…“ s barevnou tečkou.
- `blob-tvary.jpg` – **organické blob tvary**: vyfocená fotka se ořízne do takového tvaru, pozadí z palety barev (paleta vytažená z fotky, před i po úpravě / podle filmu). Na čtverečkovaném papíře.
- `ikony-pixel-zlute.jpg`, `ikony-pixel-cerne.jpg` – **pixelové ikony 24 px**: šedé neaktivní, aktivní **žluté se září** na tmavých dlaždicích. Vlastní sada ve stejném stylu (ne kopie Nucleo).
- `depth-efekt.jpg` – hloubková mapa z fotky → efekty podle hloubky.

## Architektura (jako Mraq: bez frameworku, bez buildu)
- Čisté statické soubory, ES moduly, **WebGL2**. Každý push do `main` = produkce (Cloudflare Pages). **Vývoj na větvi `dev`**
  → Pages preview URL (`dev.qamera.pages.dev`) na zkoušení v mobilu; do `main` jen ověřené. Hotfix z mobilu = malá změna + push.
- Fotky jen **lokálně v zařízení** (IndexedDB: originál + parametry úprav jako JSON → úpravy jsou nedestruktivní). Žádný server, žádné účty.
- Velká data: filmové LUT jsou malé (33³ ≈ desítky–stovky kB na film) → klidně v repu / na Pages (limit 25 MB na soubor).
  Depth model (~25 MB) se stahuje z Hugging Face CDN až při prvním použití a cachuje. **Google Drive není potřeba.**

### Plánované soubory
- `index.html`, `style.css`, `app.js` (router obrazovek, stav), `sw.js`, `manifest.webmanifest`, `icons/`
- `engine/` – `pipeline.js` (WebGL2 render graf), `shaders/*.glsl`, `lut.js` (načtení LUT do 3D textury), `export.js` (plné rozlišení po dlaždicích)
- `camera/` – `camera.js` (getUserMedia, schopnosti zařízení), `slowshutter.js`, `dials.js`
- `edit/` – `editor.js`, `crop.js` (pinch zoom, rotace, poměry), `blob.js`, `depth.js`
- `match/` – `transfer.js` (Reinhard Lab, Pitié IDT + regrain), `fitlut.js`, `exporters.js` (.cube / JSON / XMP)
- `gallery/` – galerie, role, jednorázovka
- `luts/` – upečené filmy (PNG/bin) + `SPEKTRAFILM_LICENSE.txt` + `CHANGELOG.txt` + `films.json` (metadata)
- `tools/bake_luts.py` – pečení LUT ze spektrafilmu (spouští se lokálně / v GitHub Actions, ne v appce)
- `docs/inspo/`, `docs/preview/` (HTML náhledy), `docs/screens/` (screenshoty)

## Engine – pipeline (stejný shader pro živý hledáček i export)
1. vstup sRGB → lineární světlo
2. základ: expozice (EV), vyvážení bílé (teplota/tint), kontrast, světla/stíny, saturace/vibrance
3. **film**: 3D LUT ze spektrafilmu (negativ → tisk → sken), síla filmu 0–100 %
4. **Halation** (červeno-oranžová záře kolem světel, prahová, rozmazaná po vrstvách), **Bloom** (měkká bílá záře světel)
5. **Grain** – v souřadnicích fotky (stejný v náhledu i exportu), hladký šum ve 3 natočených oktávách, shluky, barevná oblaka barviv, odezva podle jasu a „ISO“; animovaný v hledáčku, statický (seed) v exportu. Typy: **Fine, Classic, Cine, Push, Mono, Expired** (výchozí podle filmu). Hash šumu **celočíselný (PCG)** – fract hash se na velkých souřadnicích viditelně opakoval
6. Vignette, Fade, datumovka, okraje negativu s vlastním značením. **Light leaky ani prach nedělat** (Honza: levný efekt / vtip)
7. výstup sRGB (u exportu volitelně Display P3 tam, kde to prohlížeč umí)
- Výkon: hledáček v nižším rozlišení (např. 1080 px kratší strana), editace náhled ~2048 px, export plné rozlišení po dlaždicích (bez vytuhnutí telefonu).

## Filmy (zdroj: `andreavolpato/spektrafilm`, `src/spektrafilm/data/profiles`)
- Profily: Kodak Portra 160/400/800 (+push1/2), Ektar 100, Gold 200, UltraMax 400, Kodachrome 64, Ektachrome 100, Verita 200D,
  Vision3 50D/250D/200T/500T, tiskové 2383/2393, Endura…; Fujifilm C200, Pro 400H, Superia X-tra 400, Provia 100F, Velvia 100, Crystal Archive.
- Pečení: `spektrafilm_lut_creator` (`spektrafilm-lut build`, umí `.cube` i `hald_png`). Vstup **sRGB**, výstup sRGB, grid 33³ (ověřit banding; případně 65³ nebo uložit 16bit/Float16 místo 8bit Hald).
- V UI vysvětlit čísla: číslo v kódu = ISO (citlivost); typ česky (barevný negativ / diapozitiv / kinofilm) místo C-41/E-6.
- Kódy v UI vlastní, krátké, ve stylu inspo (např. `P400` „portrait 400“, `G200` „gold 200“, `KC64`, `V3-500T` „cine 500T“, `VEL` …) + drobný podtitul.
  Karusel: ikona kazety/foťáku pro každý film.
- Advanced: parametry filmu, které spektrafilm umí měnit (expozice negativu, push/pull, tisková expozice, filtrace tisku) → pro ty se buď peče víc variant LUT, nebo se aproximují.

## Kamera
- `getUserMedia`, živý náhled přes engine s vybraným filmem, zrno se hýbe. Zoom: pinch + tlačítka 0,5×/1×/2× (constraint `zoom` kde jde, jinak digitální ořez).
- **iPhone (Safari/PWA) nedovolí ručně ISO ani čas závěrky** – expozici řídí telefon sám. Proto:
  - kolečko **EV** = korekce expozice v enginu (náhled ukazuje přesně výsledek → živé focení to nekazí),
  - kolečko **ISO** = „citlivost filmu“ → velikost/síla zrna a lehce kontrast (jako výběr filmu ISO),
  - kolečko **čas** = délka **slow shutter** (1/4 s … 2 s) – krátké časy = normální snímek.
  - Na Androidu v Chrome, pokud zařízení hlásí `exposureMode/exposureTime/iso/exposureCompensation` v `getCapabilities()`, použít skutečné hodnoty (ověřit na zařízení).
- Zachycení: Android `ImageCapture.takePhoto()` (plné rozlišení), iOS = snímek ze streamu v max rozlišení (požádat o 4K constraints) – ověřit kvalitu.
- **Slow shutter**: nasbírat N snímků ze streamu do float framebufferu. Režimy: **Světelné stopy** (maximum/lighten), **Rozmazání pohybu** (průměr), **Voda/hedvábí** (průměr + ostřejší statické části). Doporučit stabilní držení / opřít; ukazovat průběh.
- **Long exposure** až 15 s (kolečko času: ¼, ½, 1, 2, 4, 8, 15 s): snímky se sčítají ve float přesnosti (průměr / maximum), hedvábí vrací ostrost statickým částem podle rozptylu. Do budoucna zarovnání snímků (stabilizace) a odšumění.
- **Formát**: 35 mm (2:3), **Half-frame** (dva snímky 3:4 vedle sebe na jedno políčko), 6×6, 6×7 – maska v hledáčku, ořez při focení.
- Ovládání (LCD + kolečka) jde **schovat** úchytem nad displejem → velký hledáček; EV jde měnit tažením prstem nahoru/dolů v hledáčku.
- **Jednorázovka**: start z galerie (+) → výběr filmu → 27 snímků, film zamčený, počítadlo v čipu, fotky schované do role; „vyvolání“ s animací (z hnědé mlhy do barev).
- Přepnutí objektivu/kamery: drží poslední snímek + rozmazání, žádné probliknutí.
- Další: mřížka třetin (zlatý řez a spirálu Honza zamítl – vypadalo to divně), samospoušť (**3 s → 10 s**), přepnutí kamery, blesk = svítilna kde jde (přední kamera = rozsvícený displej), haptika (Android `vibrate`, iOS nemá).
- **Režim DEMO** (generovaná noční ulice s auty) zůstává – Honzovi se ten vzhled líbí; přepínač DEMO/ŽIVĚ v hledáčku. O appce ukazuje, co kamera zařízení umí (zoom, svítilna, ruční ISO/čas…).

## Editor
- **Jednoduchý režim** (mobil, Prequel): fotka přes celou plochu, dole karusel filmů s živými náhledy, pod tím pravítko (Síla filmu, Expozice, Teplota, Saturace, Grain, Halation, Bloom…). **Podržením prstu na fotce = před/po.** Tlačítko celá obrazovka, **reset úprav na výchozí film**, panel má pevnou výšku (fotka při přepínání záložek neposkakuje).
- **Advanced**: tónová křivka (RGB + kanály), HSL po barvách, color grading (stíny/střed/světla), ostrost, šum, vinětace, light leaky, prach, okraje, datumovka, parametry filmu, histogram.
- **Ořez**: poměry (orig, 1:1, 4:5, 3:2, 16:9, 9:16), rotace/narovnání, **pinch zoom a posun** (jediné místo spolu s kamerou, kde gesta zoomu fungují).
- **Depth efekty** (jen v editu): Depth Anything V2 Small přes transformers.js (`onnx-community/depth-anything-v2-small`, WebGPU → záložně WASM), lazy load. Efekty: rozmazání pozadí s volbou bodu ostření (bokeh), **mlha do hloubky**, **3D paralaxa** fotky při naklánění telefonu (DeviceOrientation, na iOS žádost o povolení), náhled hloubkové mapy.
- **Blob výřez**: popisky na kartě jdou přepsat (výchozí vlevo čas pořízení, vpravo datum), paleta má **+** pro vlastní barvu. Vybrat tvar (sada organických blobů jako v inspo + vlastní generátor), posunout/zvětšit fotku uvnitř, pozadí z **palety vytažené z fotky** (k-means; před úpravou i po filmu), papírová textura s mřížkou volitelně. Export jako sdílecí karta.
- **Bez nápovědných textů typu „podrž fotku“** – Honza je považuje za nevkusné, gesta mají být samozřejmá.
- Galerie: **podržení fotky** (na PC pravé tlačítko) → nabídka Upravit / Blob karta / Silueta pro dvojexpozici / **Smazat** (s „Vrátit“). Import vlastních fotek přes + v galerii.
- **Dvojexpozice** (v Blob kartě): tvar = silueta z první fotky, uvnitř druhá fotka, kolem barva z palety (vzor: plakát s postavou plnou oken na červené). V náhledu silueta prahem jasu, v appce **segmentace postavy** (MediaPipe Selfie/Image Segmenter, Apache-2.0) nebo hloubková mapa. Do budoucna i **video** (pohybující se silueta s jiným záběrem uvnitř).
- **Kontaktní arch** z role / galerie: pruhy 35 mm s perforací, čísly políček, kroužek a fajfka fixou.
- Reference: vlastní fotka (nahrát) nebo z galerie.
- PC (široká obrazovka): Lightroom rozložení – vlevo filmy/presety, vpravo panely úprav, dole filmový pás, klávesové zkratky (`\` před/po, `C` ořez, `Ctrl+Z` atd.).
- Historie kroků (undo/redo), kopírovat/vložit úpravy mezi fotkami.

## Reference match (vlastní náhrada deep-analog)
- Uživatel vloží **referenci** (fotku, která se mu líbí) → tvoje fotka dostane její barevnost/tóny, volitelně + vybraný film navrch.
- Metody (veřejné, bez patentů deep-analogu): **Reinhard** (průměr/odchylka v Lab), **Pitié IDT** (iterativní přenos rozdělení barev) + **regrain** – port z `python-color-transfer` (MIT); plus párování tónové křivky podle histogramu jasu. Síla přenosu 0–100 %.
- Výsledná transformace se **napasuje do 3D LUT** (projetím identity gridu) → okamžité použití i na další fotky = vlastní uložený „film“.
- Export: **`.cube`** (DaVinci, Premiere, Photoshop, Lightroom přes profily), **JSON preset** (vlastní formát Qamery – parametry + odkaz na LUT), **Adobe XMP** (preset se základními posuvníky; profil s vloženou LUT tabulkou `crs:RGBTable` = ověřit formát, jinak doporučit .cube). Exporty filmů nesou atribuci CC BY-SA (viz Licence).
- Do budoucna lze přidat vlastní malou síť trénovanou na otevřených datech – ale až když jednoduché metody nebudou stačit.

## Galerie a role
- Tmavá galerie podle inspo: nahoře role (skleněné karty), masonry, plovoucí vyhledávání dole (hledá podle filmu, data, barvy).
- **Role = alba podle filmu / akce.** **Jednorázovka**: role 27 snímků s pevně zvoleným filmem, fotky se „vyvolají“ až později (za hodinu / ráno) – s animací vyvolávání.
- Sdílení přes Web Share API (soubor), uložení do galerie telefonu.

## Design a motion
- **Názvy efektů anglicky**: Halation, Grain, Bloom, Vignette, Fade (zbytek UI česky: Expozice, Teplota, Kontrast…).
- **Žádné poskakování layoutu**: měnící se texty (hodnoty, režimy, pilulky) mají pevnou šířku / tabular-nums, nic se nesmí posouvat při změně textu.
- Vodorovné pásy jdou na PC posouvat kolečkem myši i tažením; vlastní tenké scrollbary (ne výchozí z Windows). Spodní panely jdou zavřít stažením za úchyt.
- Tmavé UI, akcent **žlutá/oranžová** (displej z inspo), pixelové ikony 24 px (vlastní SVG na mřížce), aktivní ikona žlutá se září.
- Fonty: Geist, Geist Mono, Doto (Google Fonts) + segmentový/pixelový styl čísel na „LCD“.
- **Expensive motion**: pružinové přechody (vlastní spring funkce, ne lineární ease), sdílené přechody prvků (fotka z galerie plynule do editoru), kolečka s setrvačností a „cvaknutím“ na hodnotách, karusel filmů s 3D natočením, zrno a halace živě. Úvodní animace s maskotem (jako Mraq intro). Respektovat úsporné animace v nastavení (ne systémové „omezit pohyb“ – Honza to tak chce i u Mraqu).
- **Maskot**: tečkované robotí oči (jako Mraq/Klapqa), např. oči v objektivu/kazetě; reaguje na focení (mrknutí = spoušť), nálady.
- **Intro** (canvas, ~2,7 s, virtuální čas – zaseknutí vlákna ho jen pozdrží): objektiv s rytinou a reflexy povlaků → oči se tečka po tečce probudí, rozhlédnou, mrknou → tečkový nápis QAMERA (bez podtitulu) → zavře se 7lamelová clona (cvak) → průlet čočkou, appka se vynoří otevřenou clonou. Ťuknutí = přeskočit.
- **Zákaz zoomu stránky**: viewport `maximum-scale=1, user-scalable=no`, na iOS navíc blokovat `gesturestart`/`gesturechange` a double-tap zoom (`touch-action: manipulation`) – **kromě** plochy ořezu a hledáčku (`touch-action: none` + vlastní pinch).
- iOS PWA: černý start bez bílého bliknutí (stejný trik jako Mraq: `apple-touch-startup-image`, černé `html`, kryt do načtení).

## Plán (fáze)
1. **HTML náhled** (klikací, mobil 390×844 + PC): kamera s koly, karusel filmů, jednoduchý editor, advanced panel, galerie, blob karta, intro s maskotem. Screenshoty do `docs/screens/`. Schválí Honza.
2. Engine WebGL2 + pečení LUT (`tools/bake_luts.py`, GitHub Actions) + 6–8 hlavních filmů.
3. Editor jednoduchý + ořez + export + IndexedDB.
4. Kamera + slow shutter + kolečka.
5. Reference match + exporty .cube/JSON/XMP.
6. Advanced, PC rozložení.
7. Depth efekty, blob karty, galerie/role, jednorázovka, datumovka, okraje.
8. Poděkování/licence obrazovka, PWA, ladění výkonu na iPhonu i Androidu.

## Nápady do budoucna
- Kontaktní arch (contact sheet) z role jako exportovaný obrázek.
- „Expired film“ režim: náhodný posun barev, úniky světla podle data expirace.
- Simulace dvojexpozice (dva snímky do jednoho políčka).
- Polaroid / instax rámečky s „vyvoláváním“ (spektrafilm GUI má polaroid animaci – inspirace).
- Push notifikace „tvoje role je vyvolaná“ (jako Mraq přes Cloudflare Worker).
- Video s filmovým vzhledem (stejný shader na `<video>`), krátké klipy.

## Testování
- Playwright, viewport 390×844 (mobil) a 1440×900 (PC); kamera v testech přes podvržený stream (`--use-fake-device-for-media-stream`, vlastní video).
- Reálné testy na telefonu přes preview URL větve `dev` (kamera vyžaduje HTTPS).
- Ověřovat výkon (fps hledáčku) na iPhonu i Androidu.
