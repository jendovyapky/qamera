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
        var film = "NONE", str = 1.0, grain = 0.5
    }

    struct Result {
        var mp4 = "", jpg = ""
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
                try ClipDevelop.process(src: url, dst: mp4, thumb: jpg, log: log, film: o.film, str: o.str, grain: o.grain, progress: progress)
                try? FileManager.default.removeItem(at: url)
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
    static func cube(film: String, log: Bool, str: Double) -> Data {
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
            // bez filmu: lineární → sRGB s měkkým ramenem (log jinak přepálí)
            let plain = l.map { linearToSrgb($0 / (1 + $0 * 0.18)) }
            var c = plain
            if let lut {
                let t = l.map { min(max((log2(max($0, 1e-6) / 0.18) + 8) / 14, 0), 1) }
                let f = sample(lut, t[0], t[1], t[2])
                c = [plain[0] + (f.0 - plain[0]) * str, plain[1] + (f.1 - plain[1]) * str, plain[2] + (f.2 - plain[2]) * str]
            }
            let i = ((bi * n + gi) * n + ri) * 4
            out[i] = Float(c[0]); out[i + 1] = Float(c[1]); out[i + 2] = Float(c[2]); out[i + 3] = 1
        } } }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func process(src: URL, dst: URL, thumb: URL, log: Bool, film: String, str: Double, grain: Double,
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
        cubeF.setValue(cube(film: film, log: log, str: str), forKey: "inputCubeData")
        let ext = CGRect(x: 0, y: 0, width: w, height: h)
        // zrno: šum ze CIRandomGenerator, jednobarevný, mírně zvětšený a rozmazaný (shluky), každý snímek jinde
        let amp = 0.10 * grain * str
        let noiseBase = CIFilter(name: "CIRandomGenerator")!.outputImage!

        guard reader.startReading() else { throw reader.error ?? QError(message: "klip nejde přečíst") }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var frame = 0
        var t0: CMTime?
        while let sb = ro.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if t0 == nil { t0 = pts }
            var img = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
            cubeF.setValue(img, forKey: kCIInputImageKey)
            img = cubeF.outputImage ?? img
            if amp > 0.001 {
                let off = CGAffineTransform(translationX: CGFloat((frame * 977) % 4096), y: CGFloat((frame * 613) % 4096))
                let n = noiseBase.transformed(by: off).transformed(by: CGAffineTransform(scaleX: 1.6, y: 1.6))
                    .applyingGaussianBlur(sigma: 0.55).cropped(to: ext)
                let a = CGFloat(amp)
                let mono = n.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: a / 3, y: a / 3, z: a / 3, w: 0), "inputGVector": CIVector(x: a / 3, y: a / 3, z: a / 3, w: 0),
                    "inputBVector": CIVector(x: a / 3, y: a / 3, z: a / 3, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: -a / 2, y: -a / 2, z: -a / 2, w: 1)])
                img = mono.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
            }
            while !wi.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = ad.pixelBufferPool else { break }
            var outPB: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
            guard let opb = outPB else { break }
            ctx.render(img, to: opb, bounds: ext, colorSpace: nil)
            CVBufferSetAttachment(opb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(opb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(opb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            ad.append(opb, withPresentationTime: CMTimeSubtract(pts, t0!))
            frame += 1
            progress(min(1, CMTimeSubtract(pts, t0!).seconds / dur))
        }
        wi.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? QError(message: "klip se nepodařilo uložit") }
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
