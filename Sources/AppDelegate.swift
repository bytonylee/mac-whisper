import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let fnMonitor = FnKeyMonitor()
    private let speech = SpeechService()
    private let panel = FloatingPanel()
    private let settingsController = SettingsWindowController()
    private let permissionsController = PermissionsWindowController()

    private var isRecording = false
    private var isFinishing = false

    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestPermissionsAndStart()
        wireSpeech()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Undo any output mute and restore the user's original input device that we
        // switched to the built-in mic while the app was running.
        SystemAudio.restoreOutput()
        SystemAudio.restoreInput()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Mac Whisper")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Hold Fn to talk", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = holdToTalkTitle()
        menu.addItem(header)
        menu.addItem(.separator())

        // Language submenu.
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in RecognitionLanguage.allCases {
            let item = NSMenuItem(title: lang.displayName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = (lang == settings.language) ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // LLM refinement submenu.
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        let toggle = NSMenuItem(title: "Enable Refinement", action: #selector(toggleLLM), keyEquivalent: "")
        toggle.target = self
        // Render the enabled checkmark in the image column (not the state
        // column) so it lines up with the Settings gear icon below.
        toggle.image = settings.llmEnabled ? menuIcon("checkmark") : nil
        llmMenu.addItem(toggle)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = menuIcon("gearshape")
        llmMenu.addItem(settingsItem)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        // Auto-stop the session after sustained silence so it can't be kept alive
        // by background sound / pauses. (A "Noise Gate" toggle previously lived
        // here but was a no-op — audio is always forwarded to the recognizer.)
        let autoStop = NSMenuItem(title: "Auto-stop on Silence", action: #selector(toggleSilenceAutoStop), keyEquivalent: "")
        autoStop.target = self
        autoStop.image = settings.silenceAutoStopEnabled ? menuIcon("checkmark") : nil
        menu.addItem(autoStop)

        menu.addItem(.separator())

        let permItem = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Builds the "Hold 🌐 to talk" header title, rendering the Fn key as the
    /// Apple Globe/Fn key glyph (SF Symbol "globe").
    private func holdToTalkTitle() -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let result = NSMutableAttributedString(string: "Hold ", attributes: textAttrs)

        if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: "Fn")?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)) {
            globe.isTemplate = true
            let attachment = NSTextAttachment()
            attachment.image = globe
            let size = globe.size
            // Align the glyph baseline with the surrounding text.
            attachment.bounds = NSRect(x: 0, y: font.descender, width: size.width, height: size.height)
            result.append(NSAttributedString(attachment: attachment))
        } else {
            result.append(NSAttributedString(string: "Fn", attributes: textAttrs))
        }

        result.append(NSAttributedString(string: " to talk", attributes: textAttrs))
        return result
    }

    /// Builds a small template menu icon from an SF Symbol, sized to align with
    /// the menu text. Template images are tinted by AppKit for light/dark mode.
    private func menuIcon(_ symbol: String) -> NSImage? {
        let pointSize = NSFont.menuFont(ofSize: 0).pointSize
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        image?.isTemplate = true
        return image
    }

    // MARK: - Permissions + monitor

    private func requestPermissionsAndStart() {
        _ = fnMonitor.start()
        fnMonitor.onFnDown = { [weak self] in self?.startRecording() }
        fnMonitor.onFnUp = { [weak self] in self?.stopRecording() }

        // Live-restart the Fn monitor the moment Input Monitoring is granted
        // while the permissions window is open, so the Fn key starts working
        // without an app restart (the Codex "Quit & Reopen" step avoided).
        permissionsController.onInputMonitoringGranted = { [weak self] in
            self?.fnMonitor.stop()
            _ = self?.fnMonitor.start()
        }

        // Show the single combined permissions window only when something is missing.
        if !PermissionsWindowController.allGranted {
            permissionsController.showWindow()
        }
    }

    private func wireSpeech() {
        speech.onLevel = { [weak self] level in self?.panel.updateLevel(level) }
        speech.onTranscript = { [weak self] text in self?.panel.updateText(text) }
        speech.onFinished = { [weak self] text in self?.handleFinalTranscript(text) }
        // Silence auto-stop (VAD) ends the session via the same path as Fn-release.
        speech.onAutoStop = { [weak self] in self?.stopRecording() }
    }

    // MARK: - Recording cycle

    private func startRecording() {
        NSLog("MacWhisper[App]: startRecording isRecording=\(isRecording) isFinishing=\(isFinishing)")
        // A rapid Fn press during the previous session's flush window (between
        // stop() and the recognizer's onFinished) used to be rejected by the
        // isFinishing guard, dropping the press — and the stale session's
        // deferred panel.hide() then dismissed the HUD mid-sequence. Supersede
        // the finishing session instead: hard-cancel it (no transcript injected
        // for the aborted session) and start fresh. speech.cancel() invalidates
        // every stale async finish() via the generation token, so the late
        // onFinished from the old session can't tear down the new one.
        if isFinishing {
            NSLog("MacWhisper[App]: superseding finishing session")
            speech.cancel()
            isFinishing = false
        }
        guard !isRecording else { return }
        isRecording = true
        SystemAudio.muteOutput()
        speech.reset()
        // Apply the current silence auto-stop preference for this session.
        speech.silenceAutoStopEnabled = settings.silenceAutoStopEnabled
        panel.show(placeholder: settings.language.listeningPlaceholder)
        speech.start(language: settings.language)
    }

    private func stopRecording() {
        NSLog("MacWhisper[App]: stopRecording isRecording=\(isRecording)")
        SystemAudio.restoreOutput()
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        speech.stop()
    }

    private func handleFinalTranscript(_ text: String) {
        // Accept the final whenever a session is active — whether it ended via
        // Fn-release, VAD auto-stop, or an unexpected recognizer end — and clear
        // both flags so the HUD always dismisses and we ignore any duplicate.
        guard isRecording || isFinishing else { return }
        isRecording = false
        isFinishing = false

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            finish(with: "")
            return
        }

        if settings.llmEnabled && settings.llmConfigured {
            panel.showStatus("Refining…")
            LLMRefiner.refine(trimmed) { [weak self] result in
                DispatchQueue.main.async {
                    let output: String
                    switch result {
                    case .success(let refined): output = refined
                    case .failure: output = trimmed // fall back to raw transcript
                    }
                    self?.finish(with: output)
                }
            }
        } else {
            finish(with: trimmed)
        }
    }

    private func finish(with text: String) {
        isFinishing = false
        panel.hide {
            if !text.isEmpty {
                TextInjector.inject(text)
            }
        }
    }

    // MARK: - Menu actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = RecognitionLanguage(rawValue: raw) else { return }
        settings.language = lang
        rebuildMenu()
    }

    @objc private func toggleLLM() {
        settings.llmEnabled.toggle()
        if settings.llmEnabled && !settings.llmConfigured {
            openSettings()
        }
        rebuildMenu()
    }

    @objc private func toggleSilenceAutoStop() {
        settings.silenceAutoStopEnabled.toggle()
        rebuildMenu()
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func openPermissions() {
        permissionsController.showWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
