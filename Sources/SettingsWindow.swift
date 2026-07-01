import Cocoa

/// Window for configuring the LLM endpoint used for refinement. Provider and model
/// are chosen from dropdowns (curated from the opencode / models.dev registry). The
/// API Base URL is always shown; it is read-only for known providers and editable
/// only for the "Custom (OpenAI-compatible)" provider, which also reveals an
/// editable Model field.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let providerPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let modelField = NSTextField()          // shown only for the custom provider
    private let baseURLField = NSTextField()        // editable only for the custom provider
    private let baseURLLabel = NSTextField(labelWithString: "API Base URL:")
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLM Refinement Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()
    }

    private let labelWidth: CGFloat = 110
    private let fieldX: CGFloat = 130
    private let fieldWidth: CGFloat = 310

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func label(_ title: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: title)
            l.frame = NSRect(x: 16, y: y, width: labelWidth, height: 22)
            l.alignment = .right
            content.addSubview(l)
            return l
        }
        func style(_ field: NSTextField, y: CGFloat) {
            field.frame = NSRect(x: fieldX, y: y - 2, width: fieldWidth, height: 26)
            field.isEditable = true
            field.isSelectable = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            content.addSubview(field)
        }

        // Provider dropdown.
        _ = label("Provider:", y: 252)
        providerPopup.frame = NSRect(x: fieldX, y: 250, width: fieldWidth, height: 26)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        for provider in LLMProvider.all {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider.id
        }
        content.addSubview(providerPopup)

        // Model dropdown (known providers).
        _ = label("Model:", y: 210)
        modelPopup.frame = NSRect(x: fieldX, y: 208, width: fieldWidth, height: 26)
        content.addSubview(modelPopup)

        // Model text field (custom provider) — occupies the same row as the popup.
        style(modelField, y: 210)
        modelField.placeholderString = "gpt-4o-mini"

        // Base URL (custom provider only).
        baseURLLabel.frame = NSRect(x: 16, y: 168, width: labelWidth, height: 22)
        baseURLLabel.alignment = .right
        content.addSubview(baseURLLabel)
        style(baseURLField, y: 168)
        baseURLField.placeholderString = "https://api.openai.com/v1"

        // API key — read from the environment, not entered here. Shows whether the
        // key was found so the user knows if refinement will work.
        _ = label("API Key:", y: 126)
        apiKeyStatusLabel.frame = NSRect(x: fieldX, y: 128, width: fieldWidth, height: 22)
        apiKeyStatusLabel.font = .systemFont(ofSize: 11)
        apiKeyStatusLabel.textColor = .secondaryLabelColor
        content.addSubview(apiKeyStatusLabel)

        statusLabel.frame = NSRect(x: 16, y: 64, width: 424, height: 40)
        statusLabel.alignment = .left
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        let testButton = NSButton(title: "Test", target: self, action: #selector(testTapped))
        testButton.frame = NSRect(x: 240, y: 18, width: 90, height: 32)
        testButton.bezelStyle = .rounded
        content.addSubview(testButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.frame = NSRect(x: 340, y: 18, width: 100, height: 32)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)
    }

    private var selectedProvider: LLMProvider {
        let id = providerPopup.selectedItem?.representedObject as? String ?? "custom"
        return LLMProvider.provider(id: id)
    }

    private func loadValues() {
        let s = Settings.shared
        let provider = s.llmProvider
        if let index = LLMProvider.all.firstIndex(where: { $0.id == provider.id }) {
            providerPopup.selectItem(at: index)
        }
        baseURLField.stringValue = provider.isCustom ? s.llmBaseURL : provider.baseURL
        modelField.stringValue = provider.isCustom ? s.llmModel : ""
        rebuildModelPopup(selecting: s.llmModel)
        applyProviderVisibility()
        refreshAPIKeyStatus()
    }

    /// Reflects whether the API key was found in the environment. Read-only: the
    /// key is never entered or persisted here.
    private func refreshAPIKeyStatus() {
        let name = Settings.apiKeyEnvName
        if Settings.shared.llmAPIKeyIsSet {
            apiKeyStatusLabel.stringValue = "✓ Set via $\(name)"
            apiKeyStatusLabel.textColor = .systemGreen
        } else {
            apiKeyStatusLabel.stringValue = "✗ Not set ($\(name) or ~/.config/macwhisper/.env)"
            apiKeyStatusLabel.textColor = .systemRed
        }
    }

    /// Populate the model dropdown for the selected provider and select `model`.
    private func rebuildModelPopup(selecting model: String) {
        modelPopup.removeAllItems()
        let provider = selectedProvider
        modelPopup.addItems(withTitles: provider.models)
        if provider.models.contains(model) {
            modelPopup.selectItem(withTitle: model)
        } else if let first = provider.models.first {
            modelPopup.selectItem(withTitle: first)
        }
    }

    /// Show the dropdown for known providers, or the editable Model text field for
    /// the custom provider. The API Base URL row is always visible, but editable
    /// only for the custom (OpenAI-compatible) provider.
    private func applyProviderVisibility() {
        let custom = selectedProvider.isCustom
        modelPopup.isHidden = custom
        modelField.isHidden = !custom
        baseURLField.isEditable = custom
        baseURLField.isSelectable = custom
        baseURLField.textColor = custom ? .labelColor : .secondaryLabelColor
    }

    @objc private func providerChanged() {
        let provider = selectedProvider
        if provider.isCustom {
            if baseURLField.stringValue.isEmpty {
                baseURLField.stringValue = Settings.shared.llmBaseURL
            }
            if modelField.stringValue.isEmpty {
                modelField.stringValue = Settings.shared.llmModel
            }
        } else {
            baseURLField.stringValue = provider.baseURL
            rebuildModelPopup(selecting: provider.defaultModel)
        }
        applyProviderVisibility()
        statusLabel.stringValue = ""
    }

    /// Read the currently-entered values without persisting them. The API key is
    /// always sourced from the environment (never from a field).
    private func currentConfig() -> (provider: LLMProvider, baseURL: String, model: String, key: String) {
        let provider = selectedProvider
        let key = Settings.shared.llmAPIKey
        if provider.isCustom {
            let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return (provider, base, model, key)
        }
        let model = modelPopup.titleOfSelectedItem ?? provider.defaultModel
        return (provider, provider.baseURL, model, key)
    }

    @objc private func saveTapped() {
        let cfg = currentConfig()
        let s = Settings.shared
        s.llmProviderID = cfg.provider.id
        if cfg.provider.isCustom {
            s.llmBaseURL = cfg.baseURL
        }
        s.llmModel = cfg.model
        // API key is intentionally not saved here — it lives in the environment.
        refreshAPIKeyStatus()
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "Saved."
    }

    @objc private func testTapped() {
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing…"
        let cfg = currentConfig()
        LLMRefiner.request(text: "Hello", baseURL: cfg.baseURL, apiKey: cfg.key, model: cfg.model, proto: cfg.provider.proto) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let output):
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = "Success ✓  Response: \(output)"
                case .failure(let error):
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func showWindow() {
        loadValues()
        statusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
