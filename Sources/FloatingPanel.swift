import Cocoa
import QuartzCore

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
    private let textField: NSTextField
    /// Luminous inset rim emulating the CSS `.liquidGlass-shine` highlight
    /// (`box-shadow: inset … rgba(255,255,255,0.5)`) from the reference recipe.
    private let shineLayer = CAShapeLayer()

    private let panelHeight: CGFloat = 56
    private let cornerRadius: CGFloat = 28
    private let leftPadding: CGFloat = 18
    private let waveWidth: CGFloat = 44
    private let waveHeight: CGFloat = 32
    private let gap: CGFloat = 12
    private let minTextWidth: CGFloat = 160
    private let maxTextWidth: CGFloat = 560
    private let bottomMargin: CGFloat = 130

    /// Horizontal space reserved on each side of the transcript so it stays
    /// centered in the capsule (the waveform sits inside the left inset).
    private var sideInset: CGFloat { leftPadding + waveWidth + gap }

    private let textFont = NSFont.systemFont(ofSize: 16, weight: .medium)

    /// Natural height of a single line of the transcript font, used to vertically
    /// center the text within the capsule.
    private var textHeight: CGFloat { ceil(textFont.ascender - textFont.descender + textFont.leading) }
    private var textY: CGFloat { (panelHeight - textHeight) / 2 }

    init() {
        let initialWidth = (leftPadding + waveWidth + gap) * 2 + minTextWidth
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

        textField = NSTextField(labelWithString: "")
        textField.font = textFont
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBezeled = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.drawsBackground = false
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.cell?.usesSingleLineMode = true
        textField.frame = NSRect(
            x: leftPadding + waveWidth + gap,
            y: textY,
            width: minTextWidth,
            height: textHeight
        )
        (textField.cell as? NSTextFieldCell)?.alignment = .center
        // Frame is managed explicitly in resize(); keep left origin fixed.
        textField.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
        contentHost.addSubview(textField)
    }

    // MARK: - Presentation

    func show(placeholder: String) {
        textField.stringValue = placeholder
        textField.alphaValue = 0.55
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
        textField.stringValue = text
        let needed = measuredTextWidth(text)
        resize(toTextWidth: needed, animated: true)
    }

    /// Show a transient status (e.g., "Refining…") with a slightly dimmed style.
    func showStatus(_ status: String) {
        textField.alphaValue = 0.7
        textField.stringValue = status
        let needed = measuredTextWidth(status)
        resize(toTextWidth: needed, animated: true)
    }

    func hide(completion: (() -> Void)? = nil) {
        waveform.stopAnimating()
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
        return min(maxTextWidth, max(minTextWidth, ceil(size.width) + 8))
    }

    private func resize(toTextWidth textWidth: CGFloat, animated: Bool) {
        let totalWidth = sideInset * 2 + textWidth
        var frame = panel.frame
        // Keep horizontally centered while growing.
        let centerX = frame.midX
        frame.size.width = totalWidth
        frame.origin.x = centerX - totalWidth / 2

        textField.frame = NSRect(
            x: sideInset,
            y: textY,
            width: textWidth,
            height: textHeight
        )

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
