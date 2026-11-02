import AVFoundation
import Photos
import UIKit

// Kamera přes AVFoundation: fyzické objektivy, ruční ISO a čas, RAW / ProRAW, uložení do Fotek.
final class CameraModel: NSObject, ObservableObject {
    struct Lens: Identifiable, Hashable {
        let id: String
        let label: String
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "qamera.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var devices: [String: AVCaptureDevice] = [:]
    private var observers: [NSKeyValueObservation] = []
    private var areaObserver: NSObjectProtocol?
    private var inflight: [Int64: PhotoCapture] = [:]

    @Published var denied = false
    @Published var lenses: [Lens] = []
    @Published var lensID = ""
    @Published var manual = false
    @Published var iso: Float = 100
    @Published var shutter: Double = 1.0 / 60
    @Published var ev: Float = 0
    @Published var isoRange: ClosedRange<Float> = 25...3200
    @Published var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 3)
    @Published var liveISO: Float = 0
    @Published var liveShutter: Double = 0
    @Published var raw = false
    @Published var rawKind = ""
    @Published var capturing = false
    @Published var lastPhoto: UIImage?
    @Published var toast: String?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { self.configure() } else { DispatchQueue.main.async { self.denied = true } }
            }
        default:
            denied = true
        }
    }

    private func configure() {
        queue.async {
            let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
            let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
            guard let wide = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? found.first else {
                DispatchQueue.main.async { self.toast = "Kamera nenalezena" }
                return
            }
            var lenses: [Lens] = []
            for d in found {
                self.devices[d.uniqueID] = d
                lenses.append(Lens(id: d.uniqueID, label: Self.zoomLabel(d, wide: wide)))
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            self.photoOutput.maxPhotoQualityPrioritization = .quality
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.lenses = lenses }
            self.use(wide)
            self.session.startRunning()
        }
    }

    // Popisek objektivu podle zorného úhlu vůči širokému (0,5× / 1× / 3× …)
    private static func zoomLabel(_ d: AVCaptureDevice, wide: AVCaptureDevice) -> String {
        let w = tan(Double(wide.activeFormat.videoFieldOfView) * .pi / 360)
        let t = tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360)
        let z = w / max(t, 0.0001)
        if z < 0.8 { return "0,5×" }
        if z < 1.3 { return "1×" }
        return "\(Int(z.rounded()))×"
    }

    func selectLens(_ id: String) {
        queue.async {
            guard let d = self.devices[id], d != self.device else { return }
            self.use(d)
        }
    }

    // Běží na queue
    private func use(_ d: AVCaptureDevice) {
        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        guard let ni = try? AVCaptureDeviceInput(device: d), session.canAddInput(ni) else {
            if let old = input { session.addInput(old) }
            session.commitConfiguration()
            return
        }
        session.addInput(ni)
        input = ni
        device = d
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }
        let dims = d.activeFormat.supportedMaxPhotoDimensions.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        if let dims { photoOutput.maxPhotoDimensions = dims }
        session.commitConfiguration()

        if (try? d.lockForConfiguration()) != nil {
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if d.isSmoothAutoFocusSupported { d.isSmoothAutoFocusEnabled = false }
            d.isSubjectAreaChangeMonitoringEnabled = false
            d.unlockForConfiguration()
        }
        if let old = areaObserver { NotificationCenter.default.removeObserver(old) }
        areaObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                                                              object: d, queue: nil) { [weak self] _ in
            self?.recenterFocus()
        }
        observers = [
            d.observe(\.iso, options: [.initial, .new]) { [weak self] dev, _ in
                let v = dev.iso
                DispatchQueue.main.async { self?.liveISO = v }
            },
            d.observe(\.exposureDuration, options: [.initial, .new]) { [weak self] dev, _ in
                let v = dev.exposureDuration.seconds
                DispatchQueue.main.async { self?.liveShutter = v }
            },
        ]
        let isoR = d.activeFormat.minISO...d.activeFormat.maxISO
        let shR = d.activeFormat.minExposureDuration.seconds...d.activeFormat.maxExposureDuration.seconds
        let kind = rawFormat().map { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) ? "ProRAW" : "RAW" } ?? ""
        DispatchQueue.main.async {
            self.lensID = d.uniqueID
            self.isoRange = isoR
            self.shutterRange = shR
            self.iso = min(max(self.iso, isoR.lowerBound), isoR.upperBound)
            self.shutter = min(max(self.shutter, shR.lowerBound), shR.upperBound)
            self.rawKind = kind
            if kind.isEmpty { self.raw = false }
            self.applyExposure()
        }
    }

    private func rawFormat() -> OSType? {
        let types = photoOutput.availableRawPhotoPixelFormatTypes
        return types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
            ?? types.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
    }

    // Volá se z hlavního vlákna (posuvníky)
    func applyExposure() {
        let manual = self.manual, iso = self.iso, sh = self.shutter, ev = self.ev
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if manual, d.isExposureModeSupported(.custom) {
                let f = d.activeFormat
                let isoC = min(max(iso, f.minISO), f.maxISO)
                let s = min(max(sh, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
                d.setExposureModeCustom(duration: CMTime(seconds: s, preferredTimescale: 1_000_000), iso: isoC, completionHandler: nil)
            } else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
            }
            d.unlockForConfiguration()
        }
    }

    // p = bod v souřadnicích kamery (0…1)
    func focus(at p: CGPoint) {
        let manual = self.manual
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            // Průběžné ostření na ťuknutý bod (jednorázové .autoFocus zamklo ostrost napořád)
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = p
                d.focusMode = .continuousAutoFocus
            }
            d.isSubjectAreaChangeMonitoringEnabled = true
            if !manual, d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = p
                d.exposureMode = .continuousAutoExposure
            }
            d.unlockForConfiguration()
        }
    }

    // Po změně scény (pohnutí telefonem) se ostření vrátí doprostřed, jako v Fotoaparátu
    private func recenterFocus() {
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            d.isSubjectAreaChangeMonitoringEnabled = false
            d.unlockForConfiguration()
        }
    }

    func capture() {
        guard !capturing else { return }
        capturing = true
        let wantRaw = raw
        queue.async {
            let settings: AVCapturePhotoSettings
            let codec: [String: Any] = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? [AVVideoCodecKey: AVVideoCodecType.hevc] : [AVVideoCodecKey: AVVideoCodecType.jpeg]
            if wantRaw, let fmt = self.rawFormat() {
                settings = AVCapturePhotoSettings(rawPixelFormatType: fmt, processedFormat: codec)
            } else {
                settings = AVCapturePhotoSettings(format: codec)
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if let c = self.photoOutput.connection(with: .video), c.isVideoRotationAngleSupported(90) {
                c.videoRotationAngle = 90
            }
            let id = settings.uniqueID
            let pc = PhotoCapture { result in
                DispatchQueue.main.async {
                    self.inflight[id] = nil
                    self.capturing = false
                    switch result {
                    case .success(let img):
                        self.lastPhoto = img
                        self.toast = wantRaw ? "Uloženo do Fotek (+\(self.rawKind))" : "Uloženo do Fotek"
                    case .failure(let e):
                        self.toast = "Nepovedlo se: \(e.localizedDescription)"
                    }
                }
            }
            DispatchQueue.main.async { self.inflight[id] = pc }
            self.photoOutput.capturePhoto(with: settings, delegate: pc)
        }
    }
}

