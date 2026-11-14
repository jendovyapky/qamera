import AVFoundation
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

// Vlastní kamera appky (krok 1): hledáček ze snímků v Apple Logu místo getUserMedia ve WebKitu.
// Obraz z WebKitu je už zpracovaný Applem (lokální tone mapping po částech, sytost) → hledáček nikdy neseděl s RAW fotkou ani klipem.
// Tady se log (= skutečné světlo scény, bez úprav Applu) převede přesně jako vyvolaný RAW (RawDevelop): lineární Rec.709,
// měkké rameno světel, sRGB → JPEG ~1280 px → web ho přes /__live dostane jako zdroj hledáčku a dá na něj stejný film jako na RAW.
// Fotka bez RAW = plný snímek z logu (4K) vyvolaný stejně (RawDevelop bez měření expozice) – hledáček se kvůli ní nezastaví.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraEngine()

    private let q = DispatchQueue(label: "qamera.cam")
    private let vq = DispatchQueue(label: "qamera.cam.frames")
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private(set) var log = false
    private(set) var lens = "wide"
    private(set) var lensZoom = 1.0
    private var size = CGSize(width: 1080, height: 1920)
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private lazy var viewCube: CIFilter = Self.cubeFilter(Self.logCube(n: 48, linearScale: nil))
    private var stillWait: ((CIImage) -> Void)?
    private var lastFrame = 0.0
    var onFrame: ((Data) -> Void)?   // LocalServer → /__live
    var canSend: () -> Bool = { true }

    // MARK: převod Apple Log → stejný formát jako vyvolaný RAW

    /* 3D LUT z kódů Apple Logu (Rec.2020): linearScale nil = hledáček (lineární Rec.709 → rameno nad 0,55 se zachovaným odstínem → sRGB,
       přesně jako RawDevelop / raw.js), jinak lineární světlo / linearScale (pro vyvolání fotky) */
    static func logCube(n: Int, linearScale: Double?) -> (Int, Data) {
        let M = [1.6605, -0.5876, -0.0728, -0.1246, 1.1329, -0.0083, -0.0182, -0.1006, 1.1187]
        var out = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let a = [ri, gi, bi].map { ClipDevelop.appleLogToLinear(Double($0) / Double(n - 1)) }
            var l = [M[0] * a[0] + M[1] * a[1] + M[2] * a[2], M[3] * a[0] + M[4] * a[1] + M[5] * a[2], M[6] * a[0] + M[7] * a[1] + M[8] * a[2]].map { max($0, 0) }
            if let s = linearScale { l = l.map { min($0 / s, 1) } } else {
                let m = l.max() ?? 0
                if m > 0.55 { let f = 0.55 + 0.45 * (1 - exp(-(m - 0.55) / 0.45)); l = l.map { $0 * f / m } }
                l = l.map { ClipDevelop.linearToSrgb($0) }
            }
            let i = ((bi * n + gi) * n + ri) * 4
            out[i] = Float(l[0]); out[i + 1] = Float(l[1]); out[i + 2] = Float(l[2]); out[i + 3] = 1
        } } }
        return (n, out.withUnsafeBufferPointer { Data(buffer: $0) })
    }
    static func cubeFilter(_ c: (Int, Data)) -> CIFilter {
        let f = CIFilter(name: "CIColorCube")!
        f.setValue(c.0, forKey: "inputCubeDimension"); f.setValue(c.1, forKey: "inputCubeData")
        return f
    }

    // MARK: zařízení a formát

    private func pick(_ lens: String) -> (AVCaptureDevice, Double)? {
        if lens == "front" {
            guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return nil }
            return (d, 1)
        }
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                                                     mediaType: .video, position: .back).devices
        guard let wide = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return nil }
        let fov = { (d: AVCaptureDevice) in tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360) }
        let factor = { (d: AVCaptureDevice) in fov(wide) / max(fov(d), 0.0001) }
        if lens == "ultra", let u = found.first(where: { $0.deviceType == .builtInUltraWideCamera }) { return (u, factor(u)) }
        if lens == "tele", let t = found.first(where: { $0.deviceType == .builtInTelephotoCamera }) { return (t, factor(t)) }
        return (wide, 1)
    }

    // 4K s Apple Logem a 30 fps (fotka z logu 8 Mpx); jinak 1080p; když log není (přední, starší iPhone), běžné video (web pak dá převod jako dřív)
    private func format(_ d: AVCaptureDevice) -> (AVCaptureDevice.Format, Bool)? {
        let fps30 = { (f: AVCaptureDevice.Format) in f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 && $0.minFrameRate <= 30.1 } }
        let w = { (f: AVCaptureDevice.Format) in Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).width) }
        let ok = d.formats.filter { fps30($0) && w($0) >= 1920 && w($0) <= 4096 }
        let logF = ok.filter { $0.supportedColorSpaces.contains(.appleLog) }
        if let f = logF.max(by: { w($0) < w($1) }) { return (f, true) }
        if let f = ok.filter({ w($0) == 1920 && !$0.isVideoHDRSupported }).first ?? ok.min(by: { w($0) < w($1) }) { return (f, false) }
        return nil
    }

    // MARK: ovládání (z mostu WebApp)

    func start(lens: String, zoom: Double, done: @escaping (Swift.Result<[String: Any], Error>) -> Void) {
        q.async {
            self.stopNow()
            do {
                guard let (dev, lz) = self.pick(lens) else { throw QError(message: "kamera nenalezena") }
                guard let (fmt, log) = self.format(dev) else { throw QError(message: "kamera neumí video") }
                let s = AVCaptureSession()
                s.beginConfiguration()
                s.automaticallyConfiguresCaptureDeviceForWideColor = false
                s.sessionPreset = .inputPriority
                let input = try AVCaptureDeviceInput(device: dev)
                guard s.canAddInput(input) else { s.commitConfiguration(); throw QError(message: "kamera je obsazená") }
                s.addInput(input)
                let out = AVCaptureVideoDataOutput()
                out.alwaysDiscardsLateVideoFrames = true
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: log ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA]
                out.setSampleBufferDelegate(self, queue: self.vq)
                guard s.canAddOutput(out) else { s.commitConfiguration(); throw QError(message: "nejde číst obraz") }
                s.addOutput(out)
                try dev.lockForConfiguration()
                dev.activeFormat = fmt
                if log { dev.activeColorSpace = .appleLog } else if fmt.supportedColorSpaces.contains(.sRGB) { dev.activeColorSpace = .sRGB }
                dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.videoZoomFactor = max(1, min(dev.activeFormat.videoMaxZoomFactor, zoom))
                dev.unlockForConfiguration()
                if let c = out.connection(with: .video) {
                    if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                    if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false } // přední zrcadlí web sám
                    if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .standard }
                }
                s.commitConfiguration()
                self.session = s; self.device = dev; self.log = log; self.lens = lens; self.lensZoom = lz
                let dm = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                self.size = CGSize(width: Int(min(dm.width, dm.height)), height: Int(max(dm.width, dm.height)))
                s.startRunning()
                guard s.isRunning else { throw QError(message: "kamera se nespustila") }
                done(.success(["log": log, "lens": lens, "lensZoom": lz, "w": Int(self.size.width), "h": Int(self.size.height),
                               "maxZoom": Double(min(dev.activeFormat.videoMaxZoomFactor, 10)), "torch": dev.hasTorch,
                               "label": dev.localizedName]))
            } catch { self.stopNow(); done(.failure(error)) }
        }
    }

    // Synchronně: RawCapture / ClipCapture si hned potom otevřou vlastní session
    func stop() { q.sync { self.stopNow() } }
    private func stopNow() {
        session?.stopRunning(); session = nil; device = nil
    }

    var isOn: Bool { q.sync { session != nil } }

    func setZoom(_ z: Double) {
        q.async { guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.videoZoomFactor = max(1, min(d.activeFormat.videoMaxZoomFactor, z)); d.unlockForConfiguration() }
    }
    func torch(_ on: Bool) {
        q.async { guard let d = self.device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
            if on { try? d.setTorchModeOn(level: 1) } else { d.torchMode = .off }; d.unlockForConfiguration() }
    }
    // ťuknutí do hledáčku: x, y 0…1 v obraze na výšku → bod v senzoru (na šířku, otočený o 90°)
    func focus(x: Double, y: Double) {
        q.async { guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            let p = CGPoint(x: y, y: 1 - x)
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = p; if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus } }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p; if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure } }
            d.unlockForConfiguration()
            // po zaostření zpět na průběžné ostření (až se scéna změní)
            self.q.asyncAfter(deadline: .now() + 3) { guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }; d.unlockForConfiguration() }
        }
    }

    // MARK: snímky

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let img = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
        if let w = stillWait { stillWait = nil; w(img) }
        let now = CACurrentMediaTime()
        guard onFrame != nil, canSend(), now - lastFrame > 1 / 31 else { return }
        lastFrame = now
        let e = img.extent, k = min(1, 1280 / max(e.width, e.height))
        var v = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        if log { viewCube.setValue(v, forKey: kCIInputImageKey); v = viewCube.outputImage ?? v }
        let W = Int((e.width * k).rounded(.down)), H = Int((e.height * k).rounded(.down))
        guard W > 0, H > 0 else { return }
        var px = [UInt8](repeating: 255, count: W * H * 4)
        px.withUnsafeMutableBytes { p in ctx.render(v, toBitmap: p.baseAddress!, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8, colorSpace: nil) }
        guard let jpg = Self.jpeg(&px, w: W, h: H, q: 0.82) else { return }
        let meta: [String: Any] = ["w": W, "h": H, "log": log, "lens": lens]
        let mj = (try? JSONSerialization.data(withJSONObject: meta)) ?? Data("{}".utf8)
        var pkt = Data()
        var n = UInt32(2 + mj.count + jpg.count).bigEndian, m = UInt16(mj.count).bigEndian
        pkt.append(Data(bytes: &n, count: 4)); pkt.append(Data(bytes: &m, count: 2)); pkt.append(mj); pkt.append(jpg)
        onFrame?(pkt)
    }

    static func jpeg(_ px: inout [UInt8], w: Int, h: Int, q: Double) -> Data? {
        let out = NSMutableData()
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    // Fotka bez RAW: další celý snímek z logu → lineární světlo → RawDevelop (bez měření: expozice = jak ji změřil iPhone, stejně jako hledáček)
    func still(done: @escaping (Swift.Result<RawCapture.Result, Error>) -> Void) {
        q.async {
            guard self.session?.isRunning == true else { return done(.failure(QError(message: "kamera neběží"))) }
            let sem = DispatchSemaphore(value: 0)
            var got: CIImage?
            self.vq.sync { self.stillWait = { img in got = img; sem.signal() } }
            if sem.wait(timeout: .now() + 2) == .timedOut { self.vq.sync { self.stillWait = nil }; return done(.failure(QError(message: "kamera neposlala snímek"))) }
            guard let src = got else { return done(.failure(QError(message: "prázdný snímek"))) }
            let log = self.log, lz = self.lensZoom
            // vyvolání mimo frontu kamery, ať hledáček běží dál
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let lin: CIImage
                    if log {
                        let f = Self.cubeFilter(Self.logCube(n: 64, linearScale: 16))
                        f.setValue(src, forKey: kCIInputImageKey)
                        lin = (f.outputImage ?? src).applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: 16, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 16, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: 16, w: 0)])
                    } else {
                        lin = src.applyingFilter("CISRGBToneCurveToLinear")
                    }
                    let o = try RawDevelop.develop(image: lin, fixedEV: 0)
                    let id = UUID().uuidString
                    try? FileManager.default.createDirectory(at: RawCapture.dir, withIntermediateDirectories: true)
                    var res = RawCapture.Result(label: log ? "LOG" : "VIDEO", lensZoom: lz, ev: o.ev)
                    try o.jpg.write(to: RawCapture.dir.appendingPathComponent(id + ".jpg")); res.files["jpg"] = id + ".jpg"
                    if let hl = o.hl { try hl.write(to: RawCapture.dir.appendingPathComponent(id + "-hl.png")); res.files["hl"] = id + "-hl.png" }
                    done(.success(res))
                } catch { done(.failure(error)) }
            }
        }
    }
}
