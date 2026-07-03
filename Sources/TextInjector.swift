import Cocoa
import Carbon

/// Injects text into the focused field via the clipboard + a simulated Cmd+V.
///
/// To stop CJK input methods from intercepting the paste, the current input source is
/// temporarily switched to an ASCII keyboard layout before pasting and restored afterward.
/// The user's original clipboard contents are also saved and restored.
enum TextInjector {

    static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let savedItems = saveClipboard(pasteboard)

        // Temporarily switch away from a CJK input method so Cmd+V isn't swallowed.
        let originalSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let didSwitch = switchToASCIIIfNeeded(current: originalSource)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Remember our write so the deferred restore can tell whether anything
        // else (the user, a clipboard manager) has touched the clipboard since.
        let injectedChangeCount = pasteboard.changeCount

        // Give the input-source switch and clipboard write a moment to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulatePaste()

            // Restore the input source shortly after the paste is delivered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if didSwitch, let original = originalSource {
                    TISSelectInputSource(original)
                }
            }

            // Restore the clipboard much later: the target app reads the
            // pasteboard only when it processes the Cmd+V event, which can lag
            // well past 100 ms in busy/Electron apps — restoring too early
            // makes them paste the user's *old* clipboard instead of the
            // transcript. Skip the restore entirely if someone else has
            // written to the clipboard in the meantime.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard pasteboard.changeCount == injectedChangeCount else { return }
                restoreClipboard(pasteboard, items: savedItems)
            }
        }
    }

    // MARK: - Input source handling

    /// Detects whether the active input source is a CJK input method and, if so, switches
    /// to an ASCII-capable keyboard layout (ABC / U.S.). Returns true if a switch happened.
    private static func switchToASCIIIfNeeded(current: TISInputSource?) -> Bool {
        guard let current, isCJKInputSource(current) else { return false }
        guard let ascii = asciiKeyboardSource() else { return false }
        TISSelectInputSource(ascii)
        return true
    }

    private static func isCJKInputSource(_ source: TISInputSource) -> Bool {
        // CJK input methods are reported as keyboard *input modes* rather than plain
        // keyboard *layouts*. Treat any non-layout source as a CJK/IME source.
        guard let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return false
        }
        let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        let layout = kTISTypeKeyboardLayout as String
        if type == layout {
            return false
        }

        // Confirm via the source's primary language when available.
        if let langPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let langs = Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as? [String] ?? []
            if let first = langs.first {
                return first.hasPrefix("zh") || first.hasPrefix("ja") || first.hasPrefix("ko")
            }
        }
        // Non-layout source with no language info: assume IME and switch to be safe.
        return true
    }

    private static func asciiKeyboardSource() -> TISInputSource? {
        let preferredIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        for id in preferredIDs {
            if let source = inputSource(withID: id) {
                return source
            }
        }
        return nil
    }

    private static func inputSource(withID id: String) -> TISInputSource? {
        let properties = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(properties, false)?.takeRetainedValue() else {
            return nil
        }
        let sources = list as? [TISInputSource] ?? []
        return sources.first
    }

    // MARK: - Paste simulation

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Clipboard save/restore

    private struct ClipboardItem {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private static func saveClipboard(_ pasteboard: NSPasteboard) -> [ClipboardItem] {
        var saved: [ClipboardItem] = []
        guard let types = pasteboard.types else { return saved }
        for type in types {
            if let data = pasteboard.data(forType: type) {
                saved.append(ClipboardItem(type: type, data: data))
            }
        }
        return saved
    }

    private static func restoreClipboard(_ pasteboard: NSPasteboard, items: [ClipboardItem]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        for item in items {
            pasteboard.setData(item.data, forType: item.type)
        }
    }
}