struct QError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Delegát jednoho snímku: posbírá zpracovanou fotku (HEIC/JPEG) a případně RAW, uloží do Fotek
final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private var processed: Data?
    private var raw: Data?
    private let done: (Result<UIImage?, Error>) -> Void

    init(done: @escaping (Result<UIImage?, Error>) -> Void) {
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { raw = data } else { processed = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { done(.failure(error)); return }
        guard processed != nil || raw != nil else { done(.failure(QError(message: "prázdný snímek"))); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.done(.failure(QError(message: "bez přístupu k Fotkám")))
                return
            }
            var rawURL: URL?
            if let r = self.raw {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
                if (try? r.write(to: url)) != nil { rawURL = url }
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opt = PHAssetResourceCreationOptions()
                opt.shouldMoveFile = true
                if let p = self.processed {
                    req.addResource(with: .photo, data: p, options: nil)
                    if let u = rawURL { req.addResource(with: .alternatePhoto, fileURL: u, options: opt) }
                } else if let u = rawURL {
                    req.addResource(with: .photo, fileURL: u, options: opt)
                }
            }) { ok, err in
                if ok {
                    let thumb = self.processed.flatMap { UIImage(data: $0) }.flatMap { img in
                        img.preparingThumbnail(of: CGSize(width: 160, height: 160 * img.size.height / max(img.size.width, 1)))
                    }
                    self.done(.success(thumb))
                } else {
                    self.done(.failure(err ?? QError(message: "uložení selhalo")))
                }
            }
        }
    }
}
