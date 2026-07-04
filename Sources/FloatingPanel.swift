import Cocoa
import QuartzCore

private final class GradientTextView: NSView {
    private static let gradientMotionKey = "gradientMotion"

    private let gradientLayer = CAGradientLayer()
    private let textLayer = CATextLayer()

    var stringValue = "" { didSet { updateText() } }
    var font: NSFont { didSet { updateText() } }
    var alignment: NSTextAlignment = .left {
        didSet {
            updateAlignment()
            updateText()
        }
    }

    init(font: NSFont) {
        self.font = font
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.colors = [
            NSColor.white.withAlphaComponent(0.96).cgColor,
            NSColor(calibratedRed: 0.72, green: 0.92, blue: 1.0, alpha: 1.0).cgColor,
            NSColor.white.withAlphaComponent(0.96).cgColor
        ]
        gradientLayer.locations = [0, 0.55, 1]
        gradientLayer.mask = textLayer
        layer?.addSublayer(gradientLayer)

        textLayer.isWrapped = false
        textLayer.truncationMode = .none
        updateAlignment()
        updateText()
        syncLayerFrames()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setGradientMotionEnabled(_ enabled: Bool) {
        if enabled {
            guard gradientLayer.animation(forKey: Self.gradientMotionKey) == nil else { return }
            let animation = CABasicAnimation(keyPath: "locations")
            animation.fromValue = [-0.8, -0.35, 0.1]
            animation.toValue = [0.9, 1.35, 1.8]
            animation.duration = 1.6
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            gradientLayer.add(animation, forKey: Self.gradientMotionKey)
        } else {
            gradientLayer.removeAnimation(forKey: Self.gradientMotionKey)
            gradientLayer.locations = [0, 0.55, 1]
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerFrames()
    }

    override func layout() {
        super.layout()
        syncLayerFrames()
    }

    private func syncLayerFrames() {
        gradientLayer.frame = bounds
        textLayer.frame = bounds
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        gradientLayer.contentsScale = scale
        textLayer.contentsScale = scale
    }

    private func updateAlignment() {
        textLayer.alignmentMode = alignment == .center ? .center : .left
    }

    private func updateText() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        textLayer.string = NSAttributedString(
            string: stringValue,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
        )
    }
}

/// Frameless, capsule-shaped floating HUD shown while recording. Uses a non-activating
/// NSPanel + NSVisualEffectView (hudWindow material) so it never steals focus from the
/// target input field. Hosts the waveform on the left and the live transcript on the right,
/// elastically widening as text grows.
final class FloatingPanel {
    private let panel: NSPanel
    /// Background view providing the capsule material. On macOS 26+ this is an
    /// `NSGlassEffectView` (Liquid Glass); on older systems an `NSVisualEffectView`.
    /// Layer-backed so entry/exit scale animations apply to it.
    private let backgroundView: NSView
    /// Hosts the waveform and transcript. On Liquid Glass this is the glass view's
    /// `contentView`; on the fallback it is a plain subview of the effect view.
    private let contentHost: NSView
    private let waveform: WaveformView
    private let textClipView: NSView
    private let textField: GradientTextView
    /// Luminous inset rim emulating the CSS `.liquidGlass-shine` highlight
    /// (`box-shadow: inset … rgba(255,255,255,0.5)`) from the reference recipe.
    private let shineLayer = CAShapeLayer()

    private let panelHeight: CGFloat = 56
    private let cornerRadius: CGFloat = 28
    private let leftPadding: CGFloat = 18
    private let waveWidth: CGFloat = 44
    private let waveHeight: CGFloat = 32
    private let gap: CGFloat = 12
    private let rightPadding: CGFloat = 10
    private let minTextWidth: CGFloat = 160
    private let maxTextWidth: CGFloat = 560
    private let bottomMargin: CGFloat = 130

    private var textX: CGFloat { leftPadding + waveWidth + gap }

    private let textFont = NSFont.systemFont(ofSize: 16, weight: .medium)
    private var lockedVisibleWidth: CGFloat = 0

