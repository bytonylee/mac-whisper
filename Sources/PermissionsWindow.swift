import Cocoa
import AVFoundation
import Speech
import IOKit.hid
import ApplicationServices

/// A single combined window that lists every permission Mac Whisper needs, shows
/// whether each is granted, and offers a button to grant / open the relevant
/// Settings pane. This replaces the scattered one-off permission prompts.
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {

    private enum Permission: Int, CaseIterable {
        case microphone, speech, inputMonitoring, accessibility

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .speech: return "Speech Recognition"
            case .inputMonitoring: return "Input Monitoring"
            case .accessibility: return "Accessibility"
            }
        }

        func detail(_ lang: RecognitionLanguage) -> String {
            switch lang {
            case .english:
                switch self {
                case .microphone: return "Capture your voice."
                case .speech: return "Transcribe speech to text."
                case .inputMonitoring: return "Detect the Fn key. In Settings, click + and add Mac Whisper."
                case .accessibility: return "Insert text into other apps. In Settings, click + and add Mac Whisper."
                }
            case .korean:
                switch self {
                case .microphone: return "음성을 녹음합니다."
                case .speech: return "음성을 텍스트로 변환합니다."
                case .inputMonitoring: return "Fn 키 입력을 감지합니다. 설정에서 +를 눌러 Mac Whisper를 추가하세요."
                case .accessibility: return "다른 앱에 텍스트를 입력합니다. 설정에서 +를 눌러 Mac Whisper를 추가하세요."
                }
            case .simplifiedChinese:
                switch self {
                case .microphone: return "录制您的语音。"
                case .speech: return "将语音转换为文本。"
                case .inputMonitoring: return "检测 Fn 键。在设置中点按 + 并添加 Mac Whisper。"
                case .accessibility: return "将文本插入其他应用。在设置中点按 + 并添加 Mac Whisper。"
                }
            case .traditionalChinese:
                switch self {
                case .microphone: return "錄製您的語音。"
                case .speech: return "將語音轉換為文字。"
                case .inputMonitoring: return "偵測 Fn 鍵。在設定中按 + 並加入 Mac Whisper。"
                case .accessibility: return "將文字插入其他應用程式。在設定中按 + 並加入 Mac Whisper。"
                }
            case .japanese:
                switch self {
                case .microphone: return "音声を録音します。"
                case .speech: return "音声をテキストに変換します。"
                case .inputMonitoring: return "Fn キーを検出します。設定で + をクリックし、Mac Whisper を追加してください。"
                case .accessibility: return "他のアプリにテキストを入力します。設定で + をクリックし、Mac Whisper を追加してください。"
                }
            }
        }

        var isGranted: Bool {
            switch self {
            case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .speech: return SFSpeechRecognizer.authorizationStatus() == .authorized
            case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            case .accessibility: return AXIsProcessTrusted()
            }
        }

        var settingsURL: String {
            let base = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .microphone: return base + "Privacy_Microphone"
            case .speech: return base + "Privacy_SpeechRecognition"
            case .inputMonitoring: return base + "Privacy_ListenEvent"
            case .accessibility: return base + "Privacy_Accessibility"
            }
        }

        func registerWithTCCIfNeeded() {
            switch self {
            case .microphone, .speech:
                return
            case .inputMonitoring:
                if !isGranted {
                    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                }
            case .accessibility:
                if !isGranted {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
            }
        }
    }

    private var statusLabels: [Int: NSTextField] = [:]
    private var detailLabels: [Int: NSTextField] = [:]
    private var headerLabel: NSTextField?

    static var allGranted: Bool { Permission.allCases.allSatisfy { $0.isGranted } }

    /// Two-line instruction shown at the top of the window, in the user's selected language.
    private static func headerText(_ lang: RecognitionLanguage) -> String {
        switch lang {
        case .english:
            return "Mac Whisper needs the following permissions.\nGrant each one, then return here and click Recheck."
        case .korean:
            return "Mac Whisper을 사용하려면 다음 권한이 필요합니다.\n각 항목을 허용한 뒤 돌아와 Recheck를 클릭하세요."
        case .simplifiedChinese:
            return "Mac Whisper 需要以下权限。\n请逐项授予权限，返回后点按 Recheck。"
        case .traditionalChinese:
            return "Mac Whisper 需要以下權限。\n請逐項授予權限，返回後按 Recheck。"
        case .japanese:
            return "Mac Whisper には次の権限が必要です。\n各項目を許可して戻ったら Recheck をクリックしてください。"
        }
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Whisper Permissions"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let header = NSTextField(wrappingLabelWithString: "")
        header.frame = NSRect(x: 20, y: 320, width: 600, height: 46)
        header.maximumNumberOfLines = 2
        header.lineBreakMode = .byWordWrapping
        header.isEditable = false
        header.isSelectable = false
        header.drawsBackground = false
        header.isBezeled = false
        header.textColor = .secondaryLabelColor
        content.addSubview(header)
        headerLabel = header

        var y: CGFloat = 270
        for permission in Permission.allCases {
            let name = NSTextField(labelWithString: permission.title)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.frame = NSRect(x: 20, y: y + 24, width: 170, height: 20)
            content.addSubview(name)

            let detail = NSTextField(wrappingLabelWithString: "")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 2
            detail.lineBreakMode = .byWordWrapping
            detail.frame = NSRect(x: 20, y: y - 2, width: 330, height: 34)
            content.addSubview(detail)
            detailLabels[permission.rawValue] = detail

            let status = NSTextField(labelWithString: "")
            status.frame = NSRect(x: 370, y: y + 16, width: 110, height: 20)
            content.addSubview(status)
            statusLabels[permission.rawValue] = status

            let button = NSButton(title: "Open Settings", target: self, action: #selector(grantTapped(_:)))
            button.bezelStyle = .rounded
            button.tag = permission.rawValue
            button.frame = NSRect(x: 490, y: y + 12, width: 130, height: 28)
            content.addSubview(button)

            y -= 58
        }

        let recheck = NSButton(title: "Recheck", target: self, action: #selector(recheckTapped))
        recheck.bezelStyle = .rounded
        recheck.frame = NSRect(x: 400, y: 18, width: 100, height: 32)
        content.addSubview(recheck)

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 520, y: 18, width: 100, height: 32)
        content.addSubview(done)

        refresh()
    }

    private func refresh() {
        let lang = Settings.shared.language
        headerLabel?.stringValue = Self.headerText(lang)
        for permission in Permission.allCases {
            detailLabels[permission.rawValue]?.stringValue = permission.detail(lang)
            guard let label = statusLabels[permission.rawValue] else { continue }
            if permission.isGranted {
                label.stringValue = "✓ Granted"
                label.textColor = .systemGreen
            } else {
                label.stringValue = "Not granted"
                label.textColor = .systemRed
            }
        }
    }

    @objc private func grantTapped(_ sender: NSButton) {
        guard let permission = Permission(rawValue: sender.tag) else { return }
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    DispatchQueue.main.async { self?.refresh() }
                }
            } else {
                openSettings(permission)
            }
        case .speech:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                    DispatchQueue.main.async { self?.refresh() }
                }
            } else {
                openSettings(permission)
            }
        case .inputMonitoring:
            openSettingsAfterRegistering(permission)
        case .accessibility:
            openSettingsAfterRegistering(permission)
        }
    }

    private func openSettingsAfterRegistering(_ permission: Permission) {
        permission.registerWithTCCIfNeeded()

        // Let TCC finish adding the app before System Settings loads the pane,
        // otherwise the list can open before "Mac Whisper" appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.openSettings(permission)
        }
    }

    private func openSettings(_ permission: Permission) {
        if let url = URL(string: permission.settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheckTapped() { refresh() }

    @objc private func doneTapped() { window?.close() }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func showWindow() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
