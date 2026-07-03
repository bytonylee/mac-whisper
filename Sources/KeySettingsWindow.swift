import Cocoa

/// Window for choosing the dictation trigger keys. The Apple Fn key
/// (⌃Fn hold / ⌃⇧Fn lock) always works; these bindings are for external
/// keyboards or personal preference:
/// - Dictation key: hold to dictate, add Shift to toggle long-form
/// - Long-form key (optional): a dedicated key that toggles long-form alone
final class KeySettingsWindowController: NSWindowController, NSWindowDelegate {
    private let shortKeyLabel = NSTextField(labelWithString: "")
    private let shortChangeButton = NSButton()
    private let longKeyLabel = NSTextField(labelWithString: "")
    private let longChangeButton = NSButton()
    private let longClearButton = NSButton()
    private let resetButton = NSButton()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    /// The monitor whose capture mode we borrow while recording a new key.
    var fnMonitor: FnKeyMonitor?
    /// Called after a binding changed so the app can re-apply it.
    var onTriggerChanged: (() -> Void)?

    private enum CaptureTarget { case none, short, long }
    private var capturing: CaptureTarget = .none

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 236),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Trigger Keys"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func rowLabel(_ text: String, y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 20, y: y, width: 120, height: 22)
            content.addSubview(l)
        }

        // Short (push-to-talk) trigger.
        rowLabel("Dictation key:", y: 192)
        shortKeyLabel.frame = NSRect(x: 145, y: 192, width: 130, height: 22)
        shortKeyLabel.font = .boldSystemFont(ofSize: 13)
        content.addSubview(shortKeyLabel)
        shortChangeButton.title = "Change…"
        shortChangeButton.bezelStyle = .rounded
        shortChangeButton.frame = NSRect(x: 280, y: 188, width: 140, height: 30)
        shortChangeButton.target = self
        shortChangeButton.action = #selector(changeShortTapped)
        content.addSubview(shortChangeButton)

        // Long-form toggle trigger (optional).
        rowLabel("Long-form key:", y: 152)
        longKeyLabel.frame = NSRect(x: 145, y: 152, width: 130, height: 22)
        longKeyLabel.font = .boldSystemFont(ofSize: 13)
        content.addSubview(longKeyLabel)
        longChangeButton.title = "Change…"
        longChangeButton.bezelStyle = .rounded
        longChangeButton.frame = NSRect(x: 280, y: 148, width: 140, height: 30)
        longChangeButton.target = self
        longChangeButton.action = #selector(changeLongTapped)
        content.addSubview(longChangeButton)
        longClearButton.title = "Clear"
        longClearButton.bezelStyle = .rounded
        longClearButton.frame = NSRect(x: 280, y: 116, width: 140, height: 30)
        longClearButton.target = self
        longClearButton.action = #selector(clearLongTapped)
        content.addSubview(longClearButton)

        resetButton.title = "Reset to Defaults"
        resetButton.bezelStyle = .rounded
        resetButton.frame = NSRect(x: 20, y: 116, width: 150, height: 30)
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        content.addSubview(resetButton)

        hintLabel.frame = NSRect(x: 20, y: 12, width: 400, height: 96)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = """
        Dictation key: hold to dictate; add Shift to start/stop a long-form \
        recording. Long-form key: optional dedicated key — one press toggles \
        the long-form recording by itself. To register a combination, hold \
        the modifiers and press the key (e.g. ⌘⇧R). The Apple keyboard's ⌃Fn / ⌃⇧Fn \
        always works too. Defaults: hold Left Ctrl to dictate, Left Ctrl+Shift for long-form.
        """
        content.addSubview(hintLabel)

        refresh()
    }

    private func refresh() {
        let s = Settings.shared
        shortKeyLabel.stringValue = FnKeyMonitor.chordName(s.triggerKey)
        if let long = s.longTriggerKey {
            longKeyLabel.stringValue = FnKeyMonitor.chordName(long)
            longClearButton.isEnabled = capturing == .none
        } else {
            longKeyLabel.stringValue = "Trigger + Shift"
            longClearButton.isEnabled = false
        }
        shortChangeButton.title = capturing == .short ? "Press key/combo…" : "Change…"
        longChangeButton.title = capturing == .long ? "Press key/combo…" : "Change…"
        shortChangeButton.isEnabled = capturing == .none
        longChangeButton.isEnabled = capturing == .none
        resetButton.isEnabled = capturing == .none
    }

    private func beginCapture(_ target: CaptureTarget) {
        guard let fnMonitor, capturing == .none else { return }
        capturing = target
        refresh()
        fnMonitor.captureNextKey = { [weak self] chord in
            guard let self else { return }
            let target = self.capturing
            self.capturing = .none
            switch target {
            case .short:
                Settings.shared.triggerKey = chord
            case .long:
                Settings.shared.longTriggerKey = chord
            case .none:
                break
            }
            self.onTriggerChanged?()
            self.refresh()
        }
    }

    @objc private func changeShortTapped() { beginCapture(.short) }
    @objc private func changeLongTapped() { beginCapture(.long) }

    @objc private func clearLongTapped() {
        Settings.shared.longTriggerKey = nil
        onTriggerChanged?()
        refresh()
    }

    @objc private func resetTapped() {
        Settings.shared.triggerKey = KeyChord(page: 0x07, usage: 0xE0, modifiersRaw: 0)
        Settings.shared.longTriggerKey = nil
        onTriggerChanged?()
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        // Abandon a pending capture so a later key press doesn't rebind.
        fnMonitor?.captureNextKey = nil
        capturing = .none
    }

    func showWindow() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
