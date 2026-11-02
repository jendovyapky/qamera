import AVFoundation
import SwiftUI

@main
struct QameraApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

enum Q {
    static let yellow = Color(red: 1.0, green: 0.78, blue: 0.12)
    static let lcd = Color(red: 0.98, green: 0.66, blue: 0.10)
    static let ink = Color(red: 0.16, green: 0.10, blue: 0.02)
    static let mono = Font.system(size: 13, weight: .semibold, design: .monospaced)

    // Standardní řady hodnot (kolečka „cvakají“ po třetinách EV)
    static let isoStops: [Float] = [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                                    1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]
    static let shutterStops: [Double] = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500,
                                         400, 320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10,
                                         8, 6, 5, 4, 3].map { 1.0 / $0 } + [0.4, 0.5, 0.6, 0.8, 1.0]

    static func shutterText(_ s: Double) -> String {
        if s <= 0 { return "—" }
        if s >= 0.35 { return String(format: "%.1f s", s).replacingOccurrences(of: ".", with: ",") }
        return "1/\(Int((1 / s).rounded()))"
    }

    static func evText(_ v: Float) -> String {
        let r = (v * 10).rounded() / 10
        if r == 0 { return "±0" }
        return (r > 0 ? "+" : "−") + String(format: "%.1f", abs(r)).replacingOccurrences(of: ".", with: ",")
    }
}

