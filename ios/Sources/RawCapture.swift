import AVFoundation
import UIKit

// Nativní RAW ze spouště webové Qamery: web pustí svou kameru (getUserMedia), tady se na chvíli spustí
// AVCaptureSession, vyfotí Apple ProRAW (jinak Bayer RAW) ~12 Mpx a DNG uloží do dočasné složky,
// odkud si ho web stáhne přes LocalServer (/__cap/…) a vyvolá v raw.js stejně jako import RAW.
final class RawCapture: NSObject {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qcap", isDirectory: true)

    private let queue = DispatchQueue(label: "qamera.raw")
    private var session: AVCaptureSession?
    private var delegate: RawDelegate?

    struct Result {
        let file: String
        let label: String
        let lensZoom: Double
    }

    override init() {
        super.init()
        try? FileManager.default.removeItem(at: Self.dir)
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
    }

    // zoom = optický zoom, který měl webový hledáček (1 = hlavní objektiv), ultra = ultraširokáč
    func capture(zoom: Double, ultra: Bool, flash: Bool, done: @escaping (Swift.Result<Result, Error>) -> Void) {
        queue.async {
            // Web právě pustil kameru; WebKit ji uvolní během pár ms
            Thread.sleep(forTimeInterval: 0.15)
            do {
                try self.run(zoom: zoom, ultra: ultra, flash: flash, done: done)
            } catch {
                self.stop()
                done(.failure(error))
            }
        }
    }

    private func pickDevice(zoom: Double, ultra: Bool) -> (AVCaptureDevice, Double)? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        guard let wide = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return nil }
        let fov = { (d: AVCaptureDevice) in tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360) }
        let factor = { (d: AVCaptureDevice) in fov(wide) / max(fov(d), 0.0001) }
        if ultra, let u = found.first(where: { $0.deviceType == .builtInUltraWideCamera }) { return (u, factor(u)) }
        if let t = found.first(where: { $0.deviceType == .builtInTelephotoCamera }), zoom >= factor(t) * 0.95 { return (t, factor(t)) }
        return (wide, 1)
    }

    private func run(zoom: Double, ultra: Bool, flash: Bool, done: @escaping (Swift.Result<Result, Error>) -> Void) throws {
        guard let picked = pickDevice(zoom: zoom, ultra: ultra) else { throw QError(message: "kamera nenalezena") }
        let (device, lensZoom) = picked
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw QError(message: "kamera je obsazená") }
        s.addInput(input)
        let out = AVCapturePhotoOutput()
        guard s.canAddOutput(out) else { throw QError(message: "nejde fotit") }
        s.addOutput(out)
        if out.isAppleProRAWSupported { out.isAppleProRAWEnabled = true }
        // ~12 Mpx: 48 Mpx DNG by WebView při vyvolání neudržel v paměti
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        let target = 12_500_000
        if let d = dims.filter({ Int($0.width) * Int($0.height) <= target }).max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) })
            ?? dims.min(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            out.maxPhotoDimensions = d
        }
        s.commitConfiguration()

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

        let types = out.availableRawPhotoPixelFormatTypes
        guard let fmt = types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
            ?? types.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) else {
            throw QError(message: "tenhle objektiv RAW neumí")
        }
        let label = AVCapturePhotoOutput.isAppleProRAWPixelFormat(fmt) ? "ProRAW" : "RAW"
        let settings = AVCapturePhotoSettings(rawPixelFormatType: fmt)
        settings.maxPhotoDimensions = out.maxPhotoDimensions
        if flash, out.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        if let c = out.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }

        let del = RawDelegate { [weak self] result in
            guard let self else { return }
            self.queue.async {
                self.stop()
                switch result {
                case .success(let data):
                    let name = UUID().uuidString + ".dng"
                    do {
                        try data.write(to: Self.dir.appendingPathComponent(name))
                        done(.success(Result(file: name, label: label, lensZoom: lensZoom)))
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

    // Běží na queue: kamera se hned vrátí webu
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
    private var data: Data?
    private let done: (Swift.Result<Data, Error>) -> Void

    init(done: @escaping (Swift.Result<Data, Error>) -> Void) {
        self.done = done
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil, photo.isRawPhoto { data = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { return done(.failure(error)) }
        if let data { done(.success(data)) } else { done(.failure(QError(message: "prázdný snímek"))) }
    }
}
