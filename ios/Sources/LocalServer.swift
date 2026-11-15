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

    // Po uspání iOS socket naslouchání potichu zruší (stav zůstane .ready, nové spojení ale neprojde) → vždy nový listener
    func restart() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.queue.asyncAfter(deadline: .now() + 0.1) { if self.listener == nil { self.listen() } }
        }
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
            switch st {
            case .failed, .waiting:
                self?.queue.asyncAfter(deadline: .now() + 0.3) { self?.ensureRunning() }
            default: break
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
                self.respond(c, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self), rest: Data(buf[end.upperBound...]))
            } else if done || err != nil || buf.count > 65536 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String, rest: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return send(c, status: "400 Bad Request", type: "text/plain", body: Data()) }
        let method = String(parts[0])
        var path = String(parts[1])
        var query: [String: String] = [:]
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            for kv in path[path.index(after: q)...].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if p.count == 2 { query[p[0]] = p[1] }
            }
            path = String(path[..<q])
        }
        path = path.removingPercentEncoding ?? path
        var hdr: [String: String] = [:]
        for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { hdr[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }

        // /__st/… = galerie appky (GalleryStore): seznam, záznamy, data fotek a klipů
        if path.hasPrefix("/__st/") {
            let len = Int(hdr["content-length"] ?? "") ?? 0
            if method == "PUT" || method == "POST" {
                guard len >= 0, len < 4_000_000_000 else { return send(c, status: "413 Payload Too Large", type: "text/plain", body: Data()) }
                return readBody(c, have: rest, total: len) { body in self.store(c, method: method, path: path, query: query, hdr: hdr, body: body) }
            }
            return store(c, method: method, path: path, query: query, hdr: hdr, body: nil)
        }
        if path.hasSuffix("/") { path += "index.html" }

        // /__live = snímky hledáčku z CameraEngine (otevřené spojení, snímek za snímkem: u32 délka · u16 délka meta · meta JSON · JPEG)
        if path == "/__live" { return live(c) }
        // /__cap/… = čerstvé DNG z nativní spouště (RawCapture)
        var base = root
        if path.hasPrefix("/__cap/") {
            base = RawCapture.dir.standardizedFileURL
            path = String(path.dropFirst("/__cap".count))
        }
        var url = base.appendingPathComponent(String(path.drop(while: { $0 == "/" }))).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            url.appendPathComponent("index.html")
        }
        // Nic mimo povolenou složku
        guard url.path.hasPrefix(base.path), let body = try? Data(contentsOf: url) else {
            return send(c, status: "404 Not Found", type: "text/plain", body: Data("404".utf8))
        }
        send(c, status: "200 OK", type: Self.mime(url.pathExtension), body: method == "HEAD" ? Data() : body, length: body.count)
    }

    // MARK: galerie appky
    private func store(_ c: NWConnection, method: String, path: String, query: [String: String], hdr: [String: String], body: URL?) {
        defer { if let body { try? FileManager.default.removeItem(at: body) } }
        let rest = String(path.dropFirst("/__st/".count))
        let json = { (o: Any) -> Data in (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8) }
        if rest == "list" { return send(c, status: "200 OK", type: "application/json", body: GalleryStore.list()) }
        if rest == "info" { let s = GalleryStore.summary(); return send(c, status: "200 OK", type: "application/json", body: json(["n": s.n, "bytes": s.bytes])) }
        if rest.hasPrefix("rec/"), method == "PUT", let body {
            let ok = GalleryStore.putRecord(String(rest.dropFirst(4)), body: body)
            return send(c, status: ok ? "200 OK" : "400 Bad Request", type: "application/json", body: json(["ok": ok]))
        }
        if rest.hasPrefix("f/") {
            let name = String(rest.dropFirst(2))
            if method == "PUT", let body {
                guard let n = GalleryStore.putFile(name, body: body) else { return send(c, status: "400 Bad Request", type: "application/json", body: json(["ok": false])) }
                return send(c, status: "200 OK", type: "application/json", body: json(["ok": true, "n": n]))
            }
            guard let u = GalleryStore.file(name), FileManager.default.fileExists(atPath: u.path) else { return send(c, status: "404 Not Found", type: "text/plain", body: Data("404".utf8)) }
            return sendFile(c, url: u, range: hdr["range"], head: method == "HEAD")
        }
        if rest == "adopt", method == "POST" {
            guard let from = query["from"], let to = query["to"], let n = GalleryStore.adopt(from: from, to: to) else { return send(c, status: "404 Not Found", type: "application/json", body: json(["ok": false])) }
            return send(c, status: "200 OK", type: "application/json", body: json(["ok": true, "n": n]))
        }
        if rest.hasPrefix("del/"), method == "DELETE" || method == "POST" {
            GalleryStore.remove(String(rest.dropFirst(4)))
            return send(c, status: "200 OK", type: "application/json", body: json(["ok": true]))
        }
        send(c, status: "400 Bad Request", type: "text/plain", body: Data())
    }

    /// tělo požadavku rovnou do dočasného souboru (klip může mít stovky MB)
    private func readBody(_ c: NWConnection, have: Data, total: Int, done: @escaping (URL?) -> Void) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st-up-" + UUID().uuidString)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: tmp) else { return done(nil) }
        var got = 0
        func put(_ d: Data) { let n = min(d.count, total - got); if n > 0 { fh.write(d.prefix(n)); got += n } }
        put(have)
        func step() {
            if got >= total { try? fh.close(); return done(tmp) }
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, fin, err in
                if let data { put(data) }
                if got >= total { try? fh.close(); return done(tmp) }
                if fin || err != nil { try? fh.close(); try? FileManager.default.removeItem(at: tmp); c.cancel(); return }
                step()
            }
        }
        step()
    }

    /// soubor po kouscích (1 MB) a s Range – přehrávání videa ve WebKitu chce 206 Partial Content
    private func sendFile(_ c: NWConnection, url: URL, range: String?, head: Bool) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return send(c, status: "404 Not Found", type: "text/plain", body: Data("404".utf8)) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        var a = 0, b = size - 1, partial = false
        if let r = range, r.hasPrefix("bytes="), size > 0 {
            let s = r.dropFirst(6).split(separator: ",").first.map { $0.split(separator: "-", omittingEmptySubsequences: false) } ?? []
            if s.count == 2 {
                if let x = Int(s[0].trimmingCharacters(in: .whitespaces)) { a = x; if let y = Int(s[1].trimmingCharacters(in: .whitespaces)) { b = min(y, size - 1) } }
                else if let y = Int(s[1].trimmingCharacters(in: .whitespaces)) { a = max(0, size - y) }
                partial = true
            }
        }
        if partial && (a > b || a >= size) {
            try? fh.close()
            let h = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            return c.send(content: Data(h.utf8), completion: .contentProcessed { _ in c.cancel() })
        }
        let len = max(0, b - a + 1)
        var h = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(Self.mime(url.pathExtension))\r\nContent-Length: \(len)\r\nAccept-Ranges: bytes\r\n"
        if partial { h += "Content-Range: bytes \(a)-\(b)/\(size)\r\n" }
        h += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        try? fh.seek(toOffset: UInt64(a))
        var left = head ? 0 : len
        func pump() {
            if left <= 0 { try? fh.close(); c.cancel(); return }
            let d = fh.readData(ofLength: min(left, 1 << 20))
            if d.isEmpty { try? fh.close(); c.cancel(); return }
            left -= d.count
            c.send(content: d, completion: .contentProcessed { [weak self] err in
                if err != nil { try? fh.close(); c.cancel() } else { self?.queue.async { pump() } } })
        }
        c.send(content: Data(h.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { try? fh.close(); c.cancel() } else { self?.queue.async { pump() } } })
    }

    // MARK: hledáček – jeden posluchač (nový nahradí starý), posílá se vždy jen nejnovější snímek, dokud předchozí neodešel
    private var liveConn: NWConnection?
    private var liveBusy = false
    private func live(_ c: NWConnection) {
        liveConn?.cancel()
        liveConn = c; liveBusy = true
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            self?.queue.async { guard let self, self.liveConn === c else { return }; if err != nil { self.liveConn = nil }; self.liveBusy = false } })
        c.stateUpdateHandler = { [weak self] st in
            switch st { case .failed, .cancelled: self?.queue.async { if self?.liveConn === c { self?.liveConn = nil } } default: break }
        }
    }
    var liveReady: Bool { queue.sync { liveConn != nil && !liveBusy } }
    func pushFrame(_ d: Data) {
        queue.async {
            guard let c = self.liveConn, !self.liveBusy else { return }
            self.liveBusy = true
            c.send(content: d, completion: .contentProcessed { [weak self] err in
                self?.queue.async { guard let self else { return }; if err != nil, self.liveConn === c { self.liveConn = nil; c.cancel() }; self.liveBusy = false } })
        }
    }
    func liveClose() { queue.async { self.liveConn?.cancel(); self.liveConn = nil; self.liveBusy = false } }

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
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "txt", "cube": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
