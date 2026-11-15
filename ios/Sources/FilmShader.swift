import Metal
import CoreImage
import CoreVideo
import UIKit

/* Filmový shader fotky v Metalu (FilmShader.metal = přepis FS / HS z webu). Hodnoty počítá web (Engine.render → rec) a posílá je
   jako slovník {u: {uExp: …, uGE: [r, g, b], …}, lut: "luts/log/P400.png", curve: base64 256×RGBA}; appka jen dodá snímek.
   Postup jako ve webu: snímek z logu → „zdroj hledáčku“ (lineární světlo → rameno → sRGB, CIColorCube) → mapa světel (≤ 512 px,
   mipmapy) → hlavní shader (výřez na poměr cíle, zoom, film, halation, bloom, glow, zrno …) do cílové textury. */
final class FilmGPU {
    static let shared: FilmGPU? = FilmGPU()
    let dev: MTLDevice
    let queue: MTLCommandQueue
    let filmPS: MTLRenderPipelineState
    let hiPS: MTLRenderPipelineState
    let ci: CIContext
    let ciFlip: Bool          // Core Image píše do textury zdola nahoru → obraz před zápisem převrátit
    let dummy3D: MTLTexture
    let identCurve: MTLTexture
    static let viewCube = CameraEngine.logCube(n: 48, linearScale: nil)
    private var luts: [String: MTLTexture] = [:]
    private let lock = NSLock()

    private init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { Ladeni.log("filmový shader: Metal chybí"); return nil }
        guard let lib = d.makeDefaultLibrary(), let vf = lib.makeFunction(name: "qvert"), let ff = lib.makeFunction(name: "qfilm"), let hf = lib.makeFunction(name: "qhi") else {
            Ladeni.log("filmový shader: knihovna shaderů chybí"); return nil }
        do {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = vf; pd.fragmentFunction = ff; pd.colorAttachments[0].pixelFormat = .bgra8Unorm
            filmPS = try d.makeRenderPipelineState(descriptor: pd)
            let hd = MTLRenderPipelineDescriptor()
            hd.vertexFunction = vf; hd.fragmentFunction = hf; hd.colorAttachments[0].pixelFormat = .rgba16Float
            hiPS = try d.makeRenderPipelineState(descriptor: hd)
        } catch { Ladeni.log("filmový shader: \(error.localizedDescription)"); return nil }
        dev = d; queue = q
        let ctx = CIContext(mtlDevice: d, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        ci = ctx
        let t3 = MTLTextureDescriptor(); t3.textureType = .type3D; t3.pixelFormat = .rgba16Float; t3.width = 1; t3.height = 1; t3.depth = 1
        guard let dm = d.makeTexture(descriptor: t3) else { return nil }
        dummy3D = dm
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        guard let ct = d.makeTexture(descriptor: cd) else { return nil }
        var px = [UInt8](repeating: 255, count: 1024)
        for i in 0..<256 { px[i * 4] = UInt8(i); px[i * 4 + 1] = UInt8(i); px[i * 4 + 2] = UInt8(i) }
        ct.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: px, bytesPerRow: 1024)
        identCurve = ct
        ciFlip = FilmGPU.calibrate(ctx, d, q)
    }

    /* Na jakou stranu Core Image píše do textury Metalu (dokumentace to neříká jasně): bílý horní řádek (v CI y = 1) → je v řádku 0? */
    private static func calibrate(_ ci: CIContext, _ d: MTLDevice, _ q: MTLCommandQueue) -> Bool {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite, .renderTarget]; td.storageMode = .shared
        guard let t = d.makeTexture(descriptor: td), let cb = q.makeCommandBuffer() else { return false }
        let top = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 1, width: 2, height: 1))
        let img = top.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)))
        let dst = CIRenderDestination(mtlTexture: t, commandBuffer: cb)
        dst.colorSpace = nil
        do { _ = try ci.startTask(toRender: img, from: CGRect(x: 0, y: 0, width: 2, height: 2), to: dst, at: .zero) } catch { return false }
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 16)
        t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        let flip = px[0] < 128
        Ladeni.log("filmový shader: Core Image píše do textury \(flip ? "zdola" : "shora") (\(px[0]) / \(px[8]))")
        return flip
    }

    /// LUT filmu z balíčku (Web/luts/…, řezy podle modré vedle sebe) jako 3D textura
    func lut(_ path: String) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        if let t = luts[path] { return t }
        guard !path.contains(".."), let url = Bundle.main.resourceURL?.appendingPathComponent("Web/" + path),
              let img = UIImage(contentsOfFile: url.path)?.cgImage, let (n, px) = ClipDevelop.lutPixels(img) else { Ladeni.log("filmový shader: LUT \(path) chybí"); return nil }
        var h = [Float16](repeating: 1, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let si = (g * n * n + b * n + r) * 4, di = ((b * n + g) * n + r) * 4
            h[di] = Float16(px[si]); h[di + 1] = Float16(px[si + 1]); h[di + 2] = Float16(px[si + 2])
        } } }
        let td = MTLTextureDescriptor(); td.textureType = .type3D; td.pixelFormat = .rgba16Float; td.width = n; td.height = n; td.depth = n
        guard let t = dev.makeTexture(descriptor: td) else { return nil }
        h.withUnsafeBytes { t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 8, bytesPerImage: n * n * 8) }
        luts[path] = t
        return t
    }
}

