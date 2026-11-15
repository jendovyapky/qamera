import AVFoundation
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

// Vlastní kamera appky (krok 1): hledáček ze snímků v Apple Logu místo getUserMedia ve WebKitu.
// Obraz z WebKitu je už zpracovaný Applem (lokální tone mapping po částech, sytost) → hledáček nikdy neseděl s RAW fotkou ani klipem.
// Tady se log (= skutečné světlo scény, bez úprav Applu) převede přesně jako vyvolaný RAW (RawDevelop): lineární Rec.709,
// měkké rameno světel, sRGB → JPEG ~1280 px → web ho přes /__live dostane jako zdroj hledáčku a dá na něj stejný film jako na RAW.
// Fotka bez RAW = plný snímek z logu (4K) vyvolaný stejně (RawDevelop bez měření expozice) – hledáček se kvůli ní nezastaví.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
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
    private var videoOut: AVCaptureVideoDataOutput?
    // klip ze stejné session (hledáček běží dál): snímky v logu jdou rovnou do AVAssetWriter; jen na frontě vq
    private final class Rec {
        let writer: AVAssetWriter, input: AVAssetWriterInput, url: URL, dur: Double
        var audio: AVAssetWriterInput?
        var t0: CMTime?
        var started: (() -> Void)?
        var done: ((URL?, String?) -> Void)?
        init(writer: AVAssetWriter, input: AVAssetWriterInput, url: URL, dur: Double) { self.writer = writer; self.input = input; self.url = url; self.dur = dur }
    }
    private var rec: Rec?
    // mikrofon jen v režimu KLIP (oranžová tečka a dotaz na mikrofon jen tam, kde se natáčí); přidá se do běžící session
    private var audioOut: AVCaptureAudioDataOutput?
    private var audioIn: AVCaptureDeviceInput?
    private var wantAudio = false
    func setAudio(_ on: Bool) { q.async { self.wantAudio = on; self.applyAudio() } }
    // jen na frontě q
    private func applyAudio() {
        guard let s = session else { return }
        if wantAudio, audioOut == nil {
            let st = AVCaptureDevice.authorizationStatus(for: .audio)
            if st == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { ok in if ok { self.q.async { self.applyAudio() } } }; return }
            guard st == .authorized, let mic = AVCaptureDevice.default(for: .audio) else { Ladeni.log("mikrofon nepovolený / chybí"); return }
            let exc = QCatch.run {
                s.beginConfiguration()
                defer { s.commitConfiguration() }
                guard let i = try? AVCaptureDeviceInput(device: mic), s.canAddInput(i) else { return }
                s.addInput(i)
                let o = AVCaptureAudioDataOutput()
                o.setSampleBufferDelegate(self, queue: self.vq)
                guard s.canAddOutput(o) else { s.removeInput(i); return }
                s.addOutput(o)
                self.audioIn = i; self.audioOut = o
            }
            Ladeni.log("mikrofon zap=\(audioOut != nil)\(exc.map { " CHYBA " + $0 } ?? "")")
        } else if !wantAudio, let o = audioOut {
            _ = QCatch.run { s.beginConfiguration(); s.removeOutput(o); if let i = self.audioIn { s.removeInput(i) }; s.commitConfiguration() }
            audioOut = nil; audioIn = nil
            Ladeni.log("mikrofon vyp")
        }
    }
    // spoušť během natáčení = konec klipu
    func stopRecording() { vq.async { if let r = self.rec { self.finishRec(r) } } }
    private static let dbgCtx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private var lastFrame = 0.0
    private var sent = 0
    private var framesOut = 0
    private var pktMs = 0.0
    var onFrame: ((Data) -> Void)?   // LocalServer → /__live
    private var lastISO: Float = 0
    var currentISO: Float { device?.iso ?? lastISO }
    // boční tlačítko Ovládání fotoaparátu (iOS 18+): film, objektiv, EV, ruční ISO a čas, síla filmu
    private var ctlFilms: [String] = []
    private var ctlFilm = 0
    private var ctlEv = 0.0
    private var ctlLenses: [String] = []
    private var ctlLens = 0
    private var ctlStr = 100.0
    private var ctlObjs: [AnyObject] = []
    // ruční expozice (nil = AUTO); když je nastavená jen jedna hodnota, druhá se dopočítá ze stejné expozice
    private var manIso: Float?
    private var manDur: Double?
    private var isoTitles: [Float] = []
    private var durTitles: [Double] = []
    var onCtl: ((String, Any) -> Void)?
    /// skutečné ISO a čas, když je zapnutá ruční expozice (RAW je pak fotí stejně); nil = AUTO
    var manualNow: (Float, Double)? { q.sync { (manIso == nil && manDur == nil) ? nil : device.map { ($0.iso, $0.exposureDuration.seconds) } } }
    func setCtl(films: [String]?, film: Int?, ev: Double?, lenses: [String]? = nil, lens: Int? = nil, str: Double? = nil) {
        var rebuild = false
        if let films, films != ctlFilms { ctlFilms = films; rebuild = true }
        if let lenses, lenses != ctlLenses { ctlLenses = lenses; rebuild = true }
        if let film { ctlFilm = film }
        if let ev { ctlEv = ev }
        if let lens { ctlLens = lens }
        if let str { ctlStr = str }
        guard #available(iOS 18.0, *) else { return }
        if rebuild {
            // názvy v nabídce bočního tlačítka jsou dané při vytvoření → nový seznam (oblíbené, jiná sada) = ovládání postavit znovu
            q.async {
                guard let s = self.session else { return }
                Ladeni.log("boční tlačítko: nový seznam filmů (\(self.ctlFilms.count)) / objektivů (\(self.ctlLenses.count)), vybraný \(self.ctlFilm)")
                _ = QCatch.run { s.beginConfiguration(); self.addControls(s); s.commitConfiguration() }
            }
        } else { DispatchQueue.main.async { self.syncCtl() } }
    }
    var canSend: () -> Bool = { true }

    // MARK: převod Apple Log → stejný formát jako vyvolaný RAW

    /* 3D LUT z kódů Apple Logu (Rec.2020): linearScale nil = hledáček (lineární Rec.709 → rameno nad 0,55 se zachovaným odstínem → sRGB,
       přesně jako RawDevelop / raw.js), jinak lineární světlo / linearScale (pro vyvolání fotky) */
    static func logCube(n: Int, linearScale: Double?) -> (Int, Data) {
        let M: [Double] = [1.6605, -0.5876, -0.0728, -0.1246, 1.1329, -0.0083, -0.0182, -0.1006, 1.1187]
        var out = [Float](repeating: 0, count: n * n * n * 4)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let d = Double(n - 1)
            let r0: Double = ClipDevelop.appleLogToLinear(Double(ri) / d)
            let g0: Double = ClipDevelop.appleLogToLinear(Double(gi) / d)
            let b0: Double = ClipDevelop.appleLogToLinear(Double(bi) / d)
            var r1: Double = M[0] * r0; r1 += M[1] * g0; r1 += M[2] * b0
            var g1: Double = M[3] * r0; g1 += M[4] * g0; g1 += M[5] * b0
            var b1: Double = M[6] * r0; b1 += M[7] * g0; b1 += M[8] * b0
            var l: [Double] = [max(r1, 0), max(g1, 0), max(b1, 0)]
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

    /// natočení telefonu z akcelerometru (WebApp): o kolik stupňů po směru hodin otočit snímek na výšku, aby byl rovně
    static var orient = 0
    /* úhel pro obraz na výšku: zadní kamery 90 (ověřené), přední se zeptá systému (RotationCoordinator dává úhel pro rovinu podle
       natočení telefonu → odečte se natočení). Na 17 Pro má přední kamera jiný (čtvercový) senzor a napevno 90 ji otočilo a převrátilo */
    static func portraitAngle(_ d: AVCaptureDevice) -> CGFloat {
        guard d.position == .front else { return 90 }
        let rc = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil)
        let lv = Int(rc.videoRotationAngleForHorizonLevelCapture.rounded())
        let a = ((lv - orient) % 360 + 360) % 360
        Ladeni.log("přední kamera: úhel pro rovinu \(lv), natočení \(orient) → na výšku \(a)")
        return CGFloat(a)
    }

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
        if d.position == .front {
            // přední: nejširší záběr (celý senzor – u 17 Pro čtverec), pak nejvíc pixelů do 4096; log, když ho má
            let dm = { (f: AVCaptureDevice.Format) in CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
            let fl = d.formats.filter { fps30($0) && Int(max(dm($0).width, dm($0).height)) <= 4096 && Int(min(dm($0).width, dm($0).height)) >= 720 }
            Ladeni.log("přední formáty: " + fl.map { "\(dm($0).width)x\(dm($0).height) fov\(Int($0.videoFieldOfView))\($0.supportedColorSpaces.contains(.appleLog) ? " log" : "")" }.joined(separator: ", "))
            let key = { (f: AVCaptureDevice.Format) in Double(f.videoFieldOfView).rounded() * 1e9 + Double(dm(f).width) * Double(dm(f).height) }
            if let f = fl.max(by: { key($0) < key($1) }) { return (f, f.supportedColorSpaces.contains(.appleLog)) }
        }
        let ok = d.formats.filter { fps30($0) && w($0) >= 1920 && w($0) <= 4096 }
        let logF = ok.filter { $0.supportedColorSpaces.contains(.appleLog) }
        if let f = logF.max(by: { w($0) < w($1) }) { return (f, true) }
        if let f = ok.filter({ w($0) == 1920 && !$0.isVideoHDRSupported }).first ?? ok.min(by: { w($0) < w($1) }) { return (f, false) }
        return nil
    }

    // MARK: ovládání (z mostu WebApp)

    func start(lens: String, zoom: Double, done: @escaping (Swift.Result<[String: Any], Error>) -> Void) {
        CameraEngine.markStarting()
        q.async {
            self.stopNow()
            self.sent = 0
            do {
                guard let (dev, lz) = self.pick(lens) else { throw QError(message: "kamera nenalezena") }
                guard let (fmt, log) = self.format(dev) else { throw QError(message: "kamera neumí video") }
                let s = AVCaptureSession()
                var cfgErr: Error?
                // celé nastavení v QCatch: špatná kombinace (formát, pixely, fps) = výjimka ObjC → chyba v hledáčku místo pádu appky
                let exc = QCatch.run {
                    do {
                        s.beginConfiguration()
                        defer { s.commitConfiguration() }
                        s.automaticallyConfiguresCaptureDeviceForWideColor = false
                        s.automaticallyConfiguresApplicationAudioSession = false // audio session řídí VolumeShutter (s mikrofonem playAndRecord)
                        s.sessionPreset = .inputPriority
                        let input = try AVCaptureDeviceInput(device: dev)
                        guard s.canAddInput(input) else { throw QError(message: "kamera je obsazená") }
                        s.addInput(input)
                        let out = AVCaptureVideoDataOutput()
                        out.alwaysDiscardsLateVideoFrames = true
                        out.setSampleBufferDelegate(self, queue: self.vq)
                        guard s.canAddOutput(out) else { throw QError(message: "nejde číst obraz") }
                        s.addOutput(out)
                        try dev.lockForConfiguration()
                        dev.activeFormat = fmt
                        if log { dev.activeColorSpace = .appleLog } else if fmt.supportedColorSpaces.contains(.sRGB) { dev.activeColorSpace = .sRGB }
                        if fmt.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                            dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        }
                        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                        if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                        dev.videoZoomFactor = max(dev.minAvailableVideoZoomFactor, min(dev.activeFormat.videoMaxZoomFactor, zoom))
                        dev.unlockForConfiguration()
                        // pixely až po nastavení formátu (10 bit jen u formátu, který ho má) a jen z nabídky výstupu
                        let avail = out.availableVideoPixelFormatTypes
                        let want: [OSType] = log ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
                                                 : [kCVPixelFormatType_32BGRA]
                        if let pf = want.first(where: { avail.contains($0) }) {
                            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pf]
                        }
                        if #available(iOS 18.0, *) { self.addControls(s) }
                        if let c = out.connection(with: .video) {
                            let ang = Self.portraitAngle(dev)
                            if c.isVideoRotationAngleSupported(ang) { c.videoRotationAngle = ang }
                            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false } // přední zrcadlí web sám
                        }
                    } catch { cfgErr = error }
                }
                if let exc { throw QError(message: exc) }
                if let cfgErr { throw cfgErr }
                self.session = s; self.device = dev; self.log = log; self.lens = lens; self.lensZoom = lz
                self.videoOut = s.outputs.compactMap { $0 as? AVCaptureVideoDataOutput }.first
                let dm = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                self.size = CGSize(width: Int(min(dm.width, dm.height)), height: Int(max(dm.width, dm.height)))
                if let e2 = QCatch.run({ s.startRunning() }) { throw QError(message: e2) }
                guard s.isRunning else { throw QError(message: "kamera se nespustila") }
                if self.manIso != nil || self.manDur != nil { self.q.asyncAfter(deadline: .now() + 0.6) { self.applyExposure() } }
                if self.wantAudio { self.applyAudio() }
                Ladeni.log("kamera start \(lens) \(dev.localizedName) \(dm.width)x\(dm.height) log=\(log) lensZoom=\(String(format: "%.2f", lz)) pix=\(self.videoOut?.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] ?? "?")")
                done(.success(["log": log, "lens": lens, "lensZoom": lz, "w": Int(self.size.width), "h": Int(self.size.height),
                               "maxZoom": Double(min(dev.activeFormat.videoMaxZoomFactor, 10)), "torch": dev.hasTorch,
                               "label": dev.localizedName]))
            } catch { Ladeni.log("kamera start CHYBA \(lens): \(error.localizedDescription)"); self.stopNow(); done(.failure(error)) }
        }
    }

    // Synchronně: RawCapture / ClipCapture si hned potom otevřou vlastní session
    func stop() { q.sync { self.stopNow() }; CameraEngine.markOk() }
    private func stopNow() {
        vq.sync { if let r = self.rec { self.rec = nil; r.writer.cancelWriting(); r.done?(nil, "kamera se zastavila") } }
        session?.stopRunning(); session = nil; device = nil; videoOut = nil; paused = false; audioOut = nil; audioIn = nil
    }

    // Klip z běžící kamery: HEVC 1080p z těch samých snímků, které vidí hledáček. started = první zapsaný snímek.
    // done se nikdy nevolá na hlavním vlákně → volající nesmí hned volat stop() (ten čeká na frontu kamery), jen přes main.async
    func record(seconds: Double, started: @escaping () -> Void, done: @escaping (Swift.Result<(URL, Bool, Double), Error>) -> Void) {
        q.async {
            guard self.session?.isRunning == true, let out = self.videoOut else { return done(.failure(QError(message: "kamera neběží"))) }
            try? FileManager.default.createDirectory(at: RawCapture.dir, withIntermediateDirectories: true)
            let url = RawCapture.dir.appendingPathComponent(UUID().uuidString + "-src.mov")
            let log = self.log, lz = self.lensZoom, size = self.size
            var made: Rec?
            var err: String?
            let exc = QCatch.run {
                _ = out
                let k = min(1, 1080 / max(1, min(size.width, size.height)))
                var st: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
                                         AVVideoWidthKey: Int((size.width * k / 2).rounded()) * 2,
                                         AVVideoHeightKey: Int((size.height * k / 2).rounded()) * 2]
                guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { err = "nejde zapisovat"; return }
                // 10 bitů (log potřebuje jemné stupně); když to kodér odmítne, výchozí profil
                let main10: [String: Any] = [AVVideoAverageBitRateKey: 24_000_000, AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String]
                var st10 = st
                st10[AVVideoCompressionPropertiesKey] = main10
                if w.canApply(outputSettings: st10, forMediaType: .video) { st = st10 }
                guard w.canApply(outputSettings: st, forMediaType: .video) else { err = "nastavení klipu nejde použít"; return }
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: st)
                i.expectsMediaDataInRealTime = true
                guard w.canAdd(i) else { err = "klip nejde přidat"; return }
                w.add(i)
                // zvuk z mikrofonu (jen když je v session – režim KLIP a povolený mikrofon); AAC
                var ai: AVAssetWriterInput?
                if let ao = self.audioOut {
                    let rs = ao.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
                    let aset: [String: Any] = rs ?? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000, AVEncoderBitRateKey: 128000]
                    if w.canApply(outputSettings: aset, forMediaType: .audio) {
                        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: aset)
                        a.expectsMediaDataInRealTime = true
                        if w.canAdd(a) { w.add(a); ai = a }
                    }
                }
                guard w.startWriting() else { err = w.error?.localizedDescription ?? "zápis nezačal"; return }
                made = Rec(writer: w, input: i, url: url, dur: seconds)
                made?.audio = ai
            }
            guard exc == nil, err == nil, let r = made else { Ladeni.log("klip ze session NEJDE: \(exc ?? err ?? "?")"); return done(.failure(QError(message: exc ?? err ?? "klip nejde natočit"))) }
            Ladeni.log("klip ze session start zvuk=\(r.audio != nil) \(Int(size.width))x\(Int(size.height)) → \(r.input.outputSettings?[AVVideoWidthKey] ?? "?")x\(r.input.outputSettings?[AVVideoHeightKey] ?? "?")")
            r.started = started
            r.done = { u, e in
                if let u { done(.success((u, log, lz))) } else { done(.failure(QError(message: e ?? "klip se nenatočil"))) }
            }
            self.vq.sync { self.rec = r }
            // pojistka: kdyby snímky přestaly chodit
            self.q.asyncAfter(deadline: .now() + seconds + 4) { self.vq.async { if self.rec === r { self.finishRec(r) } } }
        }
    }
    // jen na frontě vq
    private func finishRec(_ r: Rec) {
        rec = nil
        guard r.t0 != nil, r.writer.status == .writing else {
            let e = r.writer.error?.localizedDescription ?? "kamera neposlala snímky"
            r.writer.cancelWriting(); r.done?(nil, e); return
        }
        _ = QCatch.run { r.input.markAsFinished(); r.audio?.markAsFinished() }
        r.writer.finishWriting { Ladeni.log("klip ze session konec stav=\(r.writer.status.rawValue) \(r.writer.error?.localizedDescription ?? "ok")"); r.done?(r.writer.status == .completed ? r.url : nil, r.writer.error?.localizedDescription) }
    }

    var isOn: Bool { q.sync { session != nil } }

    // mimo foťák: session se zastaví, ale zůstane nastavená (návrat = jen startRunning, žádné nové hledání formátu)
    private var paused = false
    func pause(_ off: Bool) {
        q.async {
            guard let s = self.session else { return }
            if off {
                guard !self.paused, self.vq.sync(execute: { self.rec == nil && self.stillWait == nil }) else { return }
                s.stopRunning(); self.paused = true; Ladeni.log("kamera pauza (mimo foťák)")
            } else if self.paused {
                self.paused = false
                if let e = QCatch.run({ s.startRunning() }) { Ladeni.log("kamera po pauze CHYBA \(e)") }
                Ladeni.log("kamera po pauze běží=\(s.isRunning)")
            }
        }
    }

    // jen na frontě q: AUTO, nebo ruční ISO / čas (chybějící hodnota = stejná expozice jako teď)
    private func applyExposure() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        if manIso == nil && manDur == nil {
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            Ladeni.log("expozice AUTO"); return
        }
        guard d.isExposureModeSupported(.custom) else { return }
        let f = d.activeFormat
        let maxDur = min(f.maxExposureDuration.seconds, 1.0 / 30) // hledáček jede 30 snímků/s → nejdelší čas 1/30
        let curIso = Double(d.iso), curDur = max(d.exposureDuration.seconds, 1e-6), ev = curIso * curDur
        var dur = manDur ?? (manIso.map { ev / Double($0) } ?? curDur)
        dur = min(max(dur, f.minExposureDuration.seconds), maxDur)
        var iso = Double(manIso ?? Float(ev / dur))
        iso = min(max(iso, Double(f.minISO)), Double(f.maxISO))
        d.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000), iso: Float(iso), completionHandler: nil)
        Ladeni.log("expozice ručně iso=\(Int(iso)) čas=1/\(Int((1 / dur).rounded()))")
        onCtl?("expo", "[\(Int(iso.rounded())), \(dur)]")
    }
    static func durLabel(_ s: Double) -> String { s >= 0.3 ? String(format: "%.1f s", s) : "1/\(Int((1 / s).rounded()))" }

    func setZoom(_ z: Double) {
        q.async { guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(d.activeFormat.videoMaxZoomFactor, z)); d.unlockForConfiguration() }
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
            if d.isExposurePointOfInterestSupported, self.manIso == nil, self.manDur == nil { d.exposurePointOfInterest = p; if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure } }
            d.unlockForConfiguration()
            // po zaostření zpět na průběžné ostření (až se scéna změní)
            self.q.asyncAfter(deadline: .now() + 3) { guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }; d.unlockForConfiguration() }
        }
    }

    // MARK: snímky

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput { // zvuk jen do běžícího klipu, od prvního snímku obrazu (stejné hodiny session)
            if let r = rec, let a = r.audio, let t0 = r.t0, r.writer.status == .writing, a.isReadyForMoreMediaData,
               CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), t0) >= 0 { _ = QCatch.run { _ = a.append(sb) } }
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let img = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
        if let w = stillWait { stillWait = nil; w(img) }
        if let r = rec {
            let ts = CMSampleBufferGetPresentationTimeStamp(sb)
            if r.t0 == nil { r.t0 = ts; r.writer.startSession(atSourceTime: ts); r.started?(); r.started = nil }
            if r.writer.status == .writing, r.input.isReadyForMoreMediaData { _ = QCatch.run { _ = r.input.append(sb) } }
            if r.writer.status != .writing || CMTimeGetSeconds(CMTimeSubtract(ts, r.t0 ?? ts)) >= r.dur { finishRec(r) }
        }
        sent += 1
        if sent % 10 == 0, let d = device { lastISO = d.iso }
        if sent % 300 == 1, let d = device { // jednou za ~10 s: v jakém světle kamera jede
            Ladeni.log("snímky \(sent) iso=\(Int(d.iso)) čas=1/\(Int((1 / max(d.exposureDuration.seconds, 0.0001)).rounded())) zoom=\(String(format: "%.2f", Double(d.videoZoomFactor))) posláno=\(framesOut) převod=\(String(format: "%.1f", pktMs)) ms")
        }
        if sent == 90 { CameraEngine.markOk() } // ~3 s snímků bez pádu = kamera appky v pořádku
        let now = CACurrentMediaTime()
        guard onFrame != nil, canSend(), now - lastFrame > 1 / 31 else { return }
        lastFrame = now
        var pkt: Data?
        if QCatch.run({ pkt = self.packet(img) }) != nil { return }
        guard let pkt else { return }
        pktMs = pktMs * 0.9 + (CACurrentMediaTime() - now) * 100
        framesOut += 1
        onFrame?(pkt)
    }

    // pojistka proti pádu: když appka spadne během startu kamery, příští spuštění jede postaru (kamera z WebKitu) – do dalšího buildu
    static let buildKey = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    static func markStarting() { UserDefaults.standard.set(buildKey, forKey: "ncamPending") }
    static func markOk() { UserDefaults.standard.removeObject(forKey: "ncamPending") }
    // volá se jednou při startu appky: vrátí true, když kamera appky v tomhle buildu dřív spadla
    static func crashedBefore() -> Bool {
        let d = UserDefaults.standard
        if d.string(forKey: "ncamPending") == buildKey { d.removeObject(forKey: "ncamPending"); d.set(buildKey, forKey: "ncamOff") }
        return d.string(forKey: "ncamOff") == buildKey
    }

    private func packet(_ img: CIImage) -> Data? {
        let e = img.extent, k = min(1, 1600 / max(e.width, e.height))
        var v = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        if log { viewCube.setValue(v, forKey: kCIInputImageKey); v = viewCube.outputImage ?? v }
        let W = Int((e.width * k).rounded(.down)), H = Int((e.height * k).rounded(.down))
        guard W > 0, H > 0 else { return nil }
        var px = [UInt8](repeating: 255, count: W * H * 4)
        px.withUnsafeMutableBytes { p in ctx.render(v, toBitmap: p.baseAddress!, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8, colorSpace: nil) }
        guard let jpg = Self.jpeg(&px, w: W, h: H, q: 0.7) else { return nil }
        let meta: [String: Any] = ["w": W, "h": H, "log": log, "lens": lens]
        let mj = (try? JSONSerialization.data(withJSONObject: meta)) ?? Data("{}".utf8)
        var pkt = Data()
        var n = UInt32(2 + mj.count + jpg.count).bigEndian, m = UInt16(mj.count).bigEndian
        pkt.append(Data(bytes: &n, count: 4)); pkt.append(Data(bytes: &m, count: 2)); pkt.append(mj); pkt.append(jpg)
        return pkt
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
                    // ladění: snímek z kamery tak, jak přišel (16bit TIFF, kódy Apple Logu bez převodu barev)
                    let st = Ladeni.stamp()
                    if log { try? Self.dbgCtx.writeTIFFRepresentation(of: src, to: Ladeni.url("log-\(st).tiff"), format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.itur_2020)!) }
                    // log se převede na světlo až v RawDevelop ve float (přes CIColorCube se stíny ztrácely v 8 bitech = černé díry a barevné fleky)
                    let o = log ? try RawDevelop.develop(image: src, fixedEV: 0, logInput: true)
                                : try RawDevelop.develop(image: src.applyingFilter("CISRGBToneCurveToLinear"), fixedEV: 0)
                    let id = UUID().uuidString
                    try? FileManager.default.createDirectory(at: RawCapture.dir, withIntermediateDirectories: true)
                    var res = RawCapture.Result(label: log ? "LOG" : "VIDEO", lensZoom: lz, ev: o.ev)
                    Ladeni.json("log-\(st).json", ["log": log, "ev": o.ev, "lensZoom": lz, "iso": Double(self.currentISO)])
                    if log { Ladeni.toPhotos("log-\(st).tiff", as: "qamera-log-\(st)-ev\(String(format: "%.2f", Double(o.ev)))-iso\(Int(self.currentISO)).tiff") }
                    try o.jpg.write(to: RawCapture.dir.appendingPathComponent(id + ".jpg")); res.files["jpg"] = id + ".jpg"
                    if let hl = o.hl { try hl.write(to: RawCapture.dir.appendingPathComponent(id + "-hl.png")); res.files["hl"] = id + "-hl.png" }
                    Ladeni.log("fotka z logu ev=\(String(format: "%.2f", Double(o.ev))) iso=\(Int(self.currentISO)) jpg=\(o.jpg.count / 1024) kB")
                    done(.success(res))
                } catch { Ladeni.log("fotka z logu CHYBA: \(error.localizedDescription)"); done(.failure(error)) }
            }
        }
    }
}