struct CameraScreen: View {
    @StateObject private var cam = CameraModel()
    @State private var focusPoint: CGPoint?
    @State private var focusID = 0
    private let tick = UISelectionFeedbackGenerator()
    private let thump = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                display
                viewfinder
                lensRow
                controls
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            if let t = cam.toast {
                Text(t)
                    .font(Q.mono)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 70)
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { cam.toast = nil }
                    }
            }
            if cam.denied {
                Text("Qamera nemá přístup ke kameře.\nPovol ho v Nastavení → Qamera DEV.")
                    .font(Q.mono).multilineTextAlignment(.center).padding(24)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: cam.toast)
        .onAppear {
            cam.start()
            tick.prepare()
            thump.prepare()
        }
    }

    // Žlutý „LCD“ displej: ISO · čas · EV · režim
    private var display: some View {
        HStack(spacing: 0) {
            cell("ISO", cam.manual ? "\(Int(cam.iso))" : "\(Int(cam.liveISO.rounded()))")
            cell("ČAS", Q.shutterText(cam.manual ? cam.shutter : cam.liveShutter))
            cell("EV", cam.manual ? "M" : Q.evText(cam.ev))
            cell("REŽIM", cam.manual ? "MAN" : "AUTO")
        }
        .padding(.vertical, 8)
        .background(Q.lcd, in: RoundedRectangle(cornerRadius: 12))
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold, design: .monospaced)).opacity(0.6)
            Text(value).font(.system(size: 17, weight: .bold, design: .monospaced)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(Q.ink)
        .frame(maxWidth: .infinity)
    }

    private var viewfinder: some View {
        CameraPreview(session: cam.session) { viewPoint, devicePoint in
            cam.focus(at: devicePoint)
            focusPoint = viewPoint
            focusID += 1
            tick.selectionChanged()
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .overlay {
            if let p = focusPoint {
                FocusMark()
                    .id(focusID)
                    .position(p)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08)))
    }

    private var lensRow: some View {
        HStack(spacing: 8) {
            ForEach(cam.lenses) { l in
                let on = l.id == cam.lensID
                Button {
                    cam.selectLens(l.id)
                    tick.selectionChanged()
                } label: {
                    Text(l.label)
                        .font(Q.mono)
                        .foregroundStyle(on ? Q.yellow : .white.opacity(0.7))
                        .frame(width: 52, height: 32)
                        .background(Color.white.opacity(on ? 0.14 : 0.06), in: Capsule())
                }
            }
        }
        .frame(height: 32)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Režim", selection: Binding(get: { cam.manual }, set: { m in
                if m {
                    // Ruční režim začne z hodnot, které právě zvolila automatika
                    cam.iso = nearest(Q.isoStops.filter { cam.isoRange.contains($0) }, cam.liveISO) ?? cam.iso
                    cam.shutter = nearest(shutterStops, cam.liveShutter) ?? cam.shutter
                }
                cam.manual = m
                cam.applyExposure()
                thump.impactOccurred()
            })) {
                Text("AUTO").tag(false)
                Text("RUČNĚ").tag(true)
            }
            .pickerStyle(.segmented)

            if cam.manual {
                stopSlider("ISO", values: Q.isoStops.filter { cam.isoRange.contains($0) }.map(Double.init),
                           current: Double(cam.iso), text: { "\(Int($0))" }) { cam.iso = Float($0) }
                stopSlider("ČAS", values: shutterStops, current: cam.shutter, text: Q.shutterText) { cam.shutter = $0 }
            } else {
                stopSlider("EV", values: stride(from: -3.0, through: 3.0, by: 1.0 / 3).map { $0 },
                           current: Double(cam.ev), text: { Q.evText(Float($0)) }) { cam.ev = Float($0) }
            }
        }
        .frame(height: 110, alignment: .top)
    }

    private var shutterStops: [Double] {
        let r = cam.shutterRange
        return Q.shutterStops.filter { $0 >= r.lowerBound * 0.999 && $0 <= r.upperBound * 1.001 }
    }

    private func nearest<T: BinaryFloatingPoint>(_ values: [T], _ v: T) -> T? {
        guard v > 0 else { return nil }
        return values.min { abs(log(Double($0)) - log(Double(v))) < abs(log(Double($1)) - log(Double(v))) }
    }

    // Posuvník, který cvaká po hodnotách řady (haptika na každém kroku)
    private func stopSlider(_ label: String, values: [Double], current: Double, text: @escaping (Double) -> String,
                            set: @escaping (Double) -> Void) -> some View {
        let idx = values.indices.min { abs(values[$0] - current) < abs(values[$1] - current) } ?? 0
        return HStack(spacing: 12) {
            Text(label).font(Q.mono).foregroundStyle(.white.opacity(0.6)).frame(width: 34, alignment: .leading)
            Slider(value: Binding(get: { Double(idx) }, set: { nv in
                let i = Int(nv.rounded())
                guard values.indices.contains(i), i != idx else { return }
                set(values[i])
                cam.applyExposure()
                tick.selectionChanged()
            }), in: 0...Double(max(values.count - 1, 1)), step: 1)
            .tint(Q.yellow)
            .disabled(values.count < 2)
            Text(values.isEmpty ? "—" : text(values[idx]))
                .font(Q.mono).monospacedDigit().foregroundStyle(Q.yellow)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var bottomBar: some View {
        HStack {
            Group {
                if let img = cam.lastPhoto {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            }

            Spacer()
            Button {
                thump.impactOccurred()
                cam.capture()
            } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.35), lineWidth: 3).frame(width: 78, height: 78)
                    Circle().fill(cam.capturing ? Color.white.opacity(0.5) : Color.white).frame(width: 64, height: 64)
                }
            }
            .disabled(cam.capturing)
            Spacer()

            Button {
                guard !cam.rawKind.isEmpty else { cam.toast = "Tenhle objektiv RAW neumí"; return }
                cam.raw.toggle()
                tick.selectionChanged()
            } label: {
                Text(cam.rawKind.isEmpty ? "RAW" : cam.rawKind)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(cam.raw ? Q.ink : .white.opacity(cam.rawKind.isEmpty ? 0.3 : 0.75))
                    .frame(width: 64, height: 34)
                    .background(cam.raw ? Q.yellow : Color.white.opacity(0.08), in: Capsule())
            }
        }
        .padding(.bottom, 8)
    }
}

// Žlutý čtvereček ostření, krátce pulzne a zmizí
struct FocusMark: View {
    @State private var shown = false
    @State private var gone = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Q.yellow, lineWidth: 1.5)
            .frame(width: 64, height: 64)
            .scaleEffect(shown ? 1 : 1.4)
            .opacity(gone ? 0 : 1)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { shown = true }
            }
            .task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.easeOut(duration: 0.4)) { gone = true }
            }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        context.coordinator.view = v
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        var onTap: (CGPoint, CGPoint) -> Void
        weak var view: PreviewUIView?
        init(onTap: @escaping (CGPoint, CGPoint) -> Void) { self.onTap = onTap }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            let p = g.location(in: v)
            onTap(p, v.previewLayer.captureDevicePointConverted(fromLayerPoint: p))
        }
    }
}