/// Jeden uživatel shaderu (hledáček, vyvolání klipu) – vlastní pomocné textury; volat vždy ze stejné fronty
final class FilmShader {
    static let table: [(String, Int, Int)] = [("uZoom", 0, 1), ("uTime", 1, 1), ("uStatic", 2, 1), ("uExp", 3, 1), ("uTemp", 4, 1), ("uTint", 5, 1), ("uCon", 6, 1), ("uSat", 7, 1), ("uStr", 8, 1), ("uHal", 9, 1), ("uBloom", 10, 1), ("uVig", 11, 1), ("uFade", 12, 1), ("uSharp", 13, 1), ("uShad", 14, 1), ("uHil", 15, 1), ("uGrain", 16, 1), ("uGFreq", 17, 1), ("uGSharp", 18, 1), ("uGChroma", 19, 1), ("uGClump", 20, 1), ("uGMot", 21, 1), ("uGN", 22, 1), ("uFCon", 23, 1), ("uFSat", 24, 1), ("uFFade", 25, 1), ("uChar", 26, 1), ("uFSoft", 27, 1), ("uBToe", 28, 1), ("uBWL", 29, 1), ("uTr", 30, 1), ("uSeed", 31, 1), ("uGlow", 32, 1), ("uPol", 33, 1), ("uLat", 34, 1), ("uHR", 35, 1), ("uFBlur", 36, 1), ("uGV", 37, 1), ("uFV", 38, 1), ("uNeg", 39, 1), ("uApl", 40, 1), ("uEst", 41, 1), ("uHV", 42, 1), ("uLut", 43, 1), ("uCover", 44, 2), ("uRes", 46, 2), ("uGE", 48, 3), ("uSh", 51, 3), ("uHi", 54, 3), ("uBW", 57, 3), ("uBTone", 60, 3), ("uGSh", 63, 3), ("uGMid", 66, 3), ("uGHi", 69, 3), ("uTrMs", 72, 3), ("uTrSs", 75, 3), ("uTrMr", 78, 3), ("uTrSr", 81, 3), ("uLF", 84, 3), ("uHsl", 87, 24)]
    static let count = 111
    static let idx: [String: Int] = Dictionary(uniqueKeysWithValues: table.map { ($0.0, $0.1) })
    let gpu: FilmGPU
    private var src: MTLTexture?
    private var hl: MTLTexture?
    private let cube: CIFilter
    private var base = [Float](repeating: 0, count: FilmShader.count)
    private var lutT: MTLTexture?
    private var curveT: MTLTexture?
    private(set) var ready = false

    init?() {
        guard let g = FilmGPU.shared else { return nil }
        gpu = g
        cube = CameraEngine.cubeFilter(FilmGPU.viewCube)
    }

