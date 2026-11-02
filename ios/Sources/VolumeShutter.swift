import AVFoundation
import MediaPlayer
import UIKit

// Tlačítka hlasitosti = spoušť, i když kameru drží WebKit (AVCaptureEventInteraction chodí jen appce s vlastní kamerou).
// Hlídá se změna hlasitosti (KVO outputVolume), hlasitost se hned vrátí zpátky a schovaný MPVolumeView potlačí systémový ukazatel.
// Zapnuté jen na obrazovce foťáku (web pošle {kind:'cam', on}), jinak hlasitost funguje normálně.
final class VolumeShutter: NSObject {
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    private var obs: NSKeyValueObservation?
    private var base: Float = 0.5
    private var restoring = false
    private var lastFire = Date.distantPast
    private let fire: () -> Void
    private(set) var on = false

    init(host: UIView, fire: @escaping () -> Void) {
        self.fire = fire
        super.init()
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        host.addSubview(volumeView)
    }

    func set(_ want: Bool) {
        guard want != on else { return }
        on = want
        if want { start() } else { stop() }
    }

    private var slider: UISlider? { volumeView.subviews.compactMap { $0 as? UISlider }.first }

    private func start() {
        let s = AVAudioSession.sharedInstance()
        // ambient + mix = nezastaví hudbu, kterou si člověk pouští
        try? s.setCategory(.ambient, options: [.mixWithOthers])
        try? s.setActive(true)
        base = s.outputVolume
        // na kraji rozsahu by stisk nic nezměnil → kousek od kraje
        if base >= 0.999 { setVolume(0.9375) } else if base <= 0.001 { setVolume(0.0625) }
        obs = s.observe(\.outputVolume, options: [.new]) { [weak self] _, ch in
            guard let self, let v = ch.newValue else { return }
            DispatchQueue.main.async { self.changed(v) }
        }
    }

    private func stop() {
        obs?.invalidate(); obs = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func changed(_ v: Float) {
        if restoring { if abs(v - base) < 0.001 { restoring = false }; return }
        guard abs(v - base) > 0.001 else { return }
        if Date().timeIntervalSince(lastFire) > 0.35 { lastFire = Date(); fire() }
        restoring = true
        setVolume(base)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.restoring = false }
    }

    private func setVolume(_ v: Float) {
        base = v
        DispatchQueue.main.async { self.slider?.setValue(v, animated: false); self.slider?.sendActions(for: .valueChanged) }
    }

    // appka šla do pozadí / zpět
    func pause() { if on { stop() } }
    func resume() { if on { start() } }
}
