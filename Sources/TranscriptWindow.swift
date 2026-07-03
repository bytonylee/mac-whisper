import Cocoa

/// Standard, resizable window showing the live transcript of a locked
/// (long-form) recording. Replaces the floating HUD for locked sessions: a
/// meeting capture wants a normal window the user can drag, resize, minimize,
/// and tile like any other — opened on demand from the menu-bar menu.
final class TranscriptWindowController: NSWindowController {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Idle")
    private let stopButton = NSButton()

    /// Wired to AppDelegate.stopLockedRecording.
    var onStopRequested: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Whisper Transcript"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 240)
        // Remember the user's size/position across sessions and launches.
        window.setFrameAutosaveName("MacWhisperTranscriptWindow")
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        content.addSubview(scrollView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.title = "Stop & Save"
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.isEnabled = false
        content.addSubview(stopButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: stopButton.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: stopButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -12),

            stopButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stopButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            stopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
    }

    @objc private func stopTapped() {
        onStopRequested?()
    }

    // MARK: - Content updates (main thread)

    /// Replaces the shown transcript, keeping the view pinned to the bottom
    /// unless the user has scrolled up to read something.
    func updateTranscript(_ text: String) {
        let clipView = scrollView.contentView
        let wasNearBottom: Bool
        if let doc = scrollView.documentView {
            let visibleBottom = clipView.bounds.maxY
            wasNearBottom = doc.bounds.height - visibleBottom < 60
        } else {
            wasNearBottom = true
        }
        textView.string = text
        if wasNearBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setRecording(_ recording: Bool) {
        stopButton.isEnabled = recording
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true, window?.frameAutosaveName.isEmpty != false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