    /// {u, lut, curve} z webu
    func configure(_ m: [String: Any]) {
        if let u = m["u"] as? [String: Any] {
            var b = [Float](repeating: 0, count: Self.count)
            for (n, o, c) in Self.table {
                guard let v = u[n] else { continue }
                if let a = v as? [Any] { for i in 0..<min(c, a.count) { b[o + i] = Float((a[i] as? Double) ?? 0) } }
                else if let d = v as? Double { b[o] = Float(d) }
            }
            base = b; ready = true
        }
        lutT = (m["lut"] as? String).flatMap { gpu.lut($0) }
        if let s = m["curve"] as? String, let d = Data(base64Encoded: s), d.count == 1024 {
            if curveT == nil { curveT = gpu.dev.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)) }
            d.withUnsafeBytes { curveT?.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 1024) }
        } else { curveT = nil }
    }

    private func tex(_ old: MTLTexture?, _ w: Int, _ h: Int) -> MTLTexture? {
        if let o = old, o.width == w, o.height == h { return o }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
        td.usage = [.shaderRead, .shaderWrite, .renderTarget]; td.storageMode = .private
        return gpu.dev.makeTexture(descriptor: td)
    }

    private func pass(_ cb: MTLCommandBuffer, _ ps: MTLRenderPipelineState, _ out: MTLTexture, _ u: [Float], _ ts: [MTLTexture]) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = out; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setRenderPipelineState(ps)
        u.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        for (i, t) in ts.enumerated() { e.setFragmentTexture(t, index: i) }
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        e.endEncoding()
    }

    /// img = snímek kamery (kódy Apple Logu, když log), maxSide = zdroj zmenšit na nejvýš tolik px (hledáček 1280 jako ve webu)
    func encode(_ img: CIImage, log: Bool, mirror: Bool, zoom: Float, time: Float, est: Float? = nil, maxSide: CGFloat, out: MTLTexture, cb: MTLCommandBuffer) throws {
        let e = img.extent, k = min(1, maxSide / max(e.width, e.height))
        let W = max(1, Int((e.width * k).rounded())), H = max(1, Int((e.height * k).rounded()))
        var s = img
        if log { cube.setValue(s, forKey: kCIInputImageKey); s = cube.outputImage ?? s }
        s = s.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        if k < 0.999 { s = s.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1]) }
        let r = CGRect(x: 0, y: 0, width: W, height: H)
        s = s.clampedToExtent().cropped(to: r)
        if mirror { s = s.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(W), ty: 0)) }
        if gpu.ciFlip { s = s.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(H))) }
        guard let st = tex(src, W, H) else { throw QError(message: "není paměť na snímek") }
        src = st
        let dst = CIRenderDestination(mtlTexture: st, commandBuffer: cb)
        dst.colorSpace = nil
        _ = try gpu.ci.startTask(toRender: s.cropped(to: r), from: r, to: dst, at: .zero)
        // mapa světel ≤ 512 px
        let kh = min(1, 512 / Double(max(W, H))), hw = max(1, Int((Double(W) * kh).rounded())), hh = max(1, Int((Double(H) * kh).rounded()))
        guard let ht = tex(hl, hw, hh) else { throw QError(message: "není paměť na mapu světel") }
        hl = ht
        if let b = cb.makeBlitCommandEncoder() { b.generateMipmaps(for: st); b.endEncoding() }
        pass(cb, gpu.hiPS, ht, [1 / Float(hw), 1 / Float(hh), max(0, log2(Float(W) / Float(hw) / 4)), log ? 1 : 0], [st])
        if let b = cb.makeBlitCommandEncoder() { b.generateMipmaps(for: ht); b.endEncoding() }
        // hlavní shader
        var u = base
        let ow = Float(out.width), oh = Float(out.height), sAR = Float(W) / Float(H), dAR = ow / oh
        func set(_ n: String, _ v: [Float]) { if let o = Self.idx[n] { for (i, x) in v.enumerated() { u[o + i] = x } } }
        set("uZoom", [max(1, zoom)]); set("uTime", [time]); set("uStatic", [0]); set("uRes", [ow, oh])
        set("uCover", dAR > sAR ? [1, sAR / dAR] : [dAR / sAR, 1])
        if let est { set("uEst", [est]) }
        pass(cb, gpu.filmPS, out, u, [st, curveT ?? gpu.identCurve, lutT ?? gpu.dummy3D, ht])
    }
}