    /// Natural height of a single line of the transcript font, used to vertically
    /// center the text within the capsule.
    private var textHeight: CGFloat { ceil(textFont.ascender - textFont.descender + textFont.leading) }
    private var textY: CGFloat { (panelHeight - textHeight) / 2 }

    init() {
        let initialWidth = leftPadding + waveWidth + gap + minTextWidth + rightPadding
        let rect = NSRect(x: 0, y: 0, width: initialWidth, height: panelHeight)

        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        // Background material: Liquid Glass on macOS 26+, frosted HUD material below.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: rect)
            glass.cornerRadius = cornerRadius
            // `.regular` is the full Liquid Glass material (frosting, refraction
            // and adaptive edge highlights) — the headline WWDC25 look. `.clear`
            // renders as a near-invisible transparent gray, so use `.regular`. A
            // subtle white tint emulates the reference `.liquidGlass-tint`
            // (`rgba(255,255,255,0.25)`) milky glass without washing out the
            // white transcript text.
            glass.style = .regular
            glass.tintColor = NSColor.white.withAlphaComponent(0.12)
            glass.autoresizingMask = [.width, .height]
            glass.wantsLayer = true
            backgroundView = glass
        } else {
            let effectView = NSVisualEffectView(frame: rect)
            effectView.material = .hudWindow
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = cornerRadius
            effectView.layer?.masksToBounds = true
            effectView.autoresizingMask = [.width, .height]
            backgroundView = effectView
        }
        panel.contentView = backgroundView

        // Host for the waveform + transcript. Liquid Glass requires its content to
        // be supplied via `contentView`; the fallback hosts it as a direct subview.
        contentHost = NSView(frame: rect)
        contentHost.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *), let glass = backgroundView as? NSGlassEffectView {
            glass.contentView = contentHost
        } else {
            backgroundView.addSubview(contentHost)
        }

        // Liquid-glass "shine": a bright inset rim drawn just inside the capsule
        // edge, mirroring the reference CSS inset white box-shadow.
        contentHost.wantsLayer = true
        shineLayer.fillColor = NSColor.clear.cgColor
        shineLayer.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        shineLayer.lineWidth = 1.5
        shineLayer.shadowColor = NSColor.white.cgColor
        shineLayer.shadowOpacity = 0.5
        shineLayer.shadowRadius = 1.5
        shineLayer.shadowOffset = .zero
        contentHost.layer?.addSublayer(shineLayer)
        let shineInset = shineLayer.lineWidth / 2
        shineLayer.frame = rect
        shineLayer.path = CGPath(
            roundedRect: rect.insetBy(dx: shineInset, dy: shineInset),
            cornerWidth: cornerRadius - shineInset,
            cornerHeight: cornerRadius - shineInset,
            transform: nil
        )

        waveform = WaveformView(frame: NSRect(
            x: leftPadding,
            y: (panelHeight - waveHeight) / 2,
            width: waveWidth,
            height: waveHeight
        ))
        // Keep the waveform pinned to the left edge as the capsule widens.
        waveform.autoresizingMask = [.maxXMargin]
        contentHost.addSubview(waveform)

        textClipView = NSView(frame: .zero)
        textClipView.wantsLayer = true
        textClipView.layer?.masksToBounds = true
        textClipView.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        contentHost.addSubview(textClipView)