// MARK: boční tlačítko (iOS 18+): přejetí = film, ve výběru ovládání i EV
@available(iOS 18.0, *)
extension CameraEngine: AVCaptureSessionControlsDelegate {
    fileprivate static let evStops: [Float] = (-9...9).map { Float($0) / 3 }
    func addControls(_ s: AVCaptureSession) {
        guard s.supportsControls else { return }
        for c in s.controls { s.removeControl(c) }
        s.setControlsDelegate(self, queue: .main)
        var objs: [AnyObject] = []
        if !ctlFilms.isEmpty {
            let p = AVCaptureIndexPicker("Film", symbolName: "film", localizedIndexTitles: ctlFilms)
            p.selectedIndex = min(max(0, ctlFilm), ctlFilms.count - 1)
            p.setActionQueue(.main) { [weak self] i in
                guard let self, i != self.ctlFilm else { return }
                self.ctlFilm = i; self.onCtl?("film", i)
            }
            if s.canAddControl(p) { s.addControl(p); objs.append(p) }
        }
        if ctlLenses.count > 1 {
            let l = AVCaptureIndexPicker("Objektiv", symbolName: "camera.aperture", localizedIndexTitles: ctlLenses)
            l.selectedIndex = min(max(0, ctlLens), ctlLenses.count - 1)
            l.setActionQueue(.main) { [weak self] i in
                guard let self, i != self.ctlLens else { return }
                self.ctlLens = i; self.onCtl?("lens", i)
            }
            if s.canAddControl(l) { s.addControl(l); objs.append(l) }
        }
        let e = AVCaptureSlider("EV", symbolName: "plusminus.circle", values: Self.evStops)
        e.value = Float((ctlEv * 3).rounded() / 3)
        e.setActionQueue(.main) { [weak self] v in
            guard let self, abs(Double(v) - self.ctlEv) > 0.01 else { return }
            self.ctlEv = Double(v); self.onCtl?("ev", Double(v))
        }
        if s.canAddControl(e) { s.addControl(e); objs.append(e) }
        // ruční ISO a čas (třetiny clony), první položka AUTO
        if let d = s.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first, d.isExposureModeSupported(.custom) {
            let f = d.activeFormat
            isoTitles = Self.isoStops.filter { $0 >= f.minISO && $0 <= f.maxISO }
            let maxDur = min(f.maxExposureDuration.seconds, 1.0 / 30)
            durTitles = Self.durStops.filter { $0 >= f.minExposureDuration.seconds && $0 <= maxDur + 1e-6 }
            let ip = AVCaptureIndexPicker("ISO", symbolName: "camera.metering.matrix", localizedIndexTitles: ["AUTO"] + isoTitles.map { String(Int($0)) })
            if let m = manIso, let i = isoTitles.firstIndex(where: { abs($0 - m) < 1 }) { ip.selectedIndex = i + 1 }
            ip.setActionQueue(.main) { [weak self] i in
                guard let self else { return }
                let v: Float? = i == 0 ? nil : self.isoTitles[i - 1]
                guard v != self.manIso else { return }
                self.manIso = v; self.q.async { self.applyExposure() }
                self.onCtl?("iso", Int(v ?? 0))
            }
            if s.canAddControl(ip) { s.addControl(ip); objs.append(ip) }
            let tp = AVCaptureIndexPicker("Čas", symbolName: "timer", localizedIndexTitles: ["AUTO"] + durTitles.map { Self.durLabel($0) })
            if let m = manDur, let i = durTitles.firstIndex(where: { abs($0 / m - 1) < 0.02 }) { tp.selectedIndex = i + 1 }
            tp.setActionQueue(.main) { [weak self] i in
                guard let self else { return }
                let v: Double? = i == 0 ? nil : self.durTitles[i - 1]
                guard v != self.manDur else { return }
                self.manDur = v; self.q.async { self.applyExposure() }
                self.onCtl?("dur", v ?? 0)
            }
            if s.canAddControl(tp) { s.addControl(tp); objs.append(tp) }
        }
        let st = AVCaptureSlider("Síla filmu", symbolName: "circle.lefthalf.filled", in: 0...100, step: 5)
        st.value = Float(ctlStr)
        st.setActionQueue(.main) { [weak self] v in
            guard let self, abs(Double(v) - self.ctlStr) > 0.5 else { return }
            self.ctlStr = Double(v); self.onCtl?("str", Double(v))
        }
        if s.canAddControl(st) { s.addControl(st); objs.append(st) }
        ctlObjs = objs
        Ladeni.log("boční tlačítko: \(objs.count) ovládání (max \(s.maxControlsCount))")
    }
    fileprivate static let isoStops: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]
    fileprivate static let durStops: [Double] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30].map { 1 / $0 }
    func syncCtl() {
        for o in ctlObjs {
            if let p = o as? AVCaptureIndexPicker, p.localizedTitle == "Film", ctlFilm >= 0, ctlFilm < p.localizedIndexTitles.count, p.selectedIndex != ctlFilm { p.selectedIndex = ctlFilm }
            if let p = o as? AVCaptureIndexPicker, p.localizedTitle == "Objektiv", ctlLens >= 0, ctlLens < p.localizedIndexTitles.count, p.selectedIndex != ctlLens { p.selectedIndex = ctlLens }
            if let e = o as? AVCaptureSlider, e.localizedTitle == "EV", abs(Double(e.value) - ctlEv) > 0.01 { e.value = Float(ctlEv) }
            if let e = o as? AVCaptureSlider, e.localizedTitle == "Síla filmu", abs(Double(e.value) - ctlStr) > 0.5 { e.value = Float(ctlStr) }
        }
    }
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
