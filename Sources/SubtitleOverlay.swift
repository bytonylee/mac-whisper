import Cocoa

/// Video-caption-style overlay for locked (long-form) recordings: white text on
/// a dim black backdrop, pinned to the very bottom of the screen — lower than
/// the push-to-talk HUD — so it reads like movie subtitles and stays out of the
/// way. Shows the raw recognizer text (pre-LLM) as it arrives. A close button
/// appears on mouse-over; closing hides the captions without touching the
/// recording.
final class SubtitleOverlay {
    /// Fired when the user closes the overlay (recording continues).
    var onCloseRequested: (() -> Void)?

    private let panel: NSPanel
    /// Transparent root hosting the caption box; oversized so the close button
    /// can overhang the box's top-right corner without being clipped.
    private let container: HoverView
    /// The visible black caption box.
    private let captionBox = NSView()
    private let textField: NSTextField
    private let closeButton: NSButton

    private let font = NSFont.systemFont(ofSize: 17, weight: .medium)
    private let hPadding: CGFloat = 18
    private let vPadding: CGFloat = 10
    private let bottomMargin: CGFloat = 14
    private let cornerRadius: CGFloat = 8
    private let maxLines = 2
    /// Roughly the last caption-worth of text to show.
    private let tailLength = 140
    private let closeSize: CGFloat = 20
    /// Extra room above/right of the caption box for the overhanging button.
    private var overhang: CGFloat { closeSize / 2 }

    /// Armed by show(); the panel becomes visible only once real speech text
    /// arrives, so a silent stretch never shows an empty black box.
    private var armed = false
    /// Generation token for flashStatus auto-hide.
    private var flashGen = 0

    init() {
        let rect = NSRect(x: 0, y: 0, width: 400, height: 44)
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
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        container = HoverView(frame: rect)
        panel.contentView = container

        captionBox.wantsLayer = true
        captionBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        captionBox.layer?.cornerRadius = cornerRadius
        container.addSubview(captionBox)

        textField = NSTextField(wrappingLabelWithString: "")
        textField.font = font
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.drawsBackground = false
        textField.isBezeled = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.alignment = .center
        textField.maximumNumberOfLines = maxLines
        textField.lineBreakMode = .byTruncatingHead
        captionBox.addSubview(textField)

        closeButton = NSButton()
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close subtitles")
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        closeButton.isHidden = true
        container.addSubview(closeButton)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        container.onHover = { [weak self] hovering in
            self?.closeButton.isHidden = !hovering
        }
    }

    @objc private func closeTapped() {
        hide()
        onCloseRequested?()
    }

    // MARK: - Presentation

    var isVisible: Bool { panel.isVisible }

    /// Arms the overlay for the session. Nothing is shown yet — the panel
    /// appears with the first real speech text (see update).
    func show() {
        armed = true
        textField.stringValue = ""
    }

    func hide() {
        armed = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    /// Briefly shows a status line (e.g. "● Recording") in the caption spot so
    /// starting/stopping has immediate visual feedback, then hides again after
    /// `duration` unless real speech text has replaced it.
    func flashStatus(_ text: String, duration: TimeInterval = 2.0) {
        flashGen &+= 1
        let myGen = flashGen
        textField.stringValue = text
        layout(for: text)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.flashGen == myGen else { return }
            // No speech arrived meanwhile — fade the badge back out.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.flashGen == myGen else { return }
                self.panel.orderOut(nil)
            })
        }
    }

    /// Splits into sentences on Korean/Latin/CJK sentence-ending punctuation,
    /// keeping the punctuation attached.
    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!。？！".contains(ch) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    /// Feeds the full accumulated transcript; the overlay shows only the tail,
    /// caption-style, and only once there is actual speech to show.
    func update(fullText: String) {
        guard armed else { return }
        // No captions until something was actually said.
        guard fullText.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        // Real-subtitle line breaking: the last two sentences, one per line,
        // so a continuing speech wraps at utterance boundaries instead of
        // stretching into one endless line.
        let recent = Self.sentences(of: String(fullText.suffix(tailLength * 2))).suffix(2)
        var tail = recent.joined(separator: "\n")
        if tail.count > tailLength {
            // A single run-on sentence: fall back to a word-aligned tail and
            // let the label wrap it.
            tail = String(tail.suffix(tailLength))
            if let space = tail.firstIndex(of: " ") {
                tail = String(tail[tail.index(after: space)...])
            }
        }
        textField.stringValue = tail
        layout(for: tail.isEmpty ? " " : tail)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Layout

    private func layout(for text: String) {
        // Prefer the active screen so captions appear where the user is
        // looking (screens.first can be the closed built-in display when an
        // external monitor is the main one).
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vis = screen.visibleFrame
        // Cap the caption width like real subtitles — on wide monitors 70% of
        // the screen let a single line run absurdly long before wrapping.
        let maxTextWidth = min(vis.width * 0.55, 720) - hPadding * 2

        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textHeight = min(ceil(bounding.height), lineHeight * CGFloat(maxLines))
        let textWidth = min(maxTextWidth, max(160, ceil(bounding.width)))

        let boxWidth = textWidth + hPadding * 2
        let boxHeight = textHeight + vPadding * 2
        // The panel is oversized by the button overhang on the top and right.
        let width = boxWidth + overhang
        let height = boxHeight + overhang

        var frame = panel.frame
        frame.size = NSSize(width: width, height: height)
        // Center the caption box (not the oversized panel) on screen.
        frame.origin.x = vis.midX - boxWidth / 2
        frame.origin.y = vis.minY + bottomMargin
        panel.setFrame(frame, display: true)

        captionBox.frame = NSRect(x: 0, y: 0, width: boxWidth, height: boxHeight)
        textField.frame = NSRect(x: hPadding, y: vPadding, width: textWidth, height: textHeight)
        // Close button centered exactly on the box's top-right corner point.
        closeButton.frame = NSRect(
            x: boxWidth - closeSize / 2,
            y: boxHeight - closeSize / 2,
            width: closeSize,
            height: closeSize
        )
    }

    /// Container that reports mouse hover for the close-button reveal.
    private final class HoverView: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
