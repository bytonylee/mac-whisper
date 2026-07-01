import Cocoa
import QuartzCore

/// A 5-bar waveform whose bar heights are driven by real-time audio RMS levels.
/// Bars use a center-high / sides-low weighting with a smooth attack/release envelope
/// plus slight per-bar jitter for an organic feel.
final class WaveformView: NSView {
    private let barCount = 5
    private let barWeights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private let barWidth: CGFloat = 4.0
    private let barGap: CGFloat = 5.0
    private let minHeight: CGFloat = 4.0

    private let attack: CGFloat = 0.40
    private let release: CGFloat = 0.15
    private let jitterAmount: CGFloat = 0.04

    private var bars: [CALayer] = []
    private var displayed: [CGFloat]
    private var level: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        displayed = Array(repeating: 0, count: barCount)
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupBars() {
        layer?.masksToBounds = false
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (bounds.width - totalWidth) / 2.0

        for i in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = barWidth / 2.0
            let x = startX + CGFloat(i) * (barWidth + barGap)
            bar.frame = CGRect(x: x, y: (bounds.height - minHeight) / 2.0,
                               width: barWidth, height: minHeight)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    /// Feed a new normalized RMS level (0...1).
    func updateLevel(_ newLevel: Float) {
        level = CGFloat(max(0, min(1, newLevel)))
    }

    func startAnimating() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        level = 0
        // Settle bars back to baseline.
        for i in 0..<barCount { displayed[i] = 0 }
        applyHeights(animated: true)
    }

    private func tick() {
        for i in 0..<barCount {
            let jitter = 1.0 + CGFloat.random(in: -jitterAmount...jitterAmount)
            let target = min(1.0, level * barWeights[i] * jitter)
            // Asymmetric envelope: fast attack, slower release.
            let coeff = target > displayed[i] ? attack : release
            displayed[i] += (target - displayed[i]) * coeff
        }
        applyHeights(animated: false)
    }

    private func applyHeights(animated: Bool) {
        let maxHeight = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.18) }
        for i in 0..<barCount {
            guard i < bars.count else { continue }
            let h = minHeight + (maxHeight - minHeight) * displayed[i]
            var frame = bars[i].frame
            frame.size.height = h
            frame.origin.y = (bounds.height - h) / 2.0
            bars[i].frame = frame
        }
        CATransaction.commit()
    }
}
