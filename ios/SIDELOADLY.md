# Qamera DEV na iPhonu přes Sideloadly

## Jednou na začátku
1. **iTunes pro Windows** z webu Applu (ne z Microsoft Storu – Sideloadly potřebuje ovladač pro iPhone).
2. **Sideloadly** z https://sideloadly.io (Windows verze).
3. **Vedlejší Apple ID** (ne hlavní) – jen na podepisování, se zapnutým dvoufázovým ověřením.
4. iPhone kabelem do PC, odemknout, „Důvěřovat tomuto počítači“.

## Nová verze appky
1. GitHub → repo `qamera` → **Actions** → poslední běh **iOS build** (zelený) → dole **Artifacts** → `Qamera-DEV-ipa` (stáhne se zip, v něm `Qamera-DEV.ipa`).
2. Sideloadly: přetáhnout `.ipa`, vybrat iPhone, zadat vedlejší Apple ID, **Start**.
3. První instalace: v iPhonu **Nastavení → Obecné → Správa VPN a zařízení** → e-mail vedlejšího Apple ID → **Důvěřovat**.
4. Na iOS 16+ je potřeba **Režim vývojáře**: Nastavení → Soukromí a zabezpečení → Režim vývojáře → zapnout (restart).

## Obnova po 7 dnech
- Sideloadly umí **automatickou obnovu přes Wi-Fi** (v Sideloadly zapnout Wi-Fi sync pro iPhone a u appky auto-refresh; PC musí běžet a iPhone být ve stejné síti).
- Data appky (fotky v appce, nastavení) obnova nemaže, dokud se nemění identifikátor appky.
