import AVFoundation
import CoreImage
import UIKit

// 5s klip z webové spouště (režim KLIP): web pustí svou kameru, appka na chvíli spustí AVCaptureSession,
// natočí klip v Apple Logu (iPhone 15 Pro a novější; jinak běžné video), ClipDevelop na něj nanese film
// (log LUT z luts/log/ = stejný film v2 jako u fotek) a zrno → HEVC .mp4 + náhled .jpg. Soubory si web stáhne
// přes LocalServer (/__cap/…) stejně jako RAW.
final class ClipCapture: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let queue = DispatchQueue(label: "qamera.clip")
    private var session: AVCaptureSession?
    private var finished: ((URL?, Error?) -> Void)?

    struct Opts {
        var seconds = 5.0
        var zoom = 1.0, ultra = false, tele = false
        var film = "NONE", str = 1.0, grain = 0.5, hal = 0.5, vig = 0.0, apl = 0.5
        // z foťáku: korekce expozice (EV), kontrast a sytost (push / pull), počet zrn na delší stranu políčka – stejné hodnoty, jaké má hledáček
        var ev = 0.0, con = 0.0, sat = 0.0, gn = 4250.0
        var bloom = 0.0, glow = 0.0 // záře jako ve fotce (už vynásobené sílou filmu)
    }

    struct Result {
        var mp4 = "", jpg = ""
        var src = "", sjpg = "" // uložený originál klipu (ClipStore) a jeho první snímek jako v hledáčku – pro pozdější změnu filmu
        var log = false
        var lensZoom = 1.0
    }

    // Zařízení: ultraširokáč / tele / hlavní (stejně jako RAW)
    private func device(_ o: Opts) -> (AVCaptureDevice, Double)? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                                                     mediaType: .video, position: .back).devices
        guard let wide = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return nil }
        let fov = { (d: AVCaptureDevice) in tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360) }
        let factor = { (d: AVCaptureDevice) in fov(wide) / max(fov(d), 0.0001) }
        if o.ultra, let u = found.first(where: { $0.deviceType == .builtInUltraWideCamera }) { return (u, factor(u)) }
        if let t = found.first(where: { $0.deviceType == .builtInTelephotoCamera }), o.tele || o.zoom >= factor(t) * 0.95 { return (t, factor(t)) }
        return (wide, 1)
    }

    // Formát: 1080p (nebo nejbližší větší) s Apple Logem a 30 fps; když Apple Log není, běžné 1080p
    private func pickFormat(_ d: AVCaptureDevice) -> (AVCaptureDevice.Format, Bool)? {
        let fps30 = { (f: AVCaptureDevice.Format) in f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 && $0.minFrameRate <= 30.1 } }
        let w = { (f: AVCaptureDevice.Format) in Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).width) }
        let ok = d.formats.filter { fps30($0) && w($0) >= 1920 }
        let byW = { (a: AVCaptureDevice.Format, b: AVCaptureDevice.Format) in w(a) < w(b) }
        if let f = ok.filter({ $0.supportedColorSpaces.contains(.appleLog) }).min(by: byW) { return (f, true) }
        if let f = ok.filter({ w($0) == 1920 && !$0.isVideoHDRSupported }).first ?? ok.min(by: byW) { return (f, false) }
        return nil
    }

    func capture(_ o: Opts, recording: @escaping () -> Void, progress: @escaping (Double) -> Void,
                 done: @escaping (Swift.Result<Result, Error>) -> Void) {
        queue.async {
            Thread.sleep(forTimeInterval: 0.15) // WebKit uvolní kameru
            try? FileManager.default.createDirectory(at: RawCapture.dir, withIntermediateDirectories: true)
            do {
                guard let (dev, lensZoom) = self.device(o) else { throw QError(message: "kamera nenalezena") }
                guard let (fmt, log) = self.pickFormat(dev) else { throw QError(message: "kamera neumí video 1080p") }
                let s = AVCaptureSession()
                s.beginConfiguration()
                s.automaticallyConfiguresCaptureDeviceForWideColor = false
                let input = try AVCaptureDeviceInput(device: dev)
                guard s.canAddInput(input) else { s.commitConfiguration(); throw QError(message: "kamera je obsazená") }
                s.addInput(input)
                let out = AVCaptureMovieFileOutput()
                guard s.canAddOutput(out) else { s.commitConfiguration(); throw QError(message: "nejde natáčet") }
                s.addOutput(out)
                try dev.lockForConfiguration()
                dev.activeFormat = fmt
                if log { dev.activeColorSpace = .appleLog } else if fmt.supportedColorSpaces.contains(.sRGB) { dev.activeColorSpace = .sRGB }
                dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                if o.zoom > lensZoom * 1.01 { dev.videoZoomFactor = min(dev.activeFormat.videoMaxZoomFactor, o.zoom / lensZoom) }
                dev.unlockForConfiguration()
                if let c = out.connection(with: .video) {
                    if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                    if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .standard }
                    // HEVC, když ho kamera v tomhle režimu dovolí (ProRes by měl stovky MB)
                    if out.availableVideoCodecTypes.contains(.hevc) { out.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: c) }
                }
                out.maxRecordedDuration = CMTime(seconds: o.seconds, preferredTimescale: 600)
                s.commitConfiguration()
                self.session = s
                s.startRunning()
                guard s.isRunning else { throw QError(message: "kamera se nespustila") }
                // usadit expozici a ostření
                let t0 = Date()
                Thread.sleep(forTimeInterval: 0.4)
                while (dev.isAdjustingExposure || dev.isAdjustingFocus) && Date().timeIntervalSince(t0) < 1.5 { Thread.sleep(forTimeInterval: 0.05) }

                let id = UUID().uuidString
                let src = RawCapture.dir.appendingPathComponent(id + "-src.mov")
                let sem = DispatchSemaphore(value: 0)
                var recErr: Error?
                var recURL: URL?
                self.finished = { url, err in recURL = url; recErr = err; sem.signal() }
                out.startRecording(to: src, recordingDelegate: self)
                recording()
                if sem.wait(timeout: .now() + o.seconds + 6) == .timedOut { out.stopRecording(); _ = sem.wait(timeout: .now() + 3) }
                s.stopRunning()
                self.session = nil
                guard let url = recURL else { throw recErr ?? QError(message: "klip se nenatočil") }

                var res = Result()
                res.log = log
                res.lensZoom = lensZoom
                let mp4 = RawCapture.dir.appendingPathComponent(id + ".mp4"), jpg = RawCapture.dir.appendingPathComponent(id + ".jpg")
                let sj = RawCapture.dir.appendingPathComponent(id + "-s.jpg")
                do {
                    try ClipDevelop.process(src: url, dst: mp4, thumb: jpg, log: log, film: o.film, str: o.str, grain: o.grain, hal: o.hal, vig: o.vig, apl: o.apl, ev: o.ev, con: o.con, sat: o.sat, gn: o.gn, bloom: o.bloom, glow: o.glow, srcThumb: sj, progress: progress)
                } catch { try? FileManager.default.removeItem(at: url); throw error }
                if let cid = ClipStore.keep(url) { res.src = cid; if FileManager.default.fileExists(atPath: sj.path) { res.sjpg = id + "-s.jpg" } }
                res.mp4 = id + ".mp4"; res.jpg = id + ".jpg"
                done(.success(res))
            } catch {
                self.session?.stopRunning()
                self.session = nil
                done(.failure(error))
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        // dosažení maxRecordedDuration chodí jako „chyba“, ale soubor je v pořádku
        var ok = error == nil
        if let e = error as NSError?, (e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true { ok = true }
        finished?(ok ? url : nil, ok ? nil : error)
        finished = nil
    }
}

