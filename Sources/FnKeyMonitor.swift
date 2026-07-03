import Cocoa
import Foundation
import IOKit.hid

/// A trigger binding: a physical key plus the modifier keys that must be held
/// with it (e.g. ⌘⇧R). For a bare key the modifier set is empty. When the key
/// itself is a modifier, its own flag is not part of the required set.
struct KeyChord: Equatable {
    var page: UInt32
    var usage: UInt32
    var modifiersRaw: UInt
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiersRaw) }
}

/// Globally monitors the Fn (Function/Globe) modifier key.
///
/// The Fn/Globe key is not delivered reliably through a CGEvent tap on modern
/// Apple Silicon keyboards — it does not report a stable keycode and does not set
/// the `.maskSecondaryFn` flag. Instead we read it directly from the keyboard's
/// HID interface, where it is exposed on the AppleVendor top-case usage page
/// (page 0xFF, usage 0x03). This requires Input Monitoring permission.
final class FnKeyMonitor {
    /// Which physical key produced a trigger event. The Apple Fn key requires
    /// Ctrl to be held (⌃Fn); a custom trigger key fires on its own.
    enum TriggerSource { case appleFn, custom }

    /// Callbacks receive the HID event capture time. Timing decisions (double-tap
    /// detection) must use it — main-queue dispatch can lag behind the hardware
    /// when the app is busy, which skews Date()-at-handling badly.
    var onFnDown: ((Date, TriggerSource) -> Void)?
    var onFnUp: ((Date) -> Void)?
    /// Fired when any real key goes down while Fn is held — the user is using
    /// Fn as a modifier (Fn+arrows, Fn+F-keys, Fn+Backspace…), not dictating.
    var onComboKeyWhileFnHeld: (() -> Void)?
    /// When set, the next key press is delivered here (for the trigger-key
    /// settings capture) instead of being processed, then cleared. Modifiers
    /// held at capture time become part of the chord.
    var captureNextKey: ((KeyChord) -> Void)?

    /// User-configurable trigger chord for dictation (defaults to bare
    /// Left Ctrl). The Apple Fn key always works in addition.
    var customTrigger = KeyChord(page: UInt32(kHIDPage_KeyboardOrKeypad), usage: 0xE0, modifiersRaw: 0)

    /// Optional dedicated chord for the locked (long-form) recording toggle.
    /// When unset, long-form is started with trigger+Shift only.
    var longTrigger: KeyChord?
    /// Fired on the dedicated long-form key's key-down (it's a toggle).
    var onLongTriggerDown: (() -> Void)?
    private var longDown = false

