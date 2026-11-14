import Foundation
import Photos

// Ladění (jen Qamera DEV): ke každé fotce se uloží i to, co appka dostala z kamery (DNG ze senzoru / snímek v Apple Logu)
// + parametry vyvolání. Složka je vidět v appce Soubory → Na mém iPhonu → Qamera DEV → Ladeni. Drží se posledních 12 souborů.
// Honza je pošle a stejný postup (raw.js = stejná matematika jako RawDevelop, stejný shader filmu) jde na PC zopakovat a doladit
// na skutečných datech, ne naslepo podle výsledné fotky.
enum Ladeni {
    static let dir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Ladeni", isDirectory: true)
    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
    static func save(_ name: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name))
        prune()
    }
    static func json(_ name: String, _ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { save(name, d) }
    }
    static func url(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    // Originál z kamery i do Fotek (Honza posílá vždy složku z Fotek, do Souborů nechodí). Parametry vyvolání jsou v názvu souboru,
    // protože JSON do Fotek uložit nejde: qamera-raw-<čas>-m<jas hledáčku>-ev<expozice>-<ProRAW|RAW>.dng / qamera-log-<čas>-ev…-iso….tiff
    static func toPhotos(_ file: String, as name: String) {
        let src = dir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = name
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: src, options: o)
            }, completionHandler: nil)
        }
    }
    // Deník appky: co kamera a web dělaly (start kamery, formát, ISO a čas, expozice vyvolání, chyby, návraty z pozadí).
    // Soubor Ladeni/qamera-log.txt (max ~300 kB, starší půlka se zahodí) – Honza ho pošle se složkou Ladeni.
    private static let logQ = DispatchQueue(label: "qamera.log")
    private static let logURL = dir.appendingPathComponent("qamera-log.txt")
    private static let logFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f }()
    private static let build = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + "/" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
    static func log(_ s: String) {
        let t = Date()
        logQ.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = Data("\(logFmt.string(from: t)) [\(build)] \(s.prefix(600))\n".utf8)
            if let sz = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, sz > 300_000, let d = try? Data(contentsOf: logURL) {
                try? d.suffix(150_000).write(to: logURL)
            }
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: logURL) }
        }
    }
    static func prune() {
        let fm = FileManager.default
        guard let all0 = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let all = all0.filter { $0.lastPathComponent != "qamera-log.txt" }
        let sorted = all.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for u in sorted.dropFirst(12) { try? fm.removeItem(at: u) }
    }
}
