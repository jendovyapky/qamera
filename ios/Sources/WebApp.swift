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

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.047, green: 0.043, blue: 0.039, alpha: 1)

        if let webRoot = Bundle.main.resourceURL?.appendingPathComponent("Web") {
            let s = LocalServer(root: webRoot)
            s.start()
            server = s
        }

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()
        let ucc = WKUserContentController()
        ucc.add(self, name: "qamera")
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

        NotificationCenter.default.addObserver(self, selector: #selector(foreground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        // Server se rozjede za pár ms; načtení se při chybě zopakuje (didFail)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.load() }
    }

    private func load() {
        web.load(URLRequest(url: LocalServer.baseURL.appendingPathComponent("docs/preview/")))
    }

    @objc private func foreground() {
        server?.ensureRunning()
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
        switch kind {
        case "vibrate":
            thump.impactOccurred(intensity: min(1, max(0.3, CGFloat((m["ms"] as? Double) ?? 6) / 20)))
        case "share":
            share(m)
        case "raw":
            let id = m["id"] as? Int ?? 0
            raw.capture(zoom: (m["zoom"] as? Double) ?? 1, ultra: (m["ultra"] as? Bool) ?? false,
                        flash: (m["flash"] as? Bool) ?? false) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let r):
                        self?.js("window.__qRaw && window.__qRaw(\(id), true, \(Self.jsStr("/__cap/" + r.file)), \(Self.jsStr(r.label)), \(r.lensZoom))")
                    case .failure(let e):
                        self?.js("window.__qRaw && window.__qRaw(\(id), false, \(Self.jsStr(e.localizedDescription)))")
                    }
                }
            }
        case "rawDone":
            if let f = m["file"] as? String { raw.remove(f) }
        default:
            break
        }
    }

    private func share(_ m: [String: Any]) {
        let id = m["id"] as? Int ?? 0
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
      window.QNATIVE = { raw: true };
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
