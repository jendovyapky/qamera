import AVFoundation
import UIKit

// Nativní RAW ze spouště webové Qamery: web pustí svou kameru (getUserMedia), tady se na chvíli spustí
// AVCaptureSession, vyfotí Apple ProRAW v plném rozlišení (u hlavního objektivu s hloubkou z LiDARu),
// nebo „RAW bez úprav“ = Bayer RAW: jeden snímek přímo ze senzoru, bez skládání a odšumění od Applu (jako Halide Process Zero), a RawDevelop ho vyvolá do JPEG ≤ 4096 px + mapy světel. Soubory si web stáhne
// přes LocalServer (/__cap/…). Když nativní vyvolání selže, pošle se DNG a vyvolá ho raw.js.
final class RawCapture: NSObject {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qcap", isDirectory: true)

    private let queue = DispatchQueue(label: "qamera.raw")
    private var session: AVCaptureSession?
    private var delegate: RawDelegate?

    struct Result {
        var files: [String: String] = [:] // jpg / hl / depth / dng → název souboru
        var label = "RAW"
        var lensZoom = 1.0
        var ev = 0.0
    }

    override init() {
        super.init()
        try? FileManager.default.removeItem(at: Self.dir)
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
    }

    // Teleobjektiv pro tlačítka ve webu: násobek proti hlavnímu (17 Pro = 4) a jestli má 48 Mpx (pak i 2× výřez = 8×)
    static func lensJSON() -> String {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        guard let w = found.first(where: { $0.deviceType == .builtInWideAngleCamera }),
              let t = found.first(where: { $0.deviceType == .builtInTelephotoCamera }) else { return "{}" }
        let fov = { (d: AVCaptureDevice) in tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360) }
        let f = fov(w) / max(fov(t), 0.0001)
        guard f.isFinite, f > 1.5 else { return "{}" }
        let k = f >= 2.5 ? f.rounded() : (f * 2).rounded() / 2 // 4,17 → 4 (Apple to tak značí)
        let big = t.formats.flatMap { $0.supportedMaxPhotoDimensions }.contains { Int($0.width) * Int($0.height) >= 40_000_000 }
        return "{\"tele\":\(k),\"teleCrop\":\(big)}"
    }

    // zoom = optický zoom webového hledáčku (1 = hlavní objektiv), ultra = ultraširokáč, tele = hledáček je na teleobjektivu
    var targetMean: Double?
    func capture(zoom: Double, ultra: Bool, flash: Bool, tele: Bool = false, bayer: Bool = false, mean: Double? = nil, done: @escaping (Swift.Result<Result, Error>) -> Void) {
        queue.async {
            self.targetMean = mean
            // Web právě pustil kameru; WebKit ji uvolní během pár ms
            Thread.sleep(forTimeInterval: 0.15)
            do {
                try self.run(zoom: zoom, ultra: ultra, flash: flash, tele: tele, bayer: bayer, done: done)
            } catch {
                self.stop()
                done(.failure(error))
            }
        }
    }

    private func candidates(zoom: Double, ultra: Bool, tele: Bool, bayer: Bool) -> [(AVCaptureDevice, Double)] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera, .builtInLiDARDepthCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        guard let wide = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return [] }
        let fov = { (d: AVCaptureDevice) in tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360) }
        let factor = { (d: AVCaptureDevice) in fov(wide) / max(fov(d), 0.0001) }
        if ultra, let u = found.first(where: { $0.deviceType == .builtInUltraWideCamera }) { return [(u, factor(u))] }
        if let t = found.first(where: { $0.deviceType == .builtInTelephotoCamera }), tele || zoom >= factor(t) * 0.95 { return [(t, factor(t))] }
        // Hlavní objektiv: nejdřív s LiDARem (hloubka), když tam RAW nejde, tak samotný
        var list: [(AVCaptureDevice, Double)] = []
        if !bayer, let l = found.first(where: { $0.deviceType == .builtInLiDARDepthCamera }) { list.append((l, 1)) } // Bayer zatím bez hloubky (jistota, že kombinaci zařízení vezme)
        list.append((wide, 1))
        return list
    }

    private func configure(_ device: AVCaptureDevice, bayer: Bool) throws -> (AVCaptureSession, AVCapturePhotoOutput, OSType) {
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { s.commitConfiguration(); throw QError(message: "kamera je obsazená") }
        s.addInput(input)
        let out = AVCapturePhotoOutput()
        guard s.canAddOutput(out) else { s.commitConfiguration(); throw QError(message: "nejde fotit") }
        s.addOutput(out)
        if !bayer, out.isAppleProRAWSupported { out.isAppleProRAWEnabled = true }
        if !bayer, out.isDepthDataDeliverySupported { out.isDepthDataDeliveryEnabled = true }
        // ProRAW v plném rozlišení (48 Mpx) – RawDevelop ho zmenší na 4096 px; Bayer RAW jen v nativním rozlišení
        // senzoru po sloučení pixelů (~12 Mpx), větší rozměr s Bayer formátem AVFoundation odmítne výjimkou
        let px = { (d: CMVideoDimensions) in Int(d.width) * Int(d.height) }
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        let pick = bayer ? (dims.filter { px($0) <= 13_000_000 }.max(by: { px($0) < px($1) }) ?? dims.min(by: { px($0) < px($1) }))
                         : dims.max(by: { px($0) < px($1) })
        if let d = pick { out.maxPhotoDimensions = d }
        out.maxPhotoQualityPrioritization = .quality
        s.commitConfiguration()
        let types = out.availableRawPhotoPixelFormatTypes
        let bay = types.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
        guard let fmt = bayer ? bay : (types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? bay) else {
            throw QError(message: bayer ? "tenhle objektiv RAW bez úprav neumí" : "tenhle objektiv RAW neumí")
        }
        return (s, out, fmt)
    }

    private func run(zoom: Double, ultra: Bool, flash: Bool, tele: Bool, bayer: Bool, done: @escaping (Swift.Result<Result, Error>) -> Void) throws {
        var picked: (AVCaptureSession, AVCapturePhotoOutput, OSType, AVCaptureDevice, Double)?
        var lastErr: Error = QError(message: "kamera nenalezena")
        // RAW bez úprav (Bayer); když ho objektiv neumí, záloha ProRAW (s hloubkou), ať RAW vždycky vyfotí
        modes: for mode in bayer ? [true, false] : [false] {
            for (d, z) in candidates(zoom: zoom, ultra: ultra, tele: tele, bayer: mode) {
                do { let (s, o, f) = try configure(d, bayer: mode); picked = (s, o, f, d, z); break modes } catch { lastErr = error }
            }
        }
        guard let p = picked else { throw lastErr }
        let (s, out, fmt, device, lensZoom) = p

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        }
        session = s
        s.startRunning()
        guard s.isRunning else { throw QError(message: "kamera se nespustila") }

        // Počkat, až se usadí expozice a ostření (min 0,35 s, max 1,5 s)
        let t0 = Date()
        Thread.sleep(forTimeInterval: 0.35)
        while (device.isAdjustingExposure || device.isAdjustingFocus) && Date().timeIntervalSince(t0) < 1.5 {
            Thread.sleep(forTimeInterval: 0.05)
        }

        var base = Result()
        base.label = AVCapturePhotoOutput.isAppleProRAWPixelFormat(fmt) ? "ProRAW" : "RAW"
        base.lensZoom = lensZoom
        Ladeni.log("RAW \(base.label) \(device.localizedName) iso=\(Int(device.iso)) čas=1/\(Int((1 / max(device.exposureDuration.seconds, 0.0001)).rounded())) usazení=\(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        let res = base
        let depth = out.isDepthDataDeliveryEnabled
        // Hloubka chodí jen se zpracovanou fotkou → RAW + malé HEIC navíc
        let settings = depth && out.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(rawPixelFormatType: fmt, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings(rawPixelFormatType: fmt)
        settings.maxPhotoDimensions = out.maxPhotoDimensions
        if depth { settings.isDepthDataDeliveryEnabled = true; settings.embedsDepthDataInPhoto = false }
        // Bayer: jeden snímek, žádné skládání (.speed je u RAW vždycky povolené)
        if AVCapturePhotoOutput.isBayerRAWPixelFormat(fmt) { settings.photoQualityPrioritization = .speed }
        if flash, out.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        if let c = out.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }

        let del = RawDelegate { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.stop() // kamera se hned vrátí webu, vyvolání běží mezitím
                switch result {
                case .success(let shot):
                    var res = res
                    let id = UUID().uuidString
                    do {
                        if let dep = shot.depth, let png = RawDevelop.depthPNG(dep, orientation: shot.orientation) {
                            try png.write(to: Self.dir.appendingPathComponent(id + "-d.png")); res.files["depth"] = id + "-d.png"
                        }
                        let st = Ladeni.stamp()
                        Ladeni.save("raw-\(st).dng", shot.raw)
                        do {
                            let o = try RawDevelop.develop(shot.raw, targetMean: self.targetMean, denoise: res.label != "ProRAW")
                            Ladeni.log("RAW vyvoláno \(res.label) ev=\(String(format: "%.2f", Double(o.ev))) cíl=\(String(format: "%.4f", self.targetMean ?? -1)) jpg=\(o.jpg.count / 1024) kB dng=\(shot.raw.count / 1024) kB")
                            Ladeni.json("raw-\(st).json", ["mean": self.targetMean ?? -1, "ev": o.ev, "label": res.label, "lensZoom": res.lensZoom])
                            Ladeni.toPhotos("raw-\(st).dng", as: "qamera-raw-\(st)-m\(String(format: "%.4f", self.targetMean ?? -1))-ev\(String(format: "%.2f", Double(o.ev)))-\(res.label).dng")
                            try o.jpg.write(to: Self.dir.appendingPathComponent(id + ".jpg")); res.files["jpg"] = id + ".jpg"
                            if let hl = o.hl { try hl.write(to: Self.dir.appendingPathComponent(id + "-hl.png")); res.files["hl"] = id + "-hl.png" }
                            res.ev = o.ev
                        } catch {
                            // záloha: DNG vyvolá raw.js ve webu
                            try shot.raw.write(to: Self.dir.appendingPathComponent(id + ".dng")); res.files["dng"] = id + ".dng"
                        }
                        done(.success(res))
                    } catch {
                        done(.failure(error))
                    }
                case .failure(let e):
                    done(.failure(e))
                }
            }
        }
        delegate = del
        out.capturePhoto(with: settings, delegate: del)
    }

    // Běží na queue
    private func stop() {
        session?.stopRunning()
        session = nil
        delegate = nil
    }

    func remove(_ file: String) {
        let name = (file as NSString).lastPathComponent
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(name))
    }
}

final class RawDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    struct Shot {
        let raw: Data
        let depth: AVDepthData?
        let orientation: CGImagePropertyOrientation
    }

    private var raw: Data?
    private var depth: AVDepthData?
    private var orientation = CGImagePropertyOrientation.right
    private let done: (Swift.Result<Shot, Error>) -> Void

    init(done: @escaping (Swift.Result<Shot, Error>) -> Void) {
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else { return }
        if let d = photo.depthData { depth = d }
        if let o = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32, let po = CGImagePropertyOrientation(rawValue: o) {
            orientation = po
        }
        if photo.isRawPhoto { raw = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { return done(.failure(error)) }
        if let raw { done(.success(Shot(raw: raw, depth: depth, orientation: orientation))) } else { done(.failure(QError(message: "prázdný snímek"))) }
    }
}
