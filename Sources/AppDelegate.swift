import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let fnMonitor = FnKeyMonitor()
    private let speech = SpeechService()
    /// Long-form engine (SpeechAnalyzer) used only for locked recordings, where
    /// long silences are normal and SFSpeechRecognizer's dictation model breaks.
    private let longForm = LongFormTranscriber()
    private let panel = FloatingPanel()
    private let transcriptWindow = TranscriptWindowController()
    private let subtitles = SubtitleOverlay()
    private let settingsController = SettingsWindowController()
    private let keySettingsController = KeySettingsWindowController()
    private let permissionsController = PermissionsWindowController()

    private var isRecording = false
    private var isFinishing = false

    /// Locked (hands-free) recording: started with a quick double-tap of Fn or
    /// from the menu, ended with a single Fn tap. The transcript is written to a
    /// file instead of pasted, so long captures never touch the clipboard.
    private var isLockedRecording = false
    /// When the current locked session started (guards instant re-toggle).
    private var lockStartedAt = Date.distantPast
    /// True between the stop gesture and the session's final delivery, so
    /// extra presses while the transcript drains can't retrigger anything.
    private var lockStopping = false

    /// What the current Fn hold resolved to. Modifiers are re-checked while Fn
    /// is held (see evaluateFnHold), so Ctrl/Shift may be pressed before or
    /// after Fn in any order.
    private enum FnHoldAction { case undecided, pushToTalk, lockToggle }
    private var fnHoldAction: FnHoldAction = .undecided
    private var fnHoldTimer: Timer?
    private var fnHoldStartedAt = Date.distantPast
    /// When Ctrl (without Shift) was first seen during this hold — start of
    /// the Shift-detection delay.
    private var ctrlOnlySince: Date?
    /// Keeps the system awake during a locked recording session.
    private var sleepActivity: NSObjectProtocol?
    /// Timestamp naming the current locked session's output files.
    private var lockSessionStamp: String?
    /// In-progress transcript autosave for the locked session (crash recovery).
    private var lockAutosaveURL: URL?
    private var lastAutosaveAt = Date.distantPast

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
        // Remember the item's menu-bar position across launches.
        statusItem.autosaveName = "MacWhisperStatusItem"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Mac Whisper")
            button.image?.isTemplate = true
        }
        rebuildMenu()
        // Diagnose "icon not visible" reports: log where the item actually landed
        // (an x past the notch's left edge means macOS hid it behind the notch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let button = self.statusItem.button, let window = button.window else {
                NSLog("MacWhisper[App]: status item has no window (not visible)")
                return
            }
            let frame = window.frame
            let screen = NSScreen.main?.frame ?? .zero
            NSLog("MacWhisper[App]: status item frame=\(frame) screen=\(screen) visible=\(self.statusItem.isVisible)")
            let line = "\(Date()) statusItem x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) screenW=\(Int(screen.width)) visible=\(self.statusItem.isVisible)\n"
            if let data = line.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: "/tmp/macwhisper-diag.log") {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/macwhisper-diag.log"))
                }
            }
        }
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

        // Locked (hands-free) recording: double-tap Fn or use this item; the
        // transcript is saved to ~/Documents/MacWhisper instead of pasted.
        let lockTitle = isLockedRecording
            ? "Stop Locked Recording & Save"
            : "Start Locked Recording"
        let lockItem = NSMenuItem(title: lockTitle, action: #selector(toggleLockedRecording), keyEquivalent: "")
        lockItem.target = self
        lockItem.image = menuIcon(isLockedRecording ? "stop.circle" : "lock.circle")
        menu.addItem(lockItem)

        let windowItem = NSMenuItem(title: "Transcript Window…", action: #selector(openTranscriptWindow), keyEquivalent: "")
        windowItem.target = self
        windowItem.image = menuIcon("text.rectangle.page")
        menu.addItem(windowItem)

        let subtitleItem = NSMenuItem(title: "Subtitle Overlay", action: #selector(toggleSubtitleOverlay), keyEquivalent: "")
        subtitleItem.target = self
        subtitleItem.image = settings.subtitleOverlayEnabled ? menuIcon("checkmark") : nil
        menu.addItem(subtitleItem)

        let notesItem = NSMenuItem(title: "Auto Meeting Notes", action: #selector(toggleMeetingNotes), keyEquivalent: "")
        notesItem.target = self
        notesItem.image = settings.meetingNotesEnabled ? menuIcon("checkmark") : nil
        menu.addItem(notesItem)

        menu.addItem(.separator())

        // Reflect the locked-recording state in the menu-bar icon so a running
        // capture is visible even with no HUD and the window closed.
        if let button = statusItem.button {
            let symbol = isLockedRecording ? "record.circle" : "mic.fill"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mac Whisper")
            button.image?.isTemplate = true
        }

        let keyItem = NSMenuItem(title: "Trigger Key…", action: #selector(openKeySettings), keyEquivalent: "")
        keyItem.target = self
        keyItem.image = menuIcon("keyboard")
        menu.addItem(keyItem)

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
        let result = NSMutableAttributedString(string: "Hold ⌃", attributes: textAttrs)

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
        fnMonitor.customTrigger = settings.triggerKey
        fnMonitor.longTrigger = settings.longTriggerKey
        _ = fnMonitor.start()
        fnMonitor.onFnDown = { [weak self] at, source in self?.handleFnDown(at: at, source: source) }
        fnMonitor.onFnUp = { [weak self] at in self?.handleFnUp(at: at) }
        fnMonitor.onComboKeyWhileFnHeld = { [weak self] in self?.handleFnCombo() }
        fnMonitor.onLongTriggerDown = { [weak self] in
            SpeechService.diag("long trigger key -> toggle locked")
            self?.toggleLockHotkey()
        }
        keySettingsController.fnMonitor = fnMonitor
        keySettingsController.onTriggerChanged = { [weak self] in
            guard let self else { return }
            self.fnMonitor.customTrigger = self.settings.triggerKey
            self.fnMonitor.longTrigger = self.settings.longTriggerKey
        }

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
        speech.onTranscript = { [weak self] text in
            self?.panel.updateText(text)
            self?.autosaveLockedTranscript(text)
        }
        speech.onFinished = { [weak self] text in self?.handleFinalTranscript(text) }
        // Silence auto-stop (VAD) ends the session via the same path as Fn-release.
        speech.onAutoStop = { [weak self] in self?.stopRecording() }

        // Locked (long-form) sessions render into the transcript window — a
        // normal draggable/resizable window — instead of the floating HUD.
        longForm.onTranscript = { [weak self] text in
            self?.transcriptWindow.updateTranscript(text)
            self?.subtitles.update(fullText: text)
            self?.autosaveLockedTranscript(text)
        }
        longForm.onFinished = { [weak self] text in self?.handleLockedFinished(text) }
        transcriptWindow.onStopRequested = { [weak self] in self?.stopLockedRecording() }
        // Closing the subtitles hides them for this session only; the recording
        // itself keeps running.
        subtitles.onCloseRequested = { }
    }

    // MARK: - Recording cycle

    /// How long a ⌃Fn press waits for a possible Shift before starting
    /// push-to-talk. Users aiming for ⌃⇧Fn may land Shift a beat after Fn;
    /// without this delay that would misfire a short dictation session.
    private static let shiftDetectionDelay: TimeInterval = 0.15
    /// Ignore the lock hotkey again for this long after locking, so holding
    /// the combo a beat too long can't immediately stop the new session.
    private static let lockToggleGrace: TimeInterval = 1.5

    /// How long after Fn goes down we keep watching for Ctrl/Shift to arrive.
    /// Modifiers may be pressed in any order; past this window a bare Fn hold
    /// is just the system Globe key and we stand down.
    private static let modifierArrivalWindow: TimeInterval = 1.0

    /// Which trigger key started the current hold. The Apple Fn requires Ctrl
    /// (⌃Fn); a custom trigger key (Right Ctrl by default) fires on its own.
    private var fnHoldSource: FnKeyMonitor.TriggerSource = .appleFn

    private func handleFnDown(at now: Date, source: FnKeyMonitor.TriggerSource) {
        SpeechService.diag("trigger down source=\(source) locked=\(isLockedRecording)")
        fnHoldAction = .undecided
        fnHoldSource = source
        ctrlOnlySince = nil
        fnHoldStartedAt = now
        // Evaluate immediately (modifiers already down), then keep polling
        // while Fn is held so Ctrl/Shift pressed *after* Fn still trigger.
        evaluateFnHold()
        guard fnHoldAction == .undecided else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.evaluateFnHold()
        }
        RunLoop.main.add(timer, forMode: .common)
        fnHoldTimer = timer
    }

    private func stopFnHoldTimer() {
        fnHoldTimer?.invalidate()
        fnHoldTimer = nil
    }

    private func evaluateFnHold() {
        guard fnHoldAction == .undecided else {
            stopFnHoldTimer()
            return
        }
        let mods = NSEvent.modifierFlags
        // The Apple Fn key needs Ctrl held (⌃Fn); a custom trigger chord fires
        // when all of its required modifiers are held with it.
        let chord = settings.triggerKey
        let baseSatisfied = fnHoldSource == .custom
            ? FnKeyMonitor.modifiersSatisfied(chord)
            : mods.contains(.control)
        // The +Shift lock upgrade only applies when Shift is not already part
        // of the chord itself (otherwise dictation would be unreachable).
        let shiftUpgrades = fnHoldSource == .appleFn || !chord.modifiers.contains(.shift)

        // Trigger+Shift: toggle locked (long-form) recording.
        if baseSatisfied && shiftUpgrades && mods.contains(.shift) {
            fnHoldAction = .lockToggle
            stopFnHoldTimer()
            SpeechService.diag("trigger+shift -> toggle locked (locked=\(isLockedRecording))")
            toggleLockHotkey()
            return
        }

        // Trigger alone: push-to-talk — held through the Shift-detection delay
        // first so a Shift landing a beat later upgrades to the lock toggle
        // instead of misfiring a dictation session.
        if baseSatisfied {
            if ctrlOnlySince == nil { ctrlOnlySince = Date() }
            if Date().timeIntervalSince(ctrlOnlySince!) >= Self.shiftDetectionDelay {
                stopFnHoldTimer()
                guard !isLockedRecording else { return }
                fnHoldAction = .pushToTalk
                startRecording()
            }
            return
        }

        // Ctrl was released (or never pressed) — reset the delay clock and
        // give up once the arrival window passes: it's a bare Fn / Globe use.
        ctrlOnlySince = nil
        if Date().timeIntervalSince(fnHoldStartedAt) > Self.modifierArrivalWindow {
            stopFnHoldTimer()
        }
    }

    private func toggleLockHotkey() {
        if isLockedRecording {
            guard !lockStopping else { return }
            guard Date().timeIntervalSince(lockStartedAt) > Self.lockToggleGrace else { return }
            stopLockedRecording()
        } else {
            startLockedRecording()
        }
    }

    /// The user pressed another key while holding Fn — Fn is acting as a
    /// modifier (Fn+arrows, Fn+Backspace, F-keys…). Cancel any push-to-talk
    /// that misfired from ⌃Fn overlapping the combo.
    private var fnComboActive = false
    private func handleFnCombo() {
        guard !fnComboActive else { return }
        fnComboActive = true
        stopFnHoldTimer()
        let wasPushToTalk = fnHoldAction == .pushToTalk
        fnHoldAction = .lockToggle // sentinel: nothing more may start this hold
        // A locked recording must survive Fn combos untouched.
        guard !isLockedRecording, wasPushToTalk, isRecording || isFinishing else { return }
        NSLog("MacWhisper[App]: Fn combo detected — canceling push-to-talk")
        SpeechService.diag("fn combo -> push-to-talk canceled")
        speech.cancel()
        isRecording = false
        isFinishing = false
        SystemAudio.restoreOutput()
        panel.hide()
    }

    private func handleFnUp(at now: Date) {
        fnComboActive = false
        stopFnHoldTimer()
        let action = fnHoldAction
        fnHoldAction = .undecided
        ctrlOnlySince = nil
        // Only a push-to-talk hold ends on Fn release; a locked session keeps
        // running, and an undecided hold never started anything.
        guard action == .pushToTalk, !isLockedRecording else { return }
        stopRecording()
    }

    // MARK: - Locked (hands-free) recording

    private func startLockedRecording() {
        guard !isLockedRecording else { return }
        NSLog("MacWhisper[App]: locked recording started")
        // Tear down the short push-to-talk session left over from the
        // double-tap's first tap; the locked session uses the long-form engine.
        // cancel() suppresses that session's onFinished on purpose, which also
        // suppresses the HUD dismissal that normally rides on it — so hide the
        // HUD explicitly or it lingers on screen for the whole locked session.
        if isRecording || isFinishing {
            speech.cancel()
            isRecording = false
            isFinishing = false
        }
        panel.hide()
        isLockedRecording = true
        lockStartedAt = Date()
        lockStopping = false
        stopFnHoldTimer()
        // Belt-and-suspenders for long captures: back up the raw audio and
        // autosave the partial transcript so neither a recognition failure nor
        // a crash can silently lose the recording.
        let stamp = Self.fileTimestamp()
        lockSessionStamp = stamp
        let dir = Self.transcriptsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        longForm.audioBackupURL = dir.appendingPathComponent("recording-\(stamp).m4a")
        lockAutosaveURL = dir.appendingPathComponent(".inprogress-\(stamp).txt")
        lastAutosaveAt = .distantPast
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "MacWhisper locked recording")
        // Note: unlike push-to-talk, locked recording does NOT mute the system
        // output — meeting audio must stay audible, and the mute was silencing
        // the start-feedback sound itself.
        // No floating HUD for locked sessions — the transcript window (opened
        // from the menu) and the menu-bar icon carry the feedback.
        transcriptWindow.updateTranscript("")
        transcriptWindow.setStatus("● Recording…  (⌃⇧Fn to stop)")
        transcriptWindow.setRecording(true)
        if settings.subtitleOverlayEnabled {
            subtitles.show()
        }
        // Immediate start feedback: without it users assume the toggle didn't
        // register and press again, which stops the recording they just began.
        NSSound(named: "Pop")?.play()
        subtitles.flashStatus("● 녹음 시작")
        longForm.start(language: settings.language)
        rebuildMenu()
    }

    private func stopLockedRecording() {
        guard isLockedRecording, !lockStopping else { return }
        lockStopping = true
        NSLog("MacWhisper[App]: locked recording stopping")
        NSSound(named: "Bottle")?.play()
        subtitles.flashStatus("■ 녹음 종료 — 저장 중…")
        transcriptWindow.setStatus("Finishing…")
        longForm.stop()
    }

    /// Final delivery for a locked session (long-form engine). Locked captures
    /// are persisted to a file, never the clipboard.
    private func handleLockedFinished(_ text: String) {
        guard isLockedRecording else { return }
        isLockedRecording = false
        lockStopping = false
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        transcriptWindow.setRecording(false)
        subtitles.hide()
        finishLockedSession(with: text)
        rebuildMenu()
    }

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
        // Re-read the glossary each session so edits apply without a restart.
        speech.contextualStrings = settings.glossaryTerms
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

    // MARK: - Locked session persistence

    static var transcriptsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacWhisper", isDirectory: true)
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// "yyyy-MM-dd_HH-mm-ss" file stamp → "yyyy-MM-dd HH:mm" for the minutes'
    /// 일시 field.
    private static func meetingDateString(from stamp: String) -> String {
        let parts = stamp.split(separator: "_")
        guard parts.count == 2 else { return stamp }
        let time = parts[1].split(separator: "-")
        guard time.count >= 2 else { return String(parts[0]) }
        return "\(parts[0]) \(time[0]):\(time[1])"
    }

    /// Serial queue for transcript autosaves — atomic writes on the main
    /// thread would stutter the UI during long sessions.
    private let autosaveQueue = DispatchQueue(label: "macwhisper.autosave", qos: .utility)

    /// Continuously mirrors the locked session's partial transcript to disk so a
    /// crash or recognition failure can never lose more than ~2 seconds of text.
    private func autosaveLockedTranscript(_ text: String) {
        guard isLockedRecording, let url = lockAutosaveURL, !text.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutosaveAt) >= 2 else { return }
        lastAutosaveAt = now
        autosaveQueue.async {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Generates structured meeting notes from the raw transcript via the LLM
    /// (glossary included in the prompt) and saves them as notes-<stamp>.md.
    /// Failures only log — the transcript file is already safe on disk.
    private func generateMeetingNotes(from transcript: String, stamp: String, in dir: URL) {
        NSLog("MacWhisper[App]: generating meeting notes chars=\(transcript.count)")
        LLMRefiner.generateMeetingNotes(from: transcript, meetingDate: Self.meetingDateString(from: stamp)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let notes):
                    let url = dir.appendingPathComponent("notes-\(stamp).md")
                    do {
                        try notes.write(to: url, atomically: true, encoding: .utf8)
                        NSLog("MacWhisper[App]: meeting notes saved chars=\(notes.count)")
                        SpeechService.diag("meeting notes saved -> \(url.lastPathComponent)")
                        self.transcriptWindow.setStatus("Meeting notes saved: \(url.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        NSLog("MacWhisper[App]: failed to save meeting notes: \(error)")
                    }
                case .failure(let error):
                    NSLog("MacWhisper[App]: meeting notes failed: \(error.localizedDescription)")
                    SpeechService.diag("meeting notes FAILED: \(error.localizedDescription)")
                    self.transcriptWindow.setStatus("Meeting notes failed — transcript is saved")
                }
            }
        }
    }

    /// Refines a saved long-form transcript with the configured LLM and updates
    /// the file in place. The raw text is already on disk, so any failure —
    /// network, quota, a bad chunk — simply leaves the original content.
    /// Long transcripts are refined in chunks to stay inside response limits.
    private func refineTranscriptFile(_ text: String, at url: URL) {
        let chunks = Self.chunkForRefinement(text, limit: 3000)
        NSLog("MacWhisper[App]: refining transcript in \(chunks.count) chunk(s)")
        var refined: [String] = []
        var anySuccess = false
        func processNext(_ index: Int) {
            if index >= chunks.count {
                guard anySuccess else { return }
                let output = refined.joined(separator: " ")
                if Self.isMeaningfulTranscript(output) {
                    try? output.write(to: url, atomically: true, encoding: .utf8)
                    NSLog("MacWhisper[App]: refined transcript written chars=\(output.count)")
                }
                return
            }
            LLMRefiner.refine(chunks[index]) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        refined.append(text)
                        anySuccess = true
                    case .failure(let error):
                        NSLog("MacWhisper[App]: refine chunk \(index) failed: \(error.localizedDescription)")
                        refined.append(chunks[index])
                    }
                    processNext(index + 1)
                }
            }
        }
        processNext(0)
    }

    /// Splits text into ~limit-sized chunks on sentence/whitespace boundaries.
    private static func chunkForRefinement(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var current = ""
        // Prefer sentence-ish boundaries; fall back to plain words.
        for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
            if current.count + piece.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = String(piece)
            } else {
                current = current.isEmpty ? String(piece) : current + " " + piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// True when the transcript carries actual content — recognizers emit lone
    /// punctuation (".") for silence-only sessions, which isn't worth a file.
    private static func isMeaningfulTranscript(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Persists a finished locked session. The final transcript wins; a useless
    /// final falls back to the last autosave. When nothing meaningful was
    /// recognized: a session with real speech keeps (and reveals) the raw audio
    /// backup so the capture is never lost, while a silence-only session is
    /// discarded entirely — no stray files.
    private func finishLockedSession(with text: String) {
        let stamp = lockSessionStamp ?? Self.fileTimestamp()
        lockSessionStamp = nil
        let autosaveURL = lockAutosaveURL
        lockAutosaveURL = nil
        longForm.audioBackupURL = nil

        var final = text
        if !Self.isMeaningfulTranscript(final), let autosaveURL,
           let autosaved = try? String(contentsOf: autosaveURL, encoding: .utf8) {
            let trimmed = autosaved.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isMeaningfulTranscript(trimmed) {
                NSLog("MacWhisper[App]: final transcript empty; recovered \(trimmed.count) chars from autosave")
                final = trimmed
            }
        }

        let dir = Self.transcriptsDirectory
        if Self.isMeaningfulTranscript(final) {
            let url = dir.appendingPathComponent("transcript-\(stamp).txt")
            do {
                // Save the raw transcript immediately — refinement must never
                // be able to lose the capture.
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try final.write(to: url, atomically: true, encoding: .utf8)
                NSLog("MacWhisper[App]: transcript saved chars=\(final.count)")
                if let autosaveURL { try? FileManager.default.removeItem(at: autosaveURL) }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                // Then refine in place when LLM refinement is configured.
                if settings.llmEnabled && settings.llmConfigured {
                    transcriptWindow.setStatus("Saved — refining with LLM…")
                    refineTranscriptFile(final, at: url)
                } else {
                    transcriptWindow.setStatus("Saved to \(url.lastPathComponent)")
                }
                // Optionally turn the raw transcript into structured meeting
                // notes (independent of the refinement toggle; runs off the
                // raw text so neither task waits on the other).
                if settings.meetingNotesEnabled && settings.llmConfigured {
                    generateMeetingNotes(from: final, stamp: stamp, in: dir)
                }
            } catch {
                NSLog("MacWhisper[App]: failed to save transcript: \(error)")
            }
            return
        }

        if let autosaveURL { try? FileManager.default.removeItem(at: autosaveURL) }
        let audioURL = dir.appendingPathComponent("recording-\(stamp).m4a")
        let hadVoice = longForm.sessionPeakLevel >= 0.02
        if hadVoice {
            // Speech happened but transcription produced nothing usable: keep
            // and reveal the audio so the capture is never silently lost.
            if FileManager.default.fileExists(atPath: audioURL.path) {
                NSLog("MacWhisper[App]: transcript empty despite voice (peak=\(longForm.sessionPeakLevel)); revealing audio backup")
                transcriptWindow.setStatus("No transcript — audio backup kept (\(audioURL.lastPathComponent))")
                NSWorkspace.shared.activateFileViewerSelecting([audioURL])
            }
        } else {
            // Silence-only session: nothing worth keeping.
            NSLog("MacWhisper[App]: silent locked session discarded (peak=\(longForm.sessionPeakLevel))")
            transcriptWindow.setStatus("No speech detected — nothing saved")
            try? FileManager.default.removeItem(at: audioURL)
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

    @objc private func openTranscriptWindow() {
        transcriptWindow.showWindow()
    }

    @objc private func toggleMeetingNotes() {
        settings.meetingNotesEnabled.toggle()
        // Notes need an LLM; open settings when none is configured yet.
        if settings.meetingNotesEnabled && !settings.llmConfigured {
            openSettings()
        }
        rebuildMenu()
    }

    @objc private func toggleSubtitleOverlay() {
        settings.subtitleOverlayEnabled.toggle()
        // Apply immediately when a locked session is running.
        if isLockedRecording {
            if settings.subtitleOverlayEnabled {
                subtitles.show()
            } else {
                subtitles.hide()
            }
        }
        rebuildMenu()
    }

    @objc private func toggleLockedRecording() {
        if isLockedRecording {
            stopLockedRecording()
        } else {
            startLockedRecording()
        }
    }

    @objc private func toggleSilenceAutoStop() {
        settings.silenceAutoStopEnabled.toggle()
        rebuildMenu()
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func openKeySettings() {
        keySettingsController.showWindow()
    }

    @objc private func openPermissions() {
        permissionsController.showWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
