import UIKit
import Metal
import QuartzCore
import CoreImage

/* Hledáček v Metalu: snímky kamery appky (Apple Log) se vyvolávají přímo na GPU stejným řetězcem jako klip (FilmLook:
   tabulka barev z foto shaderu webu + zrno v negativu, halation, bloom, glow, vinětace) a kreslí se do vrstvy POD průhledným
   WKWebView přesně na místo #vf. Web jen posílá obdélník hledáčku, vzhled (tabulka + parametry) a zoom / zrcadlení / rozmazání;
   JPEG snímky do webu jdou dál, ale jen ~8/s (měření, RAW na jas hledáčku, hlídač). Když se cokoli nepovede, web kreslí sám. */
final class MetalViewfinder: UIView {
    static weak var current: MetalViewfinder?
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var ml: CAMetalLayer { layer as! CAMetalLayer }
    private let dev = MTLCreateSystemDefaultDevice()
    private lazy var mq = dev?.makeCommandQueue()
    private lazy var ctx: CIContext? = dev.map { CIContext(mtlDevice: $0, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                                                                  .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]) }
    private let blurV = UIVisualEffectView(effect: nil)
    private let rq = DispatchQueue(label: "qamera.mvf", qos: .userInteractive)
    var onState: ((Bool, String?) -> Void)?   // → web: první snímek nakreslen / chyba

    // stav: zapisuje hlavní vlákno, čte fronta kamery a kreslení
    private let lock = NSLock()
    private var on = false
    private var px = CGSize.zero
    private var mirror = false
    private var zoom: CGFloat = 1
    private var cube: Data?
    private var params: [String: Double] = [:]
    private var gen = 0          // číslo vzhledu (nová tabulka / parametry / velikost → nový FilmLook)
    private var look: FilmLook?  // jen na rq
    private var lookGen = -1
    private var busy = false
    private var confirmed = false
    private var frameN = 0
    private var errs = 0
    private var ms = 0.0

    var live: Bool { lock.lock(); defer { lock.unlock() }; return on && cube != nil && confirmed }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = .black
        clipsToBounds = true
        ml.device = dev
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = false   // Core Image do textury zapisuje i výpočtem
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

    /// {op:'vf', on, x, y, w, h, r, mir, zoom, blur}
    func configure(_ m: [String: Any]) {
        let want = (m["on"] as? Bool) ?? false
        let r = CGRect(x: (m["x"] as? Double) ?? 0, y: (m["y"] as? Double) ?? 0, width: (m["w"] as? Double) ?? 0, height: (m["h"] as? Double) ?? 0)
        if dev == nil || ctx == nil { if want { onState?(false, "Metal není k dispozici") }; return }
        if r.width > 2, r.height > 2, frame != r { frame = r }
        layer.cornerRadius = CGFloat((m["r"] as? Double) ?? 22)
        // vykreslovat v rozlišení displeje, nejvýš 1600 px delší strana (výkon); vrstva se případně zvětší sama
        let sc = traitCollection.displayScale, k = min(1, 1600 / max(r.width * sc, r.height * sc, 1))
        let p = CGSize(width: (r.width * sc * k).rounded(), height: (r.height * sc * k).rounded())
        if p.width > 2, ml.drawableSize != p { ml.drawableSize = p }
        let blur = (m["blur"] as? Bool) ?? false
        if (blurV.effect != nil) != blur {
            UIView.animate(withDuration: blur ? 0.25 : 0.45) { self.blurV.effect = blur ? UIBlurEffect(style: .dark) : nil }
        }
        lock.lock()
        if !want { confirmed = false }
        if p != px { px = p; gen += 1 }
        on = want; mirror = (m["mir"] as? Bool) ?? false; zoom = CGFloat(max(1, (m["zoom"] as? Double) ?? 1))
        lock.unlock()
        if !want { isHidden = true }
    }

    /// {op:'look', lut: dataURL PNG (clipLut), str, grain, hal, bloom, glow, vig, gn}
    func setLook(_ m: [String: Any]) {
        guard let s = m["lut"] as? String, let comma = s.firstIndex(of: ",") else { return }
        var p: [String: Double] = [:]
        for k in ["str", "grain", "hal", "bloom", "glow", "vig", "gn"] { if let v = m[k] as? Double { p[k] = v } else if let v = m[k] as? Int { p[k] = Double(v) } }
        let b64 = String(s[s.index(after: comma)...])
        rq.async {
            guard let d = Data(base64Encoded: b64), let wl = ClipDevelop.lutFromPNG(d), wl.0 >= 17 else { Ladeni.log("metal hledáček: vadná tabulka"); return }
            let c = ClipDevelop.cubeFromWeb(wl, log: true)
            self.lock.lock(); self.cube = c; self.params = p; self.gen += 1; self.lock.unlock()
        }
    }

    // MARK: snímky (fronta kamery)

    /// src = snímek z kamery appky (kódy Apple Logu, na výšku); vrací hned, kreslí se na vlastní frontě (když nestíhá, snímek vypadne)
    func frame(_ src: CIImage, log: Bool) {
        guard log else { return }
        lock.lock()
        guard on, !busy, let cube, px.width > 2 else { lock.unlock(); return }
        busy = true
        let W = Int(px.width), H = Int(px.height), mir = mirror, z = zoom, g = gen, p = params
        lock.unlock()
        rq.async {
            let t0 = CACurrentMediaTime()
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            if self.lookGen != g || self.look?.w != W || self.look?.h != H {
                self.look = FilmLook(w: W, h: H, log: true, cube: cube, str: p["str"] ?? 1, grain: p["grain"] ?? 0.5, hal: p["hal"] ?? 0,
                                     bloom: p["bloom"] ?? 0, glow: p["glow"] ?? 0, vig: p["vig"] ?? 0, gn: p["gn"] ?? 4250)
                self.lookGen = g
            }
            guard let look = self.look, let ctx = self.ctx, let mq = self.mq else { return }
            // výřez jako ve webu: na poměr hledáčku (cover) a digitální zoom ze středu, zmenšit na velikost vrstvy
            let e = src.extent, ta = CGFloat(W) / CGFloat(H)
            var cw = e.width, ch = e.height
            if cw / ch > ta { cw = ch * ta } else { ch = cw / ta }
            cw /= z; ch /= z
            let cr = CGRect(x: e.midX - cw / 2, y: e.midY - ch / 2, width: cw, height: ch)
            let k = CGFloat(W) / cw, ext = CGRect(x: 0, y: 0, width: W, height: H)
            var img = src.cropped(to: cr).transformed(by: CGAffineTransform(translationX: -cr.minX, y: -cr.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
                .clampedToExtent().cropped(to: ext)
            if mir { img = img.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(W), ty: 0)).cropped(to: ext) }
            img = look.apply(img, frame: self.frameN); self.frameN += 1
            var fail: String?
            let exc = QCatch.run {
                guard let drawable = self.ml.nextDrawable(), let cb = mq.makeCommandBuffer() else { fail = "není plocha"; return }
                let dst = CIRenderDestination(width: W, height: H, pixelFormat: self.ml.pixelFormat, commandBuffer: cb, mtlTextureProvider: { drawable.texture })
                dst.isFlipped = true   // Core Image má počátek vlevo dole, textura Metalu vlevo nahoře
                dst.colorSpace = nil   // hodnoty už jsou v sRGB (výstup tabulky) → bez převodu
                do { _ = try ctx.startTask(toRender: img, from: ext, to: dst, at: .zero) } catch { fail = error.localizedDescription; return }
                cb.present(drawable)
                cb.commit()
            }
            if let m = exc ?? fail {
                self.errs += 1
                if self.errs == 1 || self.errs % 100 == 0 { Ladeni.log("metal hledáček CHYBA \(self.errs)×: \(m)") }
                if self.errs == 30 { DispatchQueue.main.async { self.onState?(false, m) } }
                return
            }
            self.errs = 0
            self.ms = self.ms * 0.9 + (CACurrentMediaTime() - t0) * 100
            if self.frameN % 300 == 1 { Ladeni.log("metal hledáček \(W)x\(H) snímek \(self.frameN) příprava \(String(format: "%.1f", self.ms)) ms") }
            self.lock.lock(); let first = self.on && !self.confirmed; if first { self.confirmed = true }; self.lock.unlock()
            if first { DispatchQueue.main.async { self.isHidden = false; self.onState?(true, nil) } }
        }
    }
}