        textField = GradientTextView(font: textFont)
        let textFrame = NSRect(
            x: textX,
            y: textY,
            width: minTextWidth,
            height: textHeight
        )
        textClipView.frame = textFrame
        textField.frame = NSRect(origin: .zero, size: textFrame.size)
        // Frame is managed explicitly in resize(); keep left origin fixed.
        textField.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        textClipView.addSubview(textField)
    }

    // MARK: - Presentation

    func show(placeholder: String) {
        lockedVisibleWidth = 0
        textField.alignment = .center
        textField.stringValue = placeholder
        textField.alphaValue = 0.55
        textField.setGradientMotionEnabled(true)
        resize(toTextWidth: minTextWidth, animated: false)
        position()

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        waveform.startAnimating()

        // Spring entry animation: fade + scale-up.
        if let layer = backgroundView.layer {
            layer.removeAllAnimations()
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.82
            spring.toValue = 1.0
            spring.damping = 14
            spring.stiffness = 220
            spring.mass = 1
            spring.initialVelocity = 6
            spring.duration = 0.35
            layer.add(spring, forKey: "entry")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }
    }

    func updateLevel(_ level: Float) {
        waveform.updateLevel(level)
    }

    /// Live transcript update — elastically resizes the capsule to fit the text.
    func updateText(_ text: String) {
        textField.alphaValue = 1.0
        textField.alignment = .left
        textField.setGradientMotionEnabled(false)
        textField.stringValue = displayText(for: text)
        let needed = measuredTextWidth(textField.stringValue)
        resize(toTextWidth: needed, animated: true)
    }

    /// Show a transient status (e.g., "Refining…") with a slightly dimmed style.
    func showStatus(_ status: String) {
        textField.alphaValue = 0.7
        textField.alignment = .center
        textField.setGradientMotionEnabled(false)
        textField.stringValue = status
        let needed = measuredTextWidth(status)
        resize(toTextWidth: needed, animated: true)
    }

    func hide(completion: (() -> Void)? = nil) {
        waveform.stopAnimating()
        textField.setGradientMotionEnabled(false)
        if let layer = backgroundView.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 0.86
            scale.duration = 0.22
            scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
            layer.add(scale, forKey: "exit")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.backgroundView.layer?.removeAllAnimations()
            completion?()
        })
    }

    // MARK: - Layout

    private func measuredTextWidth(_ text: String) -> CGFloat {
        let attr = [NSAttributedString.Key.font: textFont]
        let size = (text as NSString).size(withAttributes: attr)
        return ceil(size.width) + 8
    }

    private func displayText(for text: String) -> String {
        guard measuredTextWidth(text) > maxTextWidth else { return text }

        let prefix = "... "
        let characters = Array(text)
        var low = 0
        var high = characters.count
        var best = prefix

        while low <= high {
            let count = (low + high) / 2
            let candidate = prefix + String(characters.suffix(count))
            if measuredTextWidth(candidate) <= maxTextWidth {
                best = candidate
                low = count + 1
            } else {
                high = count - 1
            }
        }

        return best
    }

    private func resize(toTextWidth rawWidth: CGFloat, animated: Bool) {
        let visibleWidth = max(lockedVisibleWidth, min(maxTextWidth, max(minTextWidth, rawWidth)))
        lockedVisibleWidth = visibleWidth
        let totalWidth = textX + visibleWidth + rightPadding
        var frame = panel.frame
        // Keep horizontally centered while growing.
        let centerX = frame.midX
        frame.size.width = totalWidth
        frame.origin.x = centerX - totalWidth / 2

        textClipView.frame = NSRect(
            x: textX,
            y: textY,
            width: visibleWidth,
            height: textHeight
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textField.frame = NSRect(x: 0, y: 0, width: visibleWidth, height: textHeight)
        textField.layer?.removeAnimation(forKey: "scrollText")
        CATransaction.commit()

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        updateShine(width: totalWidth)
    }

    /// Sizes the liquid-glass shine rim to the current capsule width.
    private func updateShine(width: CGFloat) {
        let inset = shineLayer.lineWidth / 2
        let rect = CGRect(x: inset, y: inset, width: width - inset * 2, height: panelHeight - inset * 2)
        let radius = max(0, cornerRadius - inset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shineLayer.frame = CGRect(x: 0, y: 0, width: width, height: panelHeight)
        shineLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    private func position() {
        // This is a menu-bar accessory with no key window, so `NSScreen.main` is
        // unreliable. `screens.first` is the screen containing the menu bar.
        guard let screen = NSScreen.screens.first else { return }
        let vis = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = vis.midX - frame.width / 2
        frame.origin.y = vis.minY + bottomMargin
        panel.setFrame(frame, display: true)
    }
}
