import CoreImage
import CoreGraphics
import Foundation

/* Vzhled filmu na jednom snímku v logu (nebo běžném videu): zrno v negativu → tabulka barev → halation → bloom → glow → vinětace.
   Stejný řetězec používá vyvolání klipu (ClipDevelop) i hledáček v Metalu (MetalViewfinder) → hledáček = klip = fotka. */
final class FilmLook {
    let w: Int, h: Int, log: Bool
    let ext: CGRect
    private let cubeF: CIFilter
    private let noiseBase = CIFilter(name: "CIRandomGenerator")!.outputImage!
    private let gk: Double
    private let t0h: CGFloat, t1h: CGFloat, hk: CGFloat, q: CGFloat, hh: CGFloat
    private let fxQ: CGFloat, fxM: Double, bloomK: CGFloat, glowK: CGFloat
    private var vigImg: CIImage?

    /// cube = data CIColorCube 64³ (cubeFromWeb nebo cube(film:)), parametry jako z webu (clipParams)
    init(w: Int, h: Int, log: Bool, cube: Data, str: Double, grain: Double, hal: Double, bloom: Double, glow: Double, vig: Double, gn: Double) {
        self.w = w; self.h = h; self.log = log
        ext = CGRect(x: 0, y: 0, width: w, height: h)
        cubeF = CIFilter(name: "CIColorCube")!
        cubeF.setValue(64, forKey: "inputCubeDimension")
        cubeF.setValue(cube, forKey: "inputCubeData")
        /* Zrno jako ve fotce (grv 3, kalibrované na spektrafilm): každá barevná vrstva negativu šumí zvlášť (σ 0,232 / 0,152 / 0,208 EV
           na pixel 8,2 µm, vrstvy se míchají jen z desetiny), jemné – jeden pixel klipu průměruje víc zrn (4250 zrn na delší stranu políčka).
           1 EV ≈ 0,0855 kódu Apple Logu; CIRandomGenerator = nezávislé kanály 0…1 (σ 0,2887), rozostření 0,5 px ubere σ na 0,564 */
        gk = grain / 0.5 * str * (log ? 0.0855 : 0.052) * min(1, Double(max(w, h)) / max(gn, 500)) / (0.2887 * 0.564)
        /* halation = červenooranžová záře kolem opravdu přepálených světel (v logu nad ~1 EV nad bílou), jen kolem, ne přes světlo samo */
        t0h = log ? 0.70 : 0.93; t1h = log ? 0.86 : 1.0; hk = CGFloat(0.45 * hal)
        q = 0.25; hh = CGFloat(h) * q
        /* Bloom a Glow jako ve fotce. Čísla napasovaná na výstup foto shaderu na Honzově snímku se sluncem (test-raw/honza/b/fit.py):
           Bloom = měkká záře jen z opravdu přepálených světel (scéna 2× nad bílou = kód Apple Logu nad ~0,78), tři rozostření
           0,6 / 1,6 / 4,5 % delší strany s vahami 0,5 / 0,8 / 1, přičtené „screen“ (v už světlém místě přidá míň), síla 1,25 × bloom.
           Glow = difúze: rozostřený hotový obraz (1,2 % delší strany) vážený jasem (smoothstep 0,4…0,95) × 0,85, screen s vahou glow · 0,6,
           a nepatrné zvednutí černé (glow · 0,15). Počítá se ve čtvrtinovém rozlišení (jako halation). */
        fxQ = 0.25; fxM = Double(max(w, h)) * 0.25; bloomK = CGFloat(1.25 * bloom); glowK = CGFloat(glow)
        // vinětace stejně jako v hledáčku: c *= mix(1, smoothstep(.95, .2, |q|·1,15), vig), q = střed ±0,5 přepočtený na kratší stranu
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
    }

    private func fxScale(_ i: CIImage, _ k: CGFloat, bias: CGFloat = 0, alpha: CGFloat = 1) -> CIImage {
        i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
    }
    private func fxMul(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]) }
    private func fxAdd(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b]) }
    private func fxUp(_ i: CIImage) -> CIImage { i.transformed(by: CGAffineTransform(scaleX: 1 / fxQ, y: 1 / fxQ)).cropped(to: ext) }

    private func negGrain(_ frame: Int) -> CIImage {
        let off = CGAffineTransform(translationX: CGFloat((frame * 977 + 331) % 8192), y: CGFloat((frame * 613 + 173) % 8192))
        let n = noiseBase.transformed(by: off).applyingGaussianBlur(sigma: 0.5).cropped(to: ext)
        let r = CGFloat(0.232 * gk), g = CGFloat(0.152 * gk), b = CGFloat(0.208 * gk), x: CGFloat = 0.1
        return n.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: r * x, z: r * x, w: 0), "inputGVector": CIVector(x: g * x, y: g, z: g * x, w: 0),
            "inputBVector": CIVector(x: b * x, y: b * x, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -r * (1 + 2 * x) / 2, y: -g * (1 + 2 * x) / 2, z: -b * (1 + 2 * x) / 2, w: 0)])
    }

    /// src = snímek v logu (kódy 0…1) o rozměru w × h s počátkem v 0,0; frame = číslo snímku (zrno jinde)
    func apply(_ src: CIImage, frame: Int) -> CIImage {
        var img = src
        if gk > 0.0001 {
            var ng = negGrain(frame)
            if log {
                // jako negGrain ve webu: × (1 + 0,75·smoothstep(−1,3 → −3,6 EV)) × (1 − 0,8·smoothstep(+3 → +5 EV)); EV = (kód − 0,488) / 0,0855
                let wl = CIVector(x: 0.3, y: 0.5, z: 0.2, w: 0), poly = CIVector(x: 0, y: 0, z: 3, w: -2), keepA = CIVector(x: 0, y: 1, z: 0, w: 0)
                func ramp(_ k: CGFloat, _ b: CGFloat, _ gain: CGFloat, _ base: CGFloat) -> CIImage {
                    let t = src.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: wl.x * k, y: wl.y * k, z: wl.z * k, w: 0), "inputGVector": CIVector(x: wl.x * k, y: wl.y * k, z: wl.z * k, w: 0),
                        "inputBVector": CIVector(x: wl.x * k, y: wl.y * k, z: wl.z * k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0)]).applyingFilter("CIColorClamp")
                        .applyingFilter("CIColorPolynomial", parameters: ["inputRedCoefficients": poly, "inputGreenCoefficients": poly, "inputBlueCoefficients": poly, "inputAlphaCoefficients": keepA])
                    return fxScale(t, gain, bias: base)
                }
                ng = fxMul(fxMul(ng, ramp(-5.085, 1.9165, 0.75, 1)), ramp(5.848, -4.354, -0.8, 1))
            }
            img = ng.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: img]).cropped(to: ext)
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
        return img
    }
}
