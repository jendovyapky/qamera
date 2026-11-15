import AVKit
import Photos
import SwiftUI
import UIKit
import WebKit

// Webová Qamera zabalená v appce (soubory z balíčku přes LocalServer, bez internetu a bez jendovyapky.eu).
// Most JS → Swift: navigator.share (soubory → nabídka sdílení / Uložit do Fotek), navigator.vibrate (haptika).
struct WebAppView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebAppController { WebAppController() }
    func updateUIViewController(_ vc: WebAppController, context: Context) {}
}

final class WebAppController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var web: WKWebView!
    private var server: LocalServer?
    private let thump = UIImpactFeedbackGenerator(style: .light)
    private let raw = RawCapture()
    private let clip = ClipCapture()
    private var vol: VolumeShutter?
    private var camWasOn = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.047, green: 0.043, blue: 0.039, alpha: 1)

        if let webRoot = Bundle.main.resourceURL?.appendingPathComponent("Web") {
            let s = LocalServer(root: webRoot)
            s.start()
            server = s
            // vlastní kamera appky: snímky hledáčku jdou rovnou do /__live
            let cam = CameraEngine.shared
            cam.onFrame = { [weak s] d in s?.pushFrame(d) }
            cam.canSend = { [weak s] in s?.liveReady ?? false }
        }

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()
        let ucc = WKUserContentController()
        ucc.add(self, name: "qamera")
        ucc.addUserScript(WKUserScript(source: "window.__qLens = " + RawCapture.lensJSON() + ";", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if CameraEngine.crashedBefore() {
            ucc.addUserScript(WKUserScript(source: "window.__qNcamOff = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        ucc.addUserScript(WKUserScript(source: Self.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc

        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.isOpaque = false
        web.backgroundColor = view.backgroundColor
        web.scrollView.backgroundColor = view.backgroundColor
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.uiDelegate = self
        web.navigationDelegate = self
        #if DEBUG
        web.isInspectable = true
        #endif
        view.addSubview(web)

        // Boční tlačítko Ovládání fotoaparátu a tlačítka hlasitosti = spoušť (iOS je pošle, jen když běží kamera)
        if #available(iOS 17.2, *) {
            let shutter = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.js("window.__qShutter && window.__qShutter()") }
            }
            view.addInteraction(shutter)
        }

        // Tlačítka hlasitosti = spoušť i s kamerou ve WebKitu (boční Ovládání fotoaparátu jen s vlastní kamerou appky)
        vol = VolumeShutter(host: view) { [weak self] in self?.js("window.__qShutter && window.__qShutter()") }
        NotificationCenter.default.addObserver(self, selector: #selector(background),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        // Server se rozjede za pár ms; načtení se při chybě zopakuje (didFail)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.load() }
    }

    private func load() {
        web.load(URLRequest(url: LocalServer.baseURL.appendingPathComponent("docs/preview/")))
    }

    @objc private func foreground() {
        Ladeni.log("návrat do popředí")
        server?.restart()
        camWasOn = false
        js("window.__qCamResume && window.__qCamResume()")
        vol?.resume()
    }

    @objc private func background() {
        Ladeni.log("do pozadí, kamera běžela=\(CameraEngine.shared.isOn)")
        vol?.pause()
        if CameraEngine.shared.isOn { CameraEngine.shared.stop(); camWasOn = true }
        server?.liveClose()
    }

    // Kamera ve webu: povolit bez dalšího dotazu (systémový dotaz na kameru iOS ukáže sám)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == "127.0.0.1" ? .grant : .deny)
    }

    // Odkazy ven (O appce, licence) do Safari
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let host = url.host, host != "127.0.0.1",
           url.scheme == "http" || url.scheme == "https", action.targetFrame?.isMainFrame ?? true,
           action.navigationType == .linkActivated || action.targetFrame == nil {
            UIApplication.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        server?.ensureRunning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.load() }
    }

    // Webový obsah spadl (paměť) → načíst znovu
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        server?.ensureRunning()
        load()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Zrušit", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    // Zprávy z JS
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let kind = m["kind"] as? String else { return }
        if kind == "log" { Ladeni.log("web: " + ((m["t"] as? String) ?? "")); return }
        if kind != "vibrate", !(kind == "ncam" && ["ctl", "zoom", "focus"].contains((m["op"] as? String) ?? "")) {
            let skip: Set<String> = ["kind", "op", "films", "files", "data", "datas", "items", "lut", "ids"]
            let args: [String] = m.filter { !skip.contains($0.key) }.map { $0.key + "=" + String(describing: $0.value) }.sorted()
            Ladeni.log("most " + kind + " " + ((m["op"] as? String) ?? "") + " " + String(args.joined(separator: " ").prefix(300)))
        }
        switch kind {
        case "vibrate":
            thump.impactOccurred(intensity: min(1, max(0.3, CGFloat((m["ms"] as? Double) ?? 6) / 20)))
        case "share":
            share(m)
        case "ncam": // vlastní kamera appky (CameraEngine): start / stop / zoom / torch / focus
            let op = m["op"] as? String ?? ""
            let cam = CameraEngine.shared
            switch op {
            case "start":
                let id = m["id"] as? Int ?? 0
                cam.start(lens: (m["lens"] as? String) ?? "wide", zoom: (m["zoom"] as? Double) ?? 1) { [weak self] r in
                    DispatchQueue.main.async {
                        switch r {
                        case .success(let o):
                            let json = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                            self?.js("window.__qCam && window.__qCam(\(id), true, \(json))")
                        case .failure(let e):
                        Ladeni.log("CHYBA \(kind): \(e.localizedDescription)")
                            self?.js("window.__qCam && window.__qCam(\(id), false, \(Self.jsStr(e.localizedDescription)))")
                        }
                    }
                }
            case "ctl":
                cam.onCtl = { [weak self] k, v in DispatchQueue.main.async { self?.js("window.__qCtl && window.__qCtl('\(k)', \(v))") } }
                cam.setCtl(films: m["films"] as? [String], film: m["film"] as? Int, ev: m["ev"] as? Double)
            case "stop": cam.stop(); server?.liveClose()
            case "zoom": cam.setZoom((m["z"] as? Double) ?? 1)
            case "torch": cam.torch((m["on"] as? Bool) ?? false)
            case "focus": cam.focus(x: (m["x"] as? Double) ?? 0.5, y: (m["y"] as? Double) ?? 0.5)
            default: break
            }
        case "still": // fotka bez RAW z běžící kamery appky (log → jako vyvolaný RAW), hledáček se nezastaví
            let id = m["id"] as? Int ?? 0
            CameraEngine.shared.still { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r):
                        var o: [String: Any] = ["label": r.label, "lensZoom": r.lensZoom, "ev": r.ev]
                        for (k, f) in r.files { o[k] = "/__cap/" + f }
                        let json = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        self?.js("window.__qRaw && window.__qRaw(\(id), true, \(json))")
                    case .failure(let e):
                        Ladeni.log("CHYBA \(kind): \(e.localizedDescription)")
                        self?.js("window.__qRaw && window.__qRaw(\(id), false, \(Self.jsStr(e.localizedDescription)))")
                    }
                }
            }
        case "raw":
            // RAW bez úprav = jeden snímek bez skládání: v tmě (vysoké ISO hledáčku) by byl jen šum → automaticky ProRAW (skládaný z víc snímků)
            let isoNow = CameraEngine.shared.currentISO
            CameraEngine.shared.stop() // RAW si zatím otevírá vlastní session (krok 2: ze stejné)
            let id = m["id"] as? Int ?? 0
            let bayer = ((m["bayer"] as? Bool) ?? false) && !(isoNow > 320)
            raw.capture(zoom: (m["zoom"] as? Double) ?? 1, ultra: (m["ultra"] as? Bool) ?? false,
                        flash: (m["flash"] as? Bool) ?? false, tele: (m["tele"] as? Bool) ?? false, bayer: bayer, mean: m["mean"] as? Double) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r):
                        var o: [String: Any] = ["label": r.label, "lensZoom": r.lensZoom, "ev": r.ev]
                        for (k, f) in r.files { o[k] = "/__cap/" + f }
                        let json = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        self?.js("window.__qRaw && window.__qRaw(\(id), true, \(json))")
                    case .failure(let e):
                        Ladeni.log("CHYBA \(kind): \(e.localizedDescription)")
                        self?.js("window.__qRaw && window.__qRaw(\(id), false, \(Self.jsStr(e.localizedDescription)))")
                    }
                }
            }
        case "clip":
            let id = m["id"] as? Int ?? 0
            var o = ClipCapture.Opts()
            o.seconds = min(10, max(1, (m["sec"] as? Double) ?? 5))
            o.zoom = (m["zoom"] as? Double) ?? 1
            o.ultra = (m["ultra"] as? Bool) ?? false
            o.tele = (m["tele"] as? Bool) ?? false
            o.film = (m["film"] as? String) ?? "NONE"
            o.str = (m["str"] as? Double) ?? 1
            o.grain = (m["grain"] as? Double) ?? 0.5
            o.hal = (m["hal"] as? Double) ?? 0.5
            o.apl = (m["apl"] as? Double) ?? 0.5
            o.vig = (m["vig"] as? Double) ?? 0
            o.ev = (m["ev"] as? Double) ?? 0
            o.con = (m["con"] as? Double) ?? 0
            o.sat = (m["sat"] as? Double) ?? 0
            o.gn = (m["gn"] as? Double) ?? 4250
            o.bloom = (m["bloom"] as? Double) ?? 0
            o.glow = (m["glow"] as? Double) ?? 0
            if let s = m["lut"] as? String, let c = s.range(of: ",") { o.lut = Data(base64Encoded: String(s[c.upperBound...])) }
            let opts = o
            let recording: () -> Void = { [weak self] in
                DispatchQueue.main.async { self?.js("window.__qClipRec && window.__qClipRec(\(id))") }
            }
            let progress: (Double) -> Void = { [weak self] p in
                DispatchQueue.main.async { self?.js("window.__qClipProg && window.__qClipProg(\(id), \(p))") }
            }
            let finish: (Swift.Result<ClipCapture.Result, Error>, Bool) -> Void = { [weak self] result, same in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r):
                        var o: [String: Any] = ["mp4": "/__cap/" + r.mp4, "jpg": "/__cap/" + r.jpg, "log": r.log, "lensZoom": r.lensZoom, "same": same]
                        if !r.src.isEmpty { o["src"] = r.src }
                        if !r.sjpg.isEmpty { o["sjpg"] = "/__cap/" + r.sjpg }
                        let json = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        self?.js("window.__qClip && window.__qClip(\(id), true, \(json))")
                    case .failure(let e):
                        Ladeni.log("CHYBA \(kind): \(e.localizedDescription)")
                        self?.js("window.__qClip && window.__qClip(\(id), false, \(Self.jsStr(e.localizedDescription)))")
                    }
                }
            }
            // změna filmu u hotového klipu: znovu vyvolat uložený originál (kamera se nepoužije)
            if let cid = m["src"] as? String {
                let srcURL = ClipStore.url(cid), isLog = (m["log"] as? Bool) ?? true
                Ladeni.log("klip znovu z originálu \(cid.prefix(8)) film=\(opts.film)")
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard FileManager.default.fileExists(atPath: srcURL.path) else { throw QError(message: "originál klipu už v telefonu není") }
                        try? FileManager.default.createDirectory(at: RawCapture.dir, withIntermediateDirectories: true)
                        var res = ClipCapture.Result()
                        res.log = isLog
                        res.src = cid
                        let rid = UUID().uuidString
                        try ClipDevelop.process(src: srcURL, dst: RawCapture.dir.appendingPathComponent(rid + ".mp4"), thumb: RawCapture.dir.appendingPathComponent(rid + ".jpg"),
                                                log: isLog, film: opts.film, str: opts.str, grain: opts.grain, hal: opts.hal, vig: opts.vig, apl: opts.apl, ev: opts.ev, con: opts.con, sat: opts.sat, gn: opts.gn, bloom: opts.bloom, glow: opts.glow, webLut: opts.lut, progress: progress)
                        res.mp4 = rid + ".mp4"; res.jpg = rid + ".jpg"
                        finish(.success(res), true)
                    } catch { finish(.failure(error), true) }
                }
                break
            }
            // postaru: kamera appky se zastaví a klip si otevře vlastní session (hledáček po dobu klipu stojí)
            let old: () -> Void = { [weak self] in
                CameraEngine.shared.stop()
                self?.server?.liveClose()
                self?.clip.capture(opts, recording: recording, progress: progress) { r in finish(r, false) }
            }
            // kamera appky běží: klip ze stejné session, hledáček jede dál; když to nejde, postaru
            if (m["same"] as? Bool) == true, CameraEngine.shared.isOn {
                CameraEngine.shared.record(seconds: opts.seconds, started: recording) { rr in
                    switch rr {
                    case .failure:
                        DispatchQueue.main.async { old() }
                    case .success(let v):
                        let (url, log, lz) = v
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                var res = ClipCapture.Result()
                                res.log = log
                                res.lensZoom = lz
                                let cid = UUID().uuidString
                                let sj = RawCapture.dir.appendingPathComponent(cid + "-s.jpg")
                                try ClipDevelop.process(src: url, dst: RawCapture.dir.appendingPathComponent(cid + ".mp4"), thumb: RawCapture.dir.appendingPathComponent(cid + ".jpg"),
                                                        log: log, film: opts.film, str: opts.str, grain: opts.grain, hal: opts.hal, vig: opts.vig, apl: opts.apl, ev: opts.ev, con: opts.con, sat: opts.sat, gn: opts.gn, bloom: opts.bloom, glow: opts.glow, srcThumb: sj, webLut: opts.lut, progress: progress)
                                // originál zůstane (ClipStore) → film jde změnit i později
                                if let kid = ClipStore.keep(url) { res.src = kid; if FileManager.default.fileExists(atPath: sj.path) { res.sjpg = cid + "-s.jpg" } }
                                res.mp4 = cid + ".mp4"; res.jpg = cid + ".jpg"
                                finish(.success(res), true)
                            } catch {
                                try? FileManager.default.removeItem(at: url)
                                finish(.failure(error), true)
                            }
                        }
                    }
                }
            } else { old() }
        case "clipKeep": // úklid osiřelých originálů klipů
            let ids = (m["ids"] as? [String]) ?? []
            DispatchQueue.global(qos: .utility).async { ClipStore.sweep(keep: ids) }
        case "clipDel": // klip smazaný v galerii → smazat i jeho originál
            if let cid = m["src"] as? String { ClipStore.remove(cid) }
        case "cam":
            vol?.set((m["on"] as? Bool) ?? false)
        case "server": // web nedostal soubor ze serveru (Load failed) → nový listener
            server?.restart()
        case "rawDone":
            for f in (m["files"] as? [String]) ?? [] { raw.remove(f) }
        default:
            break
        }
    }

    private func share(_ m: [String: Any]) {
        let id = m["id"] as? Int ?? 0
        // Jen fotky (export) → rovnou do Fotek, bez nabídky sdílení
        let files = (m["files"] as? [[String: Any]]) ?? []
        let photoTypes: Set<String> = ["image/jpeg", "image/png", "image/heic"]
        if !files.isEmpty, m["url"] as? String == nil,
           files.allSatisfy({ photoTypes.contains(($0["type"] as? String) ?? "") }) {
            let datas = files.compactMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
            return saveToPhotos(datas, id: id)
        }
        if files.count == 1, m["url"] as? String == nil, (files[0]["type"] as? String ?? "").hasPrefix("video/"),
           let b64 = files[0]["data"] as? String, let data = Data(base64Encoded: b64) {
            return saveVideoToPhotos(data, name: files[0]["name"] as? String ?? "qamera.mp4", id: id)
        }
        var items: [Any] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in (m["files"] as? [[String: Any]]) ?? [] {
            guard let name = f["name"] as? String, let b64 = f["data"] as? String,
                  let data = Data(base64Encoded: b64) else { continue }
            let type = f["type"] as? String ?? ""
            if type.hasPrefix("image/"), type != "image/svg+xml", let img = UIImage(data: data) {
                // Obrázek jako soubor (zachová EXIF a název) – „Uložit obrázek“ ho dá do Fotek
                let url = dir.appendingPathComponent(name)
                if (try? data.write(to: url)) != nil { items.append(url) } else { items.append(img) }
            } else {
                let url = dir.appendingPathComponent(name)
                if (try? data.write(to: url)) != nil { items.append(url) }
            }
        }
        if let s = m["url"] as? String, let u = URL(string: s) { items.append(u) }
        if items.isEmpty { return finish(id, ok: false, abort: false) }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { [weak self] _, done, _, err in
            try? FileManager.default.removeItem(at: dir)
            self?.finish(id, ok: done, abort: !done && err == nil)
        }
        if let pop = vc.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
        }
        present(vc, animated: true)
    }

    private func saveToPhotos(_ datas: [Data], id: Int) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.finish(id, ok: false, abort: false)
                    self.js("window.toast && toast('Qamera nemá povolené ukládání do Fotek (Nastavení → Qamera)')")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for d in datas { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil) }
            }) { ok, _ in
                DispatchQueue.main.async {
                    if ok { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                    self.finish(id, ok: ok, abort: false)
                    self.js("window.toast && toast(\(Self.jsStr(ok ? (datas.count == 1 ? "Uloženo do Fotek" : "Uloženo do Fotek (\(datas.count))") : "Uložení do Fotek se nepovedlo")))")
                }
            }
        }
    }

    private func saveVideoToPhotos(_ data: Data, name: String, id: Int) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(id)-" + name)
        guard (try? data.write(to: url)) != nil else { return finish(id, ok: false, abort: false) }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    self.finish(id, ok: false, abort: false)
                    self.js("window.toast && toast('Qamera nemá povolené ukládání do Fotek (Nastavení → Qamera)')")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }) { ok, _ in
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    if ok { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                    self.finish(id, ok: ok, abort: false)
                    self.js("window.toast && toast(\(Self.jsStr(ok ? "Klip uložen do Fotek" : "Uložení do Fotek se nepovedlo")))")
                }
            }
        }
    }

    private func finish(_ id: Int, ok: Bool, abort: Bool) {
        js("window.__qShareDone && window.__qShareDone(\(id), \(ok), \(abort))")
    }

    private func js(_ s: String) {
        web.evaluateJavaScript(s, completionHandler: nil)
    }

    // Bezpečný JS řetězec (JSON)
    static func jsStr(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }

    // Shim pro web: sdílení souborů a vibrace přes nativní most
    static let bridgeJS = """
    (() => {
      const post = (m) => window.webkit.messageHandlers.qamera.postMessage(m);
      window.QNATIVE = Object.assign({ raw: 2, bayer: true, clip: 1, crec: 1, cedit: 1, ncam: window.__qNcamOff ? 0 : 1 }, window.__qLens || {});
      navigator.vibrate = (ms) => { post({ kind: 'vibrate', ms: Array.isArray(ms) ? (ms[0] || 6) : (+ms || 6) }); return true; };
      const pend = new Map(); let seq = 0;
      window.__qShareDone = (id, ok, abort) => {
        const p = pend.get(id); if (!p) return; pend.delete(id);
        if (ok) p.res(); else { const e = new Error(abort ? 'Zrušeno' : 'Sdílení se nepovedlo'); e.name = abort ? 'AbortError' : 'Error'; p.rej(e); }
      };
      const b64 = (blob) => new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] || ''); r.onerror = rej; r.readAsDataURL(blob); });
      navigator.canShare = (d) => !!d && ((Array.isArray(d.files) && d.files.length > 0) || !!d.url || !!d.text);
      navigator.share = async (d = {}) => {
        const files = [];
        for (const f of (d.files || [])) files.push({ name: f.name || 'qamera', type: f.type || '', data: await b64(f) });
        const id = ++seq;
        return new Promise((res, rej) => { pend.set(id, { res, rej }); post({ kind: 'share', id, files, url: d.url || null, title: d.title || null }); });
      };
    })();
    """
}
