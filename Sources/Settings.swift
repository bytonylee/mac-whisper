import Foundation

/// Supported recognition languages exposed in the menu bar.
enum RecognitionLanguage: String, CaseIterable {
    case english = "en-US"
    case korean = "ko-KR"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case japanese = "ja-JP"

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// "Listening…" placeholder shown in the HUD, localized to this language.
    var listeningPlaceholder: String {
        switch self {
        case .english: return "Listening…"
        case .korean: return "듣고 있어요…"
        case .simplifiedChinese: return "聆听中…"
        case .traditionalChinese: return "聆聽中…"
        case .japanese: return "聞き取り中…"
        }
    }
}

/// Thin wrapper around UserDefaults for persisted configuration.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language = "recognitionLanguage"
        static let llmEnabled = "llmEnabled"
        static let llmProvider = "llmProvider"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
        static let silenceAutoStop = "silenceAutoStopEnabled"
        static let glossaryPath = "glossaryPath"
        static let subtitleOverlay = "subtitleOverlayEnabled"
        static let triggerKeyPage = "triggerKeyPage"
        static let triggerKeyUsage = "triggerKeyUsage"
        static let triggerKeyMods = "triggerKeyModifiers"
        static let longTriggerKeyPage = "longTriggerKeyPage"
        static let longTriggerKeyUsage = "longTriggerKeyUsage"
        static let longTriggerKeyMods = "longTriggerKeyModifiers"
        static let meetingNotes = "meetingNotesEnabled"
    }

    /// Environment variable name holding the LLM API key. Set it via
    /// `launchctl setenv MACWHISPER_LLM_API_KEY <key>` (persists for GUI launches)
    /// or place `MACWHISPER_LLM_API_KEY=<key>` in `~/.config/macwhisper/.env`.
    /// For development, a repo-local `.env` (gitignored) is sourced by `make run`.
    static let apiKeyEnvName = "MACWHISPER_LLM_API_KEY"

    /// Path to an optional user-level env file consulted when the process
    /// environment doesn't carry the key (e.g. an installed app launched from
    /// Finder). Lives outside any repo so it's never committed.
    private static var apiKeyFilePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macwhisper/.env")
    }

    /// Loads `KEY=VALUE` lines from a `.env`-style file into a dictionary.
    /// Ignores blank lines and `#` comments; trims surrounding whitespace and
    /// optional single/double quotes around the value.
    private static func loadEnvFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
                (val.hasPrefix("'") && val.hasSuffix("'")) {
                val.removeFirst(); val.removeLast()
            }
            out[key] = val
        }
        return out
    }

    private init() {
        // Default language is English; the user can switch to any other from the menu.
        if defaults.string(forKey: Keys.language) == nil {
            defaults.set(RecognitionLanguage.english.rawValue, forKey: Keys.language)
        }
        // Silence auto-stop defaults on so ambient noise / pauses don't keep a
        // session alive. register() supplies the default without overriding a
        // user's choice.
        defaults.register(defaults: [
            Keys.silenceAutoStop: true,
            Keys.subtitleOverlay: true,
        ])
    }

    var language: RecognitionLanguage {
        get {
            let raw = defaults.string(forKey: Keys.language) ?? RecognitionLanguage.english.rawValue
            return RecognitionLanguage(rawValue: raw) ?? .english
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.language) }
    }

    var llmEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmEnabled) }
    }

    /// Auto-stop the session after a sustained silence (VAD); also a safety net if
    /// an Fn key-up is missed.
    var silenceAutoStopEnabled: Bool {
        get { defaults.bool(forKey: Keys.silenceAutoStop) }
        set { defaults.set(newValue, forKey: Keys.silenceAutoStop) }
    }

    /// Selected provider id from `LLMProvider.all` (e.g. "openai"), or "custom".
    var llmProviderID: String {
        get { defaults.string(forKey: Keys.llmProvider) ?? "openai" }
        set { defaults.set(newValue, forKey: Keys.llmProvider) }
    }

    var llmProvider: LLMProvider { LLMProvider.provider(id: llmProviderID) }

    /// Effective base URL: derived from the selected provider, except for the
    /// custom provider where the user supplies it directly.
    var llmBaseURL: String {
        get {
            let provider = llmProvider
            if provider.isCustom {
                return defaults.string(forKey: Keys.llmBaseURL) ?? ""
            }
            return provider.baseURL
        }
        set { defaults.set(newValue, forKey: Keys.llmBaseURL) }
    }

    /// Wire protocol for the selected provider.
    var llmProtocol: LLMProtocol { llmProvider.proto }

    /// The LLM API key, read from the environment so it is never persisted to
    /// UserDefaults (a plaintext plist on disk). Resolution order:
    ///   1. `MACWHISPER_LLM_API_KEY` in the process environment
    ///      (set via `launchctl setenv`, or inherited when launched from a shell
    ///      that sourced the repo `.env` — e.g. `make run`).
    ///   2. `MACWHISPER_LLM_API_KEY` in `~/.config/macwhisper/.env`.
    /// Returns "" when not found. Read-only; there is no setter.
    var llmAPIKey: String {
        if let value = ProcessInfo.processInfo.environment[Self.apiKeyEnvName],
           !value.isEmpty {
            return value
        }
        return Self.loadEnvFile(Self.apiKeyFilePath)[Self.apiKeyEnvName] ?? ""
    }

    /// Whether the API key was resolved from the environment (for UI status).
    var llmAPIKeyIsSet: Bool { !llmAPIKey.isEmpty }

    var llmModel: String {
        get { defaults.string(forKey: Keys.llmModel) ?? "gpt-5.4-mini" }
        set { defaults.set(newValue, forKey: Keys.llmModel) }
    }

    /// Generate structured meeting notes with the LLM after a locked
    /// (long-form) recording finishes. Off by default; requires a configured
    /// LLM provider. The glossary is included so domain terms come out right.
    var meetingNotesEnabled: Bool {
        get { defaults.bool(forKey: Keys.meetingNotes) }
        set { defaults.set(newValue, forKey: Keys.meetingNotes) }
    }

    /// Show caption-style subtitles at the bottom of the screen during a
    /// locked (long-form) recording.
    var subtitleOverlayEnabled: Bool {
        get { defaults.bool(forKey: Keys.subtitleOverlay) }
        set { defaults.set(newValue, forKey: Keys.subtitleOverlay) }
    }

    /// Custom trigger key (HID page/usage) for external keyboards. Defaults to
    /// Left Ctrl on the standard keyboard page: hold it to dictate, add Shift
    /// for the long-form toggle. The Apple Fn key (⌃Fn) always works too.
    var triggerKey: KeyChord {
        get {
            let page = defaults.integer(forKey: Keys.triggerKeyPage)
            let usage = defaults.integer(forKey: Keys.triggerKeyUsage)
            let mods = defaults.integer(forKey: Keys.triggerKeyMods)
            guard page > 0, usage > 0 else { return KeyChord(page: 0x07, usage: 0xE0, modifiersRaw: 0) }
            return KeyChord(page: UInt32(page), usage: UInt32(usage), modifiersRaw: UInt(mods))
        }
        set {
            defaults.set(Int(newValue.page), forKey: Keys.triggerKeyPage)
            defaults.set(Int(newValue.usage), forKey: Keys.triggerKeyUsage)
            defaults.set(Int(newValue.modifiersRaw), forKey: Keys.triggerKeyMods)
        }
    }

    /// Optional dedicated chord toggling the locked (long-form) recording.
    /// nil = not set; trigger+Shift is then the only long-form gesture.
    var longTriggerKey: KeyChord? {
        get {
            let page = defaults.integer(forKey: Keys.longTriggerKeyPage)
            let usage = defaults.integer(forKey: Keys.longTriggerKeyUsage)
            let mods = defaults.integer(forKey: Keys.longTriggerKeyMods)
            guard page > 0, usage > 0 else { return nil }
            return KeyChord(page: UInt32(page), usage: UInt32(usage), modifiersRaw: UInt(mods))
        }
        set {
            defaults.set(Int(newValue?.page ?? 0), forKey: Keys.longTriggerKeyPage)
            defaults.set(Int(newValue?.usage ?? 0), forKey: Keys.longTriggerKeyUsage)
            defaults.set(Int(newValue?.modifiersRaw ?? 0), forKey: Keys.longTriggerKeyMods)
        }
    }

    // MARK: - Glossary

    /// Default glossary location, used when the user hasn't attached a file.
    static var defaultGlossaryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macwhisper/glossary.txt")
    }

    /// Path to the attached glossary text file. One term per line; `#` lines are
    /// comments; `wrong -> right` lines map a common mis-transcription to the
    /// preferred spelling.
    var glossaryURL: URL {
        get {
            if let path = defaults.string(forKey: Keys.glossaryPath), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            return Self.defaultGlossaryURL
        }
        set { defaults.set(newValue.path, forKey: Keys.glossaryPath) }
    }

    /// Raw glossary text for the LLM prompt, capped so a huge file can't blow up
    /// every request. Empty string when the file is missing or empty.
    var glossaryText: String {
        guard let text = try? String(contentsOf: glossaryURL, encoding: .utf8) else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(8000))
    }

    /// Individual terms for speech-recognition hints (SFSpeechRecognizer
    /// contextualStrings). For mapping lines only the right-hand side is a real
    /// term; comments and blanks are skipped.
    var glossaryTerms: [String] {
        var terms: [String] = []
        for rawLine in glossaryText.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let term: String
            if let range = line.range(of: "->") ?? line.range(of: "→") {
                term = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                term = line
            }
            if !term.isEmpty { terms.append(term) }
        }
        return Array(terms.prefix(500))
    }

    /// LLM refinement is usable only when enabled and minimally configured.
    /// The ChatGPT subscription provider authenticates via OAuth, not an API key.
    var llmConfigured: Bool {
        if llmProtocol == .chatgpt {
            return ChatGPTOAuth.shared.isSignedIn &&
                !llmModel.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !llmBaseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !llmAPIKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !llmModel.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
