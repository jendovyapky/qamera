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
    static func prune() {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = all.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for u in sorted.dropFirst(12) { try? fm.removeItem(at: u) }
    }
}
