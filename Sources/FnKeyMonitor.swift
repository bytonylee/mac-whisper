import Foundation
import IOKit.hid

/// Globally monitors the Fn (Function/Globe) modifier key.
///
/// The Fn/Globe key is not delivered reliably through a CGEvent tap on modern
/// Apple Silicon keyboards — it does not report a stable keycode and does not set
/// the `.maskSecondaryFn` flag. Instead we read it directly from the keyboard's
/// HID interface, where it is exposed on the AppleVendor top-case usage page
/// (page 0xFF, usage 0x03). This requires Input Monitoring permission.
final class FnKeyMonitor {
    /// Callbacks receive the HID event capture time. Timing decisions (double-tap
    /// detection) must use it — main-queue dispatch can lag behind the hardware
    /// when the app is busy, which skews Date()-at-handling badly.
    var onFnDown: ((Date) -> Void)?
    var onFnUp: ((Date) -> Void)?
    /// Fired when any real key goes down while Fn is held — the user is using
    /// Fn as a modifier (Fn+arrows, Fn+F-keys, Fn+Backspace…), not dictating.
    var onComboKeyWhileFnHeld: (() -> Void)?

    private var manager: IOHIDManager?
    private var fnDown = false

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

        // Match the keyboard (where the Fn element lives) and, defensively, any
        // device that primarily exposes the AppleVendor top-case page.
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey as String: Int(fnUsagePage),
             kIOHIDDeviceUsageKey as String: Int(fnUsage)],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context = context else { return }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handle(value: value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        self.manager = manager

        NSLog("MacWhisper[Fn]: start opened=\(opened) inputMonitoring=\(hasInputMonitoringAccess)")
        return opened && hasInputMonitoringAccess
    }

    func stop() {
        if let manager = manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)

        if page == fnUsagePage, usage == fnUsage {
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            guard pressed != fnDown else { return }
            fnDown = pressed
            let at = Date()
            NSLog("MacWhisper[Fn]: Fn \(pressed ? "DOWN" : "UP")")

            DispatchQueue.main.async { [weak self] in
                if pressed { self?.onFnDown?(at) } else { self?.onFnUp?(at) }
            }
            return
        }

        // Any real (non-modifier) key pressed while Fn is down means Fn is
        // acting as a modifier for a shortcut. usage >= 4 skips the
        // roll-over/error codes; usage < 0xE0 excludes Ctrl/Shift/Cmd/Opt,
        // which legitimately arrive after Fn in the app's own ⌃Fn / ⌃⇧Fn
        // gestures.
        if fnDown, page == UInt32(kHIDPage_KeyboardOrKeypad),
           usage >= 4, usage < 0xE0,
           IOHIDValueGetIntegerValue(value) != 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onComboKeyWhileFnHeld?()
            }
        }
    }
}