    /// Modifier flags we track for chords.
    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .shift, .option, .command]

    /// The modifier flag a modifier key itself contributes, so a chord bound
    /// to e.g. Left Ctrl doesn't require Ctrl as an *additional* modifier.
    static func ownFlag(for usage: UInt32) -> NSEvent.ModifierFlags {
        switch usage {
        case 0xE0, 0xE4: return .control
        case 0xE1, 0xE5: return .shift
        case 0xE2, 0xE6: return .option
        case 0xE3, 0xE7: return .command
        default: return []
        }
    }

    /// Modifiers currently held, minus the trigger key's own contribution.
    static func heldModifiers(excluding usage: UInt32) -> NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection(relevantModifiers).subtracting(ownFlag(for: usage))
    }

    /// True when every modifier the chord requires is currently held.
    static func modifiersSatisfied(_ chord: KeyChord) -> Bool {
        heldModifiers(excluding: chord.usage).isSuperset(of: chord.modifiers)
    }

    /// Display name for a chord, for the settings UI (e.g. "⌘⇧ + F13").
    static func chordName(_ chord: KeyChord) -> String {
        var prefix = ""
        if chord.modifiers.contains(.control) { prefix += "⌃" }
        if chord.modifiers.contains(.option) { prefix += "⌥" }
        if chord.modifiers.contains(.shift) { prefix += "⇧" }
        if chord.modifiers.contains(.command) { prefix += "⌘" }
        let base = keyName(page: chord.page, usage: chord.usage)
        return prefix.isEmpty ? base : "\(prefix) + \(base)"
    }

    /// Display name for a trigger key, for the settings UI.
    static func keyName(page: UInt32, usage: UInt32) -> String {
        if page == 0xFF, usage == 0x03 { return "Fn (Apple)" }
        let names: [UInt32: String] = [
            0xE0: "Left Ctrl", 0xE1: "Left Shift", 0xE2: "Left Option", 0xE3: "Left Cmd",
            0xE4: "Right Ctrl", 0xE5: "Right Shift", 0xE6: "Right Option", 0xE7: "Right Cmd",
            0x68: "F13", 0x69: "F14", 0x6A: "F15", 0x6B: "F16", 0x6C: "F17", 0x6D: "F18", 0x6E: "F19",
            0x39: "Caps Lock", 0x2C: "Space", 0x35: "`", 0x31: "\\",
        ]
        return names[usage] ?? String(format: "Key 0x%02X", usage)
    }

    private var manager: IOHIDManager?
    private var fnDown = false
    private var customDown = false
    /// NSEvent monitors for modifier-key triggers. Karabiner-Elements seizes
    /// physical keyboards and re-injects events through its virtual keyboard,
    /// but modifiers are not re-injected as HID elements — they only surface
    /// as flagsChanged events. Without these monitors a modifier trigger key
    /// is dead on any Karabiner-processed keyboard.
    private var flagsMonitorGlobal: Any?
    private var flagsMonitorLocal: Any?

    /// HID usage → virtual key code for the eight standard modifiers.
    private static let modifierUsageToKeyCode: [UInt32: UInt16] = [
        0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55,   // left ctrl/shift/opt/cmd
        0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,   // right ctrl/shift/opt/cmd
    ]

    private static func modifierFlagActive(for usage: UInt32, flags: NSEvent.ModifierFlags) -> Bool {
        switch usage {
        case 0xE0, 0xE4: return flags.contains(.control)
        case 0xE1, 0xE5: return flags.contains(.shift)
        case 0xE2, 0xE6: return flags.contains(.option)
        case 0xE3, 0xE7: return flags.contains(.command)
        default: return false
        }
    }
    /// Either trigger key held: Apple Fn/Globe, or the custom trigger key
    /// (Right Ctrl by default) on external keyboards without an Apple Fn.
    private var triggerDown: Bool { fnDown || customDown }

    /// AppleVendor top-case page + KeyboardFn usage that report the Globe/Fn key.
    private let fnUsagePage: UInt32 = 0xFF
    private let fnUsage: UInt32 = 0x03

    /// Whether the process is allowed to listen to HID input (Input Monitoring).
    var hasInputMonitoringAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Starts monitoring. Returns true only when Input Monitoring is granted and
    /// the HID manager opened successfully.
    func start() -> Bool {
        // Prompt for Input Monitoring if it has not been granted yet. This adds the
        // app to System Settings → Privacy & Security → Input Monitoring.
        if !hasInputMonitoringAccess {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match keyboards (where the Fn element lives) and, defensively, keypads
        // and any device that primarily exposes the AppleVendor top-case page —
        // some external keyboards enumerate as keypads or composite devices.
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keypad],
            [kIOHIDDeviceUsagePageKey as String: Int(fnUsagePage),
             kIOHIDDeviceUsageKey as String: Int(fnUsage)],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        // Log every matched keyboard so "my external keyboard does nothing"
        // reports can be diagnosed from the diag file.
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "unknown"
            let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "?"
            SpeechService.diag("hid keyboard matched: \(name) vendor=\(vendor) transport=\(transport)")
        }, nil)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context = context else { return }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handle(value: value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        self.manager = manager

        // Modifier-key triggers need the NSEvent path: Karabiner's virtual
        // keyboard does not re-inject modifiers as HID elements, so a Ctrl/Opt
        // trigger would otherwise be dead on Karabiner-processed keyboards.
        if flagsMonitorGlobal == nil {
            flagsMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
            flagsMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }
        }

        NSLog("MacWhisper[Fn]: start opened=\(opened) inputMonitoring=\(hasInputMonitoringAccess)")
        return opened && hasInputMonitoringAccess
    }

    func stop() {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        if let monitor = flagsMonitorGlobal { NSEvent.removeMonitor(monitor) }
        if let monitor = flagsMonitorLocal { NSEvent.removeMonitor(monitor) }
        flagsMonitorGlobal = nil
        flagsMonitorLocal = nil
    }

    /// flagsChanged path for modifier trigger keys (runs on the main thread).
    /// The HID path stays authoritative for non-modifier keys and the Apple Fn;
    /// the shared down-state guards make duplicate delivery harmless when a
    /// non-Karabiner keyboard reports through both paths.
    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        SpeechService.diag("flagsChanged keyCode=\(keyCode) flags=0x\(String(event.modifierFlags.rawValue, radix: 16)) trigger=(\(customTrigger.page),\(customTrigger.usage))")

        // Modifier capture for the settings window (HID capture misses
        // Karabiner-processed modifiers entirely). Other held modifiers become
        // part of the chord.
        if let capture = captureNextKey,
           let usage = Self.modifierUsageToKeyCode.first(where: { $0.value == keyCode })?.key,
           Self.modifierFlagActive(for: usage, flags: event.modifierFlags) {
            captureNextKey = nil
            let mods = Self.heldModifiers(excluding: usage)
            capture(KeyChord(page: UInt32(kHIDPage_KeyboardOrKeypad), usage: usage, modifiersRaw: mods.rawValue))
            return
        }

        if customTrigger.page == UInt32(kHIDPage_KeyboardOrKeypad),
           let code = Self.modifierUsageToKeyCode[customTrigger.usage], code == keyCode {
            let pressed = Self.modifierFlagActive(for: customTrigger.usage, flags: event.modifierFlags)
            if pressed != customDown {
                updateTrigger(pressed: pressed, source: .custom, label: "Trigger(flags)")
            }
        }

        if let lt = longTrigger, lt.page == UInt32(kHIDPage_KeyboardOrKeypad),
           let code = Self.modifierUsageToKeyCode[lt.usage], code == keyCode {
            let pressed = Self.modifierFlagActive(for: lt.usage, flags: event.modifierFlags)
            if pressed != longDown {
                longDown = pressed
                if pressed, Self.modifiersSatisfied(lt) {
                    NSLog("MacWhisper[Fn]: LongTrigger DOWN (flags)")
                    DispatchQueue.main.async { [weak self] in self?.onLongTriggerDown?() }
                }
            }
        }
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)

        let pressed = IOHIDValueGetIntegerValue(value) != 0

        // Diagnostic: record every modifier/Fn HID event (low volume) so
        // "trigger key does nothing" reports show exactly what arrives.
        if page == fnUsagePage || (page == UInt32(kHIDPage_KeyboardOrKeypad) && usage >= 0xE0 && usage <= 0xE7) {
            SpeechService.diag("hid key page=\(page) usage=\(usage) pressed=\(pressed) trigger=(\(customTrigger.page),\(customTrigger.usage))")
        }

        // Trigger-key capture for the settings window: deliver the next real
        // key press (any keyboard key or the Apple Fn) and swallow it. The
        // modifiers held at that moment become part of the chord, so pressing
        // e.g. ⌘⇧R registers the full combination.
        if let capture = captureNextKey, pressed {
            let isFn = page == fnUsagePage && usage == fnUsage
            let isKeyboardKey = page == UInt32(kHIDPage_KeyboardOrKeypad) && usage >= 4
            if isFn || isKeyboardKey {
                captureNextKey = nil
                DispatchQueue.main.async {
                    let mods = Self.heldModifiers(excluding: usage)
                    capture(KeyChord(page: page, usage: usage, modifiersRaw: mods.rawValue))
                }
                return
            }
        }

        if page == fnUsagePage, usage == fnUsage {
            guard pressed != fnDown else { return }
            updateTrigger(pressed: pressed, source: .appleFn, label: "Fn")
            return
        }

        // Dedicated long-form toggle chord, when configured. Checked before
        // the dictation trigger so binding the same key prefers the long-form
        // action. Fires only when the chord's modifiers are held too.
        if let lt = longTrigger, page == lt.page, usage == lt.usage {
            guard pressed != longDown else { return }
            longDown = pressed
            if pressed, Self.modifiersSatisfied(lt) {
                NSLog("MacWhisper[Fn]: LongTrigger DOWN")
                DispatchQueue.main.async { [weak self] in self?.onLongTriggerDown?() }
            }
            return
        }

        // The configurable trigger key (Right Ctrl by default) acts as the Fn
        // substitute on external (Windows) keyboards.
        if page == customTrigger.page, usage == customTrigger.usage {
            guard pressed != customDown else { return }
            updateTrigger(pressed: pressed, source: .custom, label: "Trigger")
            return
        }

        // Any real (non-modifier) key pressed while a trigger is down means it
        // is acting as a modifier for a shortcut. usage >= 4 skips the
        // roll-over/error codes; usage < 0xE0 excludes Ctrl/Shift/Cmd/Opt,
        // which legitimately arrive after Fn in the app's own ⌃Fn / ⌃⇧Fn
        // gestures.
        if triggerDown, page == UInt32(kHIDPage_KeyboardOrKeypad),
           usage >= 4, usage < 0xE0, pressed {
            DispatchQueue.main.async { [weak self] in
                self?.onComboKeyWhileFnHeld?()
            }
        }
    }

    /// Applies a trigger-key state change and fires down/up only when the
    /// combined trigger state actually flips, so holding Fn and the custom
    /// trigger together can't double-fire.
    ///
    /// The key state is selected by `source` instead of being passed inout:
    /// an inout binding overlapping the `triggerDown` getter (which reads the
    /// same stored properties) is a Swift exclusivity violation that aborted
    /// the app the moment any trigger key was pressed.
    private func updateTrigger(pressed: Bool, source: TriggerSource, label: String) {
        let before = triggerDown
        switch source {
        case .appleFn: fnDown = pressed
        case .custom: customDown = pressed
        }
        let after = triggerDown
        SpeechService.diag("updateTrigger \(label) pressed=\(pressed) before=\(before) after=\(after)")
        guard before != after else { return }
        let at = Date()
        NSLog("MacWhisper[Fn]: \(label) \(pressed ? "DOWN" : "UP")")
        DispatchQueue.main.async { [weak self] in
            if after { self?.onFnDown?(at, source) } else { self?.onFnUp?(at) }
        }
    }
}
