import Foundation
import Network

// Malý HTTP server jen na 127.0.0.1 uvnitř appky: podává webovou Qameru z balíčku appky.
// http://127.0.0.1 je pro WebKit bezpečný kontext (kamera, IndexedDB, ES moduly, workery fungují),
// pevný port = stálý origin → fotky v IndexedDB přežijí restart i aktualizaci appky.
final class LocalServer {
    static let port: UInt16 = 47213
    static var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    private let root: URL
    private let queue = DispatchQueue(label: "qamera.server")
    private var listener: NWListener?

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func start() {
        queue.async { self.listen() }
    }

    // Po návratu z pozadí může být naslouchání zrušené → znovu
    func ensureRunning() {
        queue.async {
            if let l = self.listener, case .ready = l.state { return }
            self.listener?.cancel()
            self.listener = nil
            self.listen()
        }
    }

    private func listen() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed = st {
                self?.queue.asyncAfter(deadline: .now() + 0.3) { self?.ensureRunning() }
            }
        }
        l.start(queue: queue)
        listener = l
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || err != nil || buf.count > 65536 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) {
        let parts = (head.split(separator: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return send(c, status: "400 Bad Request", type: "text/plain", body: Data()) }
        let method = String(parts[0])
        var path = String(parts[1])
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path
        if path.hasSuffix("/") { path += "index.html" }

        var url = root.appendingPathComponent(String(path.drop(while: { $0 == "/" }))).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            url.appendPathComponent("index.html")
        }
        // Nic mimo složku Web
        guard url.path.hasPrefix(root.path), let body = try? Data(contentsOf: url) else {
            return send(c, status: "404 Not Found", type: "text/plain", body: Data("404".utf8))
        }
        send(c, status: "200 OK", type: Self.mime(url.pathExtension), body: method == "HEAD" ? Data() : body, length: body.count)
    }

    private func send(_ c: NWConnection, status: String, type: String, body: Data, length: Int? = nil) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length ?? body.count)\r\n"
            + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "webmanifest": return "application/manifest+json"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "txt", "cube": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
