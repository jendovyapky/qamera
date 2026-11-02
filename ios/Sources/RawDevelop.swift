import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Nativní vyvolání RAW (Core Image) – stejná matematika jako develop() v docs/preview/raw.js:
// automatická expozice (geometrický průměr jasu → 0,17, nikdy tmavěji), měkké filmové rameno světel,
// hodně přepálené světlo do bílé, mapa světel (EV nad bílou / 3, ořezaný senzor ≥ 0,5) pro halation a bloom.
// Rychlejší než wasm ve WebView a zvládne i 48 Mpx ProRAW (zmenší se na 4096 px jako export).
enum RawDevelop {
    struct Output {
        let jpg: Data
        let hl: Data?
        let ev: Double
    }

    private static let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let ctx = CIContext(options: [.workingColorSpace: lin, .cacheIntermediates: false])
    private static let srgbLUT: [UInt8] = (0...4096).map { i in
        let v = Double(i) / 4096
        return UInt8((255 * (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)).rounded())
    }

    static func develop(_ data: Data, maxSide: Int = 4096, hlMax: Int = 512) throws -> Output {
        guard let f = CIRAWFilter(imageData: data, identifierHint: UTType("com.adobe.raw-image")?.identifier) else {
            throw QError(message: "RAW se nepodařilo otevřít")
        }
        let n = f.nativeSize
        f.scaleFactor = Float(min(1, Double(maxSide) / Double(max(n.width, n.height, 1))))
        f.boostAmount = 0
        f.baselineExposure = 0
        f.exposure = 0
        if f.isLocalToneMapSupported { f.localToneMapAmount = 0 }
        guard let img = f.outputImage else { throw QError(message: "RAW se nepodařilo vyvolat") }
        let ext = img.extent.integral
        let W = Int(ext.width), H = Int(ext.height)
        guard W > 0, H > 0 else { throw QError(message: "prázdný RAW") }

        // 1) expozice ze zmenšeniny (~200 px)
        let k = min(1, 220 / CGFloat(max(W, H)))
        let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k)).cropped(to: CGRect(x: ext.minX * k, y: ext.minY * k, width: ext.width * k, height: ext.height * k).integral)
        let se = small.extent.integral, sw = Int(se.width), sh = Int(se.height)
        var sb = [Float](repeating: 0, count: max(1, sw * sh * 4))
        sb.withUnsafeMutableBytes { p in ctx.render(small, toBitmap: p.baseAddress!, rowBytes: sw * 16, bounds: se, format: .RGBAf, colorSpace: lin) }
        var ls = 0.0, ln = 0.0
        for i in stride(from: 0, to: sw * sh * 4, by: 4) {
            let y = 0.2126 * Double(sb[i]) + 0.7152 * Double(sb[i + 1]) + 0.0722 * Double(sb[i + 2])
            ls += log2(max(y, 1e-5)); ln += 1
        }
        var ev = max(0, min(4.5, log2(0.17) - ls / max(ln, 1)))
        if !ev.isFinite { ev = 0 }
        let g = Float(pow(2, ev))

        // 2) po pásech: rameno světel, sRGB, mapa světel
        let hk = min(1, Double(hlMax) / Double(max(W, H)))
        let hw = max(1, Int((Double(W) * hk).rounded())), hh = max(1, Int((Double(H) * hk).rounded()))
        var hv = [Float](repeating: 0, count: hw * hh), hn = [Float](repeating: 0, count: hw * hh)
        var out = [UInt8](repeating: 255, count: W * H * 4)
        let band = 256
        var buf = [Float16](repeating: 0, count: W * band * 4)
        let lut = srgbLUT
        for y0 in stride(from: 0, to: H, by: band) {
            let bh = min(band, H - y0)
            let r = CGRect(x: ext.minX, y: ext.maxY - CGFloat(y0 + bh), width: CGFloat(W), height: CGFloat(bh))
            buf.withUnsafeMutableBytes { p in ctx.render(img, toBitmap: p.baseAddress!, rowBytes: W * 8, bounds: r, format: .RGBAh, colorSpace: lin) }
            for yy in 0..<bh {
                let y = y0 + yy, hy = min(hh - 1, Int(Double(y) * hk))
                for x in 0..<W {
                    let s = (yy * W + x) * 4
                    let pr = Float(buf[s]), pg = Float(buf[s + 1]), pb = Float(buf[s + 2])
                    let clip = max(pr, pg, pb) > 0.985
                    var r = max(0, pr * g), gg = max(0, pg * g), b = max(0, pb * g)
                    let m = max(r, gg, b)
                    if m > 0.55 {
                        let fm = 0.55 + 0.45 * (1 - exp(-(m - 0.55) / 0.45)), kk = fm / m, w = min(1, max(0, (m - 1) / 6))
                        r = r * kk * (1 - w) + fm * w; gg = gg * kk * (1 - w) + fm * w; b = b * kk * (1 - w) + fm * w
                    }
                    let o = (y * W + x) * 4
                    out[o] = lut[min(4096, Int(r * 4096))]
                    out[o + 1] = lut[min(4096, Int(gg * 4096))]
                    out[o + 2] = lut[min(4096, Int(b * 4096))]
                    let hi = hy * hw + min(hw - 1, Int(Double(x) * hk))
                    hv[hi] += max(m > 1 ? min(1, log2(m) / 3) : 0, clip ? 0.5 : 0)
                    hn[hi] += 1
                }
            }
        }

        guard let jpg = encode(&out, w: W, h: H, gray: false, type: UTType.jpeg, quality: 0.95) else {
            throw QError(message: "JPEG se nepodařilo uložit")
        }
        var any: Float = 0
        var hm = [UInt8](repeating: 0, count: hw * hh)
        for i in 0..<(hw * hh) {
            let v = hn[i] > 0 ? hv[i] / hn[i] : 0
            any += v
            hm[i] = UInt8(min(255, max(0, (v * 255).rounded())))
        }
        let hl = any > 0 ? encode(&hm, w: hw, h: hh, gray: true, type: UTType.png, quality: 1) : nil
        return Output(jpg: jpg, hl: hl, ev: ev)
    }

    // Hloubka z LiDARu → šedá PNG jako výstup Depth Anything (blízko = světlé), orientace jako fotka
    static func depthPNG(_ d: AVDepthData, orientation: CGImagePropertyOrientation) -> Data? {
        let disp = d.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32).applyingExifOrientation(orientation)
        let pb = disp.depthDataMap
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        var v = [Float](repeating: .nan, count: w * h)
        for y in 0..<h {
            let row = (base + y * rb).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { v[y * w + x] = row[x] }
        }
        let ok = v.filter { $0.isFinite && $0 > 0 }.sorted()
        guard ok.count > 16 else { return nil }
        let lo = ok[ok.count * 2 / 100], hi = ok[ok.count * 98 / 100], span = max(hi - lo, 1e-6)
        var px = v.map { $0.isFinite && $0 > 0 ? UInt8(min(255, max(0, ((($0 - lo) / span) * 255).rounded()))) : 0 }
        return encode(&px, w: w, h: h, gray: true, type: UTType.png, quality: 1)
    }

    private static func encode(_ px: inout [UInt8], w: Int, h: Int, gray: Bool, type: UTType, quality: Double) -> Data? {
        let cs = gray ? CGColorSpaceCreateDeviceGray() : srgb
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let cg: CGImage? = px.withUnsafeMutableBytes { p in
            CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: gray ? w : w * 4,
                      space: cs, bitmapInfo: info)?.makeImage()
        }
        guard let cg else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return data as Data
    }
}
