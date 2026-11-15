import UIKit
import Metal
import QuartzCore
import CoreImage

/* Hledáček v Metalu: snímky kamery appky (Apple Log) jdou stejným filmovým shaderem jako fotka (FilmShader.metal = přepis
   shaderu webu, hodnoty počítá web) a kreslí se do vrstvy POD průhledným WKWebView přesně na místo #vf. Web posílá obdélník
   hledáčku a velikost v pixelech, hodnoty shaderu + LUT + křivku a zoom / zrcadlení / rozmazání; JPEG snímky do webu jdou dál,
   ale jen ~8/s (měření, RAW na jas hledáčku, hlídač). Když se cokoli nepovede, web kreslí sám. */
final class MetalViewfinder: UIView {
    static weak var current: MetalViewfinder?
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var ml: CAMetalLayer { layer as! CAMetalLayer }
    private let fs = FilmShader()
    private let blurV = UIVisualEffectView(effect: nil)
    private let rq = DispatchQueue(label: "qamera.mvf", qos: .userInteractive)
    var onState: ((Bool, String?) -> Void)?   // → web: první snímek nakreslen / chyba

    // stav: zapisuje hlavní vlákno, čte fronta kamery a kreslení
    private let lock = NSLock()
    private var on = false
    private var px = CGSize.zero
    private var mirror = false
    private var zoom: Float = 1
    private var hasUni = false
    private var busy = false
    private var confirmed = false
    private let t0 = CACurrentMediaTime()
    private var frameN = 0          // jen na rq
    private var errs = 0            // jen na rq
    private var ms = 0.0            // jen na rq

    var live: Bool { lock.lock(); defer { lock.unlock() }; return on && hasUni && confirmed }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = .black
        clipsToBounds = true
        ml.device = fs?.gpu.dev
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = true
        ml.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        ml.isOpaque = true
        ml.maximumDrawableCount = 3
        ml.cornerCurve = .continuous
        blurV.frame = bounds
        blurV.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurV)
        MetalViewfinder.current = self
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: z mostu (hlavní vlákno)

    /// {op:'vf', on, x, y, w, h, pw, ph, r, mir, zoom, blur}
    func configure(_ m: [String: Any]) {
        let want = (m["on"] as? Bool) ?? false
        if fs == nil { if want { onState?(false, "filmový shader v Metalu se nepodařilo připravit") }; return }
        let r = CGRect(x: (m["x"] as? Double) ?? 0, y: (m["y"] as? Double) ?? 0, width: (m["w"] as? Double) ?? 0, height: (m["h"] as? Double) ?? 0)
        if r.width > 2, r.height > 2, frame != r { frame = r }
        layer.cornerRadius = CGFloat((m["r"] as? Double) ?? 22)
        // velikost v pixelech určuje web (stejná jako jeho plátno → stejné zrno); jinak displej, nejvýš 1600 px
        var p = CGSize(width: (m["pw"] as? Double) ?? 0, height: (m["ph"] as? Double) ?? 0)
        if p.width < 2 { let sc = traitCollection.displayScale, k = min(1, 1600 / max(r.width * sc, r.height * sc, 1)); p = CGSize(width: (r.width * sc * k).rounded(), height: (r.height * sc * k).rounded()) }
        if p.width > 2, ml.drawableSize != p { ml.drawableSize = p }
        let blur = (m["blur"] as? Bool) ?? false
        if (blurV.effect != nil) != blur {
            UIView.animate(withDuration: blur ? 0.25 : 0.45) { self.blurV.effect = blur ? UIBlurEffect(style: .dark) : nil }
        }
        lock.lock()
        if !want { confirmed = false }
        px = p; on = want; mirror = (m["mir"] as? Bool) ?? false; zoom = Float(max(1, (m["zoom"] as? Double) ?? 1))
        lock.unlock()
        if !want { isHidden = true }
    }

    /// {op:'uni', u, lut, curve} – hodnoty shaderu z webu
    func setUni(_ m: [String: Any]) {
        guard let fs else { return }
        rq.async {
            fs.configure(m)
            self.lock.lock(); self.hasUni = fs.ready; self.lock.unlock()
        }
    }

    // MARK: snímky (fronta kamery)

    /// src = snímek z kamery appky (kódy Apple Logu, na výšku); vrací hned, kreslí se na vlastní frontě (když nestíhá, snímek vypadne)
    func frame(_ src: CIImage, log: Bool) {
        guard log, let fs else { return }
        lock.lock()
        guard on, hasUni, !busy, px.width > 2 else { lock.unlock(); return }
        busy = true
        let mir = mirror, z = zoom
        lock.unlock()
        rq.async {
            let tS = CACurrentMediaTime()
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            var fail: String?
            let exc = QCatch.run {
                guard let drawable = self.ml.nextDrawable(), let cb = fs.gpu.queue.makeCommandBuffer() else { fail = "není plocha"; return }
                do { try fs.encode(src, log: true, mirror: mir, zoom: z, time: Float(tS - self.t0), maxSide: 1280, out: drawable.texture, cb: cb) }
                catch { fail = error.localizedDescription; return }
                cb.present(drawable)
                cb.commit()
            }
            if let m = exc ?? fail {
                self.errs += 1
                if self.errs == 1 || self.errs % 100 == 0 { Ladeni.log("metal hledáček CHYBA \(self.errs)×: \(m)") }
                if self.errs == 30 { DispatchQueue.main.async { self.onState?(false, m) } }
                return
            }
            self.errs = 0; self.frameN += 1
            self.ms = self.ms * 0.9 + (CACurrentMediaTime() - tS) * 100
            if self.frameN % 300 == 1 { Ladeni.log("metal hledáček \(Int(self.ml.drawableSize.width))x\(Int(self.ml.drawableSize.height)) snímek \(self.frameN) příprava \(String(format: "%.1f", self.ms)) ms, CI \(fs.gpu.ciFlip ? "zdola" : "shora")") }
            self.lock.lock(); let first = self.on && !self.confirmed; if first { self.confirmed = true }; self.lock.unlock()
            if first { DispatchQueue.main.async { self.isHidden = false; self.onState?(true, nil) } }
        }
    }
}
