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

    private let panelBaseHeight: CGFloat = 56
    private let verticalTextPadding: CGFloat = 24
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
    private func textFieldY(forHeight height: CGFloat, textBlockHeight: CGFloat) -> CGFloat { (height - textBlockHeight) / 2 }

    init() {
        let initialWidth = (leftPadding + waveWidth + gap) * 2 + minTextWidth
        let rect = NSRect(x: 0, y: 0, width: initialWidth, height: panelBaseHeight)

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
            // renders as a near-invisible transparent gray, so use `.regular`.
            // Liquid Glass adapts its look to whatever is behind it, which means
            // a light tint (the original design) turns the capsule near-white —
            // and unreadable — over light backgrounds/pages. A dark tint biases
            // it toward a consistently dark capsule regardless of what's behind,
            // so the white transcript/waveform stay legible everywhere.
            glass.style = .regular
            glass.tintColor = NSColor.black.withAlphaComponent(0.55)
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
        // Liquid Glass's tint alone isn't enough to guarantee contrast — it still
        // lightens noticeably over bright content. A solid dark scrim behind the
        // waveform/text guarantees legibility regardless of what's underneath,
        // while the glass blur/refraction still shows through at ~28% opacity.
        contentHost.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        contentHost.layer?.cornerRadius = cornerRadius
        contentHost.layer?.masksToBounds = true
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
            y: (panelBaseHeight - waveHeight) / 2,
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
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.usesSingleLineMode = false
        textField.frame = NSRect(
            x: leftPadding + waveWidth + gap,
            y: textFieldY(forHeight: panelBaseHeight, textBlockHeight: textHeight),
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
        resize(to: CGSize(width: minTextWidth, height: textHeight), animated: false)
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
        let size = measuredTextSize(for: text)
        resize(to: size, animated: true)
    }

    /// Show a transient status (e.g., "Refining…") with a slightly dimmed style.
    func showStatus(_ status: String) {
        textField.alphaValue = 0.7
        textField.stringValue = status
        let size = measuredTextSize(for: status)
        resize(to: size, animated: true)
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

    /// Measures the space the transcript needs: grows horizontally up to
    /// `maxTextWidth` as a single line, then wraps onto additional lines
    /// (growing the capsule taller) so the full text stays visible.
    private func measuredTextSize(for text: String) -> CGSize {
        let attr = [NSAttributedString.Key.font: textFont]
        let singleLineWidth = ceil((text as NSString).size(withAttributes: attr).width) + 8
        if singleLineWidth <= maxTextWidth {
            return CGSize(width: max(minTextWidth, singleLineWidth), height: textHeight)
        }
        // NSString.boundingRect under-measures wrapped CJK text in practice
        // (it plateaus after ~2 lines regardless of length) — the text field's
        // own cell, which is what actually lays the glyphs out, is reliable.
        let fitting = textField.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: maxTextWidth, height: .greatestFiniteMagnitude)
        ) ?? NSSize(width: maxTextWidth, height: textHeight)
        return CGSize(width: maxTextWidth, height: max(textHeight, ceil(fitting.height)))
    }

    private func resize(to textSize: CGSize, animated: Bool) {
        let totalWidth = sideInset * 2 + textSize.width
        let totalHeight = max(panelBaseHeight, textSize.height + verticalTextPadding)

        var frame = panel.frame
        // Keep horizontally centered while growing; the bottom edge stays
        // anchored (origin.y untouched) so taller capsules grow upward
        // instead of running off the bottom of the screen.
        let centerX = frame.midX
        frame.size.width = totalWidth
        frame.size.height = totalHeight
        frame.origin.x = centerX - totalWidth / 2

        textField.frame = NSRect(
            x: sideInset,
            y: textFieldY(forHeight: totalHeight, textBlockHeight: textSize.height),
            width: textSize.width,
            height: textSize.height
        )
        waveform.frame.origin.y = (totalHeight - waveHeight) / 2

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        updateShine(width: totalWidth, height: totalHeight)
    }

    /// Sizes the liquid-glass shine rim to the current capsule width.
    private func updateShine(width: CGFloat, height: CGFloat) {
        let inset = shineLayer.lineWidth / 2
        let rect = CGRect(x: inset, y: inset, width: width - inset * 2, height: height - inset * 2)
        let radius = max(0, cornerRadius - inset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shineLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
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