// Originály klipů (Apple Log, HEVC 10 bit 1080p, ~15 MB / 5 s): zůstávají v Documents/Klipy, aby šel film změnit i po natočení.
// Hotové video je jen výstup – nové vyvolání jde vždy z originálu, nikdy z už vyvolaného klipu. Smaže se spolu s klipem v galerii.
enum ClipStore {
    static let dir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Klipy", isDirectory: true)
    static func url(_ id: String) -> URL { dir.appendingPathComponent(id.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".mov") }
    // přesune čerstvý záznam do úložiště; vrátí id, nebo nil (pak se originál neuchová a klip nepůjde upravit)
    static func keep(_ tmp: URL) -> String? {
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try FileManager.default.moveItem(at: tmp, to: url(id)); return id } catch { Ladeni.log("originál klipu se neuložil: \(error.localizedDescription)"); return nil }
    }
    static func remove(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }
}

// Film na klip: Apple Log (Rec.2020) → lineární světlo → log vstup filmu v2 (t = (log2(x/0,18)+8)/14) → LUT filmu.
// Celý převod je předpočítaný do jedné 3D tabulky 64³ (vstup = kódové hodnoty logu), takže jde po snímcích na GPU.
enum ClipDevelop {
    static func appleLogToLinear(_ p: Double) -> Double {
        let r0 = -0.05641088, rt = 0.01, c = 47.28711236, b = 0.00964052, g = 0.08550479, be = 0.69336945
        let pt = c * (rt - r0) * (rt - r0)
        if p >= pt { return pow(2, (p - be) / g) - b }
        if p >= 0 { return (p / c).squareRoot() + r0 }
        return r0
    }

