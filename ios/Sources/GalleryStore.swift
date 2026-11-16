import Foundation

/* Galerie appky jako soubory v Library/Application Support/Galerie – v Souborech NENÍ vidět (nejde omylem smazat), zálohuje se se zařízením:
   <id>.json = záznam (úpravy, štítky, datum…, místo dat odkazy {__n: jméno souboru}), <id>-<pole>-<náhoda>.<přípona> = data
   (originál, mapa světel, hloubka, hotový klip, první snímek klipu). Web je nahrává přes LocalServer (/__st/…), hotový klip
   z vyvolání se jen přesune (adopt) – nic velkého neputuje přes most ani do paměti webu.
   Úklid: při zápisu záznamu se smažou soubory dané fotky, na které záznam neodkazuje (stará verze klipu po novém vyvolání …). */
enum GalleryStore {
    static let dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Galerie", isDirectory: true)

    /// jen bezpečná jména (bez lomítek a „..“)
    static func safe(_ s: String) -> String? {
        let ok = !s.isEmpty && s.count < 200 && !s.hasPrefix(".") && !s.contains("..")
            && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
        return ok ? s : nil
    }
    static func file(_ name: String) -> URL? { safe(name).map { dir.appendingPathComponent($0) } }
    private static func ensureDir() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    private static func size(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? 0 }

    /// všechny záznamy jako JSON pole
    static func list() -> Data {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        var out = Data("[".utf8), first = true
        for n in names {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(n)), (try? JSONSerialization.jsonObject(with: d)) != nil else { continue }
            if !first { out.append(Data(",".utf8)) }
            out.append(d); first = false
        }
        out.append(Data("]".utf8))
        return out
    }

    /// zápis záznamu (tělo požadavku v dočasném souboru) + úklid souborů, na které už neodkazuje
    static func putRecord(_ id: String, body: URL) -> Bool {
        guard let id = safe(id), let d = try? Data(contentsOf: body), (try? JSONSerialization.jsonObject(with: d)) is [String: Any] else { return false }
        ensureDir()
        let dst = dir.appendingPathComponent(id + ".json")
        do { try d.write(to: dst, options: .atomic) } catch { Ladeni.log("galerie: záznam \(id) se nezapsal: \(error.localizedDescription)"); return false }
        let text = String(decoding: d, as: UTF8.self)
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) where n.hasPrefix(id + "-") && !text.contains("\"" + n + "\"") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
        return true
    }

    /// data (tělo požadavku) → soubor; vrací velikost
    static func putFile(_ name: String, body: URL) -> Int? {
        guard let dst = file(name) else { return nil }
        ensureDir()
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: body, to: dst) } catch { Ladeni.log("galerie: soubor \(name) se nezapsal: \(error.localizedDescription)"); return nil }
        return size(dst)
    }

    /// čerstvý soubor z nativní spouště / vyvolání (tmp/qcap) se jen přesune do galerie
    static func adopt(from: String, to: String) -> Int? {
        guard let f = safe(from), let dst = file(to) else { return nil }
        let src = RawCapture.dir.appendingPathComponent(f)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        ensureDir()
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: src, to: dst) } catch { Ladeni.log("galerie: přesun \(f) se nepovedl: \(error.localizedDescription)"); return nil }
        return size(dst)
    }

    /// smaže záznam i všechna data fotky
    static func remove(_ id: String) {
        guard let id = safe(id) else { return }
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) where n == id + ".json" || n.hasPrefix(id + "-") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    /// počet záznamů a velikost (deník, O appce)
    static func summary() -> (n: Int, bytes: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return (names.filter { $0.hasSuffix(".json") }.count, names.reduce(0) { $0 + size(dir.appendingPathComponent($1)) })
    }
}