    static func srgbToLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func linearToSrgb(_ v: Double) -> Double { let x = min(1, max(0, v)); return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }

    // LUT filmu z balíčku (Web/luts/log/KOD.png): n × n² px, y = zelená, x = červená + modrá·n, hodnoty sRGB
    static func filmLUT(_ code: String) -> (Int, [Float])? {
        guard code != "NONE", let url = Bundle.main.resourceURL?.appendingPathComponent("Web/luts/log/\(code).png"),
              let img = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let n = img.height, w = img.width
        guard w == n * n else { return nil }
        var px = [UInt8](repeating: 0, count: w * n * 4)
        guard let ctx = CGContext(data: &px, width: w, height: n, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: n))
        return (n, px.map { Float($0) / 255 })
    }

    static func sample(_ lut: (Int, [Float]), _ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let (n, d) = lut, m = Double(n - 1), w = n * n
        let fr = min(max(r, 0), 1) * m, fg = min(max(g, 0), 1) * m, fb = min(max(b, 0), 1) * m
        let r0 = Int(fr), g0 = Int(fg), b0 = Int(fb), r1 = min(r0 + 1, n - 1), g1 = min(g0 + 1, n - 1), b1 = min(b0 + 1, n - 1)
        let tr = fr - Double(r0), tg = fg - Double(g0), tb = fb - Double(b0)
        func at(_ ri: Int, _ gi: Int, _ bi: Int, _ k: Int) -> Double { Double(d[(gi * w + bi * n + ri) * 4 + k]) }
        var o = [0.0, 0.0, 0.0]
        for k in 0..<3 {
            let c00 = at(r0, g0, b0, k) * (1 - tr) + at(r1, g0, b0, k) * tr, c10 = at(r0, g1, b0, k) * (1 - tr) + at(r1, g1, b0, k) * tr
            let c01 = at(r0, g0, b1, k) * (1 - tr) + at(r1, g0, b1, k) * tr, c11 = at(r0, g1, b1, k) * (1 - tr) + at(r1, g1, b1, k) * tr
            o[k] = (c00 * (1 - tg) + c10 * tg) * (1 - tb) + (c01 * (1 - tg) + c11 * tg) * tb
        }
        return (o[0], o[1], o[2])
    }

    // Tabulka 64³ RGBA float: vstup = kódové hodnoty videa (log nebo sRGB), výstup = sRGB po filmu
    /* stejný převod jako aplInv / aplFwd ve webu (index.html): Apple Log = scéna → napůl k vzhledu iPhonu (jako RAW fotka a hledáček);
       běžné video bez logu je už zpracované Applem → napůl zpět ke scéně */
    static func aplEv(_ lg: Double) -> Double {
        let ss = { (a: Double, b: Double, x: Double) -> Double in let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        return min(2.4, 2.2 * pow(2, -(lg + 7.6) / 1.8)) * (1 - ss(-4.6, -2.7, lg)) - 0.22 * exp(-pow((lg + 1.8) / 0.8, 2)) + 1.2 * ss(-0.3, 1, lg)
    }
    static func aplSat(_ lg: Double) -> Double {
        let ss = { (a: Double, b: Double, x: Double) -> Double in let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        return lg < -5 ? 0.5 + 0.1 * ss(-7, -5, lg) : 0.6 + 0.15 * ss(-4.5, -2, lg)
    }
    static func luma(_ c: [Double]) -> Double { max(0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2], 1e-5) }
    static func aplInv(_ c: [Double], _ k: Double) -> [Double] {
        let L = luma(c), lg = log2(L), s = 1 + (aplSat(lg) - 1) * k, e = pow(2, aplEv(lg) * k)
        return c.map { max(L + ($0 - L) * s, 0) * e }
    }
    static func aplFwd(_ c: [Double], _ k: Double) -> [Double] {
        let lx = log2(luma(c)); var lg = lx
        for _ in 0..<3 { lg = lx - aplEv(lg) * k }
        let x = c.map { $0 * pow(2, -aplEv(lg) * k) }, L = luma(x), s = 1 + (aplSat(lg) - 1) * k
        return x.map { max(L + ($0 - L) / s, 0) }
    }

    static func cube(film: String, log: Bool, str: Double, apl: Double = 0.5, ev: Double = 0, con: Double = 0, sat: Double = 0) -> Data {
        let n = 64, lut = filmLUT(film)
        // Rec.2020 → Rec.709/sRGB (lineárně)
        let M = [1.6605, -0.5876, -0.0728, -0.1246, 1.1329, -0.0083, -0.0182, -0.1006, 1.1187]
        var out = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let p = [Double(ri), Double(gi), Double(bi)].map { $0 / Double(n - 1) }
            var l: [Double]
            if log {
                let a = p.map(appleLogToLinear)
                l = [M[0] * a[0] + M[1] * a[1] + M[2] * a[2], M[3] * a[0] + M[4] * a[1] + M[5] * a[2], M[6] * a[0] + M[7] * a[1] + M[8] * a[2]]
            } else { l = p.map(srgbToLinear) }
            l = l.map { max($0, 0) }
            if apl > 0 { l = log ? aplFwd(l, apl) : aplInv(l, apl) }
            // jako filmLog ve webu: korekce expozice, sytost a kontrast (v log expozici) PŘED tabulkou filmu
            if ev != 0 { let k = pow(2, ev); l = l.map { $0 * k } }
            if sat != 0 { let L = luma(l); l = l.map { max(L + ($0 - L) * (1 + sat), 0) } }
            // bez filmu: lineární → sRGB s měkkým ramenem (log jinak přepálí)
            let plain = l.map { linearToSrgb($0 / (1 + $0 * 0.18)) }
            var c = plain
            if let lut {
                let t = l.map { min(max((log2(max($0, 1e-6) / 0.18) * (1 + con * 0.5) + 8) / 14, 0), 1) }
                let f = sample(lut, t[0], t[1], t[2])
                c = [plain[0] + (f.0 - plain[0]) * str, plain[1] + (f.1 - plain[1]) * str, plain[2] + (f.2 - plain[2]) * str]
            }
            let i = ((bi * n + gi) * n + ri) * 4
            out[i] = Float(c[0]); out[i + 1] = Float(c[1]); out[i + 2] = Float(c[2]); out[i + 3] = 1
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func process(src: URL, dst: URL, thumb: URL, log: Bool, film: String, str: Double, grain: Double, hal: Double, vig: Double, apl: Double = 0.5, ev: Double = 0, con: Double = 0, sat: Double = 0, gn: Double = 4250, bloom: Double = 0, glow: Double = 0, srcThumb: URL? = nil,
                        progress: (Double) -> Void) throws {
        let asset = AVURLAsset(url: src)
        guard let track = asset.tracks(withMediaType: .video).first else { throw QError(message: "klip je prázdný") }
        let size = track.naturalSize, dur = max(asset.duration.seconds, 0.1)
        let reader = try AVAssetReader(asset: asset)
        // nativní 10bit YUV bez převodu barev (hodnoty zůstanou v logu)
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        ro.alwaysCopiesSampleData = false
        reader.add(ro)
        try? FileManager.default.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let w = Int(size.width), h = Int(size.height)
        let codec: AVVideoCodecType = .hevc
        let wi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        wi.transform = track.preferredTransform
        wi.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: wi, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(wi)

        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAh])
        let cubeF = CIFilter(name: "CIColorCube")!
        cubeF.setValue(64, forKey: "inputCubeDimension")
        var cut: String?
        cubeF.setValue(cube(film: film, log: log, str: str, apl: apl, ev: ev, con: con, sat: sat), forKey: "inputCubeData")
        let ext = CGRect(x: 0, y: 0, width: w, height: h)
        /* zrno = šum v hustotě negativu: přidává se do logu PŘED filmem, takže ho křivka filmu sama zeslabí ve světlech
           (rameno) i ve stínech (pata) a nejvíc je vidět ve středních tónech – jako skutečné zrno. Dvě velikosti zrn
           (shluky), převážně jednobarevné s trochou barevných mračen barviv, každý snímek jinde */
        let sd = (log ? 0.026 : 0.016) * grain * max(str, 0.15) // σ v kódech logu (1 EV ≈ 0,085)
        let noiseBase = CIFilter(name: "CIRandomGenerator")!.outputImage!
        func grainLayer(_ frame: Int, scale: CGFloat, blur: Double, amp: Double, salt: Int) -> CIImage {
            let off = CGAffineTransform(translationX: CGFloat((frame * 977 + salt * 331) % 8192), y: CGFloat((frame * 613 + salt * 173) % 8192))
            let n = noiseBase.transformed(by: off).transformed(by: CGAffineTransform(scaleX: scale, y: scale)).applyingGaussianBlur(sigma: blur).cropped(to: ext)
            let m = CGFloat(amp * 0.27), c = CGFloat(amp * 0.19) // mono + barevná složka
            return n.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m + c, y: m, z: m, w: 0), "inputGVector": CIVector(x: m, y: m + c, z: m, w: 0),
                "inputBVector": CIVector(x: m, y: m, z: m + c, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -(3 * m + c) / 2, y: -(3 * m + c) / 2, z: -(3 * m + c) / 2, w: 0)])
        }
        /* Zrno jako ve fotce (grv 3, kalibrované na spektrafilm): každá barevná vrstva negativu šumí zvlášť (σ 0,232 / 0,152 / 0,208 EV
           na pixel 8,2 µm, vrstvy se míchají jen z desetiny), jemné – jeden pixel klipu průměruje víc zrn (4250 zrn na delší stranu políčka).
           1 EV ≈ 0,0855 kódu Apple Logu; CIRandomGenerator = nezávislé kanály 0…1 (σ 0,2887), rozostření 0,5 px ubere σ na 0,564 */
        let gk = grain / 0.5 * str * (log ? 0.0855 : 0.052) * min(1, Double(max(w, h)) / max(gn, 500)) / (0.2887 * 0.564)
        func negGrain(_ frame: Int) -> CIImage {
            let off = CGAffineTransform(translationX: CGFloat((frame * 977 + 331) % 8192), y: CGFloat((frame * 613 + 173) % 8192))
            let n = noiseBase.transformed(by: off).applyingGaussianBlur(sigma: 0.5).cropped(to: ext)
            let r = CGFloat(0.232 * gk), g = CGFloat(0.152 * gk), b = CGFloat(0.208 * gk), x: CGFloat = 0.1
            return n.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: r * x, z: r * x, w: 0), "inputGVector": CIVector(x: g * x, y: g, z: g * x, w: 0),
                "inputBVector": CIVector(x: b * x, y: b * x, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -r * (1 + 2 * x) / 2, y: -g * (1 + 2 * x) / 2, z: -b * (1 + 2 * x) / 2, w: 0)])
        }
        /* halation = červenooranžová záře kolem opravdu přepálených světel (v logu nad ~1 EV nad bílou), jen kolem, ne přes světlo samo */
        let t0h: CGFloat = log ? 0.70 : 0.93, t1h: CGFloat = log ? 0.86 : 1.0, hk = CGFloat(0.45 * hal)
        let q: CGFloat = 0.25, hh = CGFloat(h) * q
        /* Bloom a Glow jako ve fotce. Čísla napasovaná na výstup foto shaderu na Honzově snímku se sluncem (test-raw/honza/b/fit.py):
           Bloom = měkká záře jen z opravdu přepálených světel (scéna 2× nad bílou = kód Apple Logu nad ~0,78), tři rozostření
           0,6 / 1,6 / 4,5 % delší strany s vahami 0,5 / 0,8 / 1, přičtené „screen“ (v už světlém místě přidá míň), síla 1,25 × bloom.
           Glow = difúze: rozostřený hotový obraz (1,2 % delší strany) vážený jasem (smoothstep 0,4…0,95) × 0,85, screen s vahou glow · 0,6,
           a nepatrné zvednutí černé (glow · 0,15). Počítá se ve čtvrtinovém rozlišení (jako halation). */
        let fxQ: CGFloat = 0.25, fxM = Double(max(w, h)) * Double(fxQ), bloomK = CGFloat(1.25 * bloom), glowK = CGFloat(glow)
        func fxScale(_ i: CIImage, _ k: CGFloat, bias: CGFloat = 0, alpha: CGFloat = 1) -> CIImage {
            i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        }
        func fxMul(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]) }
        func fxAdd(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b]) }
        func fxUp(_ i: CIImage) -> CIImage { i.transformed(by: CGAffineTransform(scaleX: 1 / fxQ, y: 1 / fxQ)).cropped(to: ext) }
        // vinětace stejně jako v hledáčku: c *= mix(1, smoothstep(.95, .2, |q|·1,15), vig), q = střed ±0,5 přepočtený na kratší stranu
        var vigImg: CIImage?
        if vig > 0.005 {
            let vw = 180, vh = max(1, Int((Double(vw) * Double(h) / Double(w)).rounded()))
            var px = [UInt8](repeating: 255, count: vw * vh * 4)
            let ar = Double(w) / Double(h)
            for y in 0..<vh { for x in 0..<vw {
                var qx = (Double(x) + 0.5) / Double(vw) - 0.5, qy = (Double(y) + 0.5) / Double(vh) - 0.5
                if ar > 1 { qx *= ar } else { qy /= ar }
                let d = (qx * qx + qy * qy).squareRoot() * 1.15
                let t = min(max((d - 0.95) / (0.2 - 0.95), 0), 1), ss = t * t * (3 - 2 * t)
                let v = UInt8(min(255, max(0, (1 + (ss - 1) * vig) * 255)))
                let i = (y * vw + x) * 4; px[i] = v; px[i + 1] = v; px[i + 2] = v
            } }
            if let prov = CGDataProvider(data: Data(px) as CFData),
               let cg = CGImage(width: vw, height: vh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: vw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                vigImg = CIImage(cgImage: cg, options: [.colorSpace: NSNull()]).transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(vw), y: CGFloat(h) / CGFloat(vh))).clampedToExtent().cropped(to: ext)
            }
        }

        guard reader.startReading() else { throw reader.error ?? QError(message: "klip nejde přečíst") }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var frame = 0
        var t0: CMTime?
        while let sb = ro.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if t0 == nil { t0 = pts }
            let src = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
            if frame == 0, let st = srcThumb {
                // první snímek originálu převedený jako hledáček (log → světlo → rameno → sRGB): web na něm ukáže náhled jiného filmu
                var sv = src
                if log { let vf = CameraEngine.cubeFilter(CameraEngine.logCube(n: 48, linearScale: nil)); vf.setValue(src, forKey: kCIInputImageKey); sv = vf.outputImage ?? src }
                if let j = ctx.jpegRepresentation(of: sv.cropped(to: ext), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) { try? j.write(to: st) }
            }
            var img = src
            if gk > 0.0001 {
                img = negGrain(frame).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
            }
            cubeF.setValue(img, forKey: kCIInputImageKey)
            img = (cubeF.outputImage ?? img).cropped(to: ext)
            if hk > 0.01 {
                let k = 1 / (t1h - t0h)
                let mask = src.applyingFilter("CIMaximumComponent").applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputBiasVector": CIVector(x: -t0h * k, y: -t0h * k, z: -t0h * k, w: 0)])
                    .applyingFilter("CIColorClamp").transformed(by: CGAffineTransform(scaleX: q, y: q))
                let me = mask.clampedToExtent()
                let b1 = me.applyingGaussianBlur(sigma: Double(hh * 0.008)), b2 = me.applyingGaussianBlur(sigma: Double(hh * 0.022))
                let blur = b1.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.6, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.6, w: 0)])
                    .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b2.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.4, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.4, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.4, w: 0)])])
                // záře kolem minus světlo samo (oříznuté na ≥ 0), obarvit a zvětšit zpět
                let neg = me.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
                let ring = neg.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blur]) // blur − mask, záporné ořízne CIColorClamp
                let tint = ring.applyingFilter("CIColorClamp").applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: hk, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: hk * 0.22, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: hk * 0.05, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
                    .transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q)).cropped(to: ext)
                img = tint.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
            }
            if bloomK > 0.002 {
                // energie světla: log 0,779 → 0,375, 0,885 → 1 (pod prahem nic, jako ve fotce); běžné video: jen skoro bílá
                let mx = src.applyingFilter("CIMaximumComponent")
                let ramp = (log ? fxScale(mx, 5.848, bias: -4.18) : fxScale(mx, 14.3, bias: -13.3)).applyingFilter("CIColorClamp")
                let gate = (log ? fxScale(mx, 200, bias: -155.8) : fxScale(mx, 200, bias: -186)).applyingFilter("CIColorClamp")
                let hm = fxMul(fxMul(ramp, gate), img).transformed(by: CGAffineTransform(scaleX: fxQ, y: fxQ)).clampedToExtent()
                let b = fxAdd(fxAdd(fxScale(hm.applyingGaussianBlur(sigma: fxM * 0.006), 0.5), fxScale(hm.applyingGaussianBlur(sigma: fxM * 0.016), 0.8)), hm.applyingGaussianBlur(sigma: fxM * 0.045))
                let inv = fxScale(img, -1, bias: 1)
                img = fxAdd(fxScale(fxMul(fxUp(b), inv), bloomK, alpha: 0), img).cropped(to: ext)
            }
            if glowK > 0.002 {
                let dg = fxUp(img.transformed(by: CGAffineTransform(scaleX: fxQ, y: fxQ)).clampedToExtent().applyingGaussianBlur(sigma: fxM * 0.012))
                // gw = smoothstep(0,4…0,95) z jasu rozostřeného obrazu
                let s: CGFloat = 1 / 0.55
                let t = dg.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.2126 * s, y: 0.7152 * s, z: 0.0722 * s, w: 0), "inputGVector": CIVector(x: 0.2126 * s, y: 0.7152 * s, z: 0.0722 * s, w: 0),
                    "inputBVector": CIVector(x: 0.2126 * s, y: 0.7152 * s, z: 0.0722 * s, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: -0.4 * s, y: -0.4 * s, z: -0.4 * s, w: 0)]).applyingFilter("CIColorClamp")
                let poly = CIVector(x: 0, y: 0, z: 3, w: -2)
                let gw = t.applyingFilter("CIColorPolynomial", parameters: ["inputRedCoefficients": poly, "inputGreenCoefficients": poly, "inputBlueCoefficients": poly, "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)])
                let a = fxMul(fxMul(dg, gw), fxScale(img, -1, bias: 1))
                img = fxAdd(fxScale(a, 0.85 * 0.6 * glowK, alpha: 0), img).cropped(to: ext)
                img = fxScale(img, 1 - 0.15 * glowK * 0.04, bias: 0.15 * glowK * 0.025)
            }
            if let v = vigImg { img = img.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: v]).cropped(to: ext) }
            while !wi.isReadyForMoreMediaData && writer.status == .writing { Thread.sleep(forTimeInterval: 0.005) }
            if writer.status != .writing { cut = writer.error?.localizedDescription ?? "zápis se zastavil"; break }
            guard let pool = ad.pixelBufferPool else { cut = "došla paměť na snímky"; break }
            var outPB: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
            guard let opb = outPB else { cut = "došla paměť na snímky"; break }
            ctx.render(img, to: opb, bounds: ext, colorSpace: nil)
            CVBufferSetAttachment(opb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(opb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(opb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            if !ad.append(opb, withPresentationTime: CMTimeSubtract(pts, t0!)) { cut = writer.error?.localizedDescription ?? "snímek se nezapsal"; break }
            frame += 1
            progress(min(1, CMTimeSubtract(pts, t0!).seconds / dur))
        }
        wi.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? QError(message: "klip se nepodařilo uložit") }
        if let cut { Ladeni.log("klip vyvolání přerušeno po \(frame) snímcích: \(cut)"); throw QError(message: "klip se nevyvolal celý (" + cut + ")") }
        if reader.status == .failed { throw reader.error ?? QError(message: "klip nejde přečíst") }

        // náhled = první snímek (otočený jako video)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: dst))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1440, height: 1440)
        if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil), let j = UIImage(cgImage: cg).jpegData(compressionQuality: 0.9) {
            try j.write(to: thumb)
        }
    }
}
