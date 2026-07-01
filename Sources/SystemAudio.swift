import CoreAudio
import Foundation

/// Mutes the system's default audio output while dictation is active (Fn held)
/// and restores the previous state on release. This prevents the user from
/// hearing the brief Bluetooth A2DP→HFP "blur" that occurs while the mic is
/// capturing, and stops any playback from bleeding into the recording.
enum SystemAudio {
    /// Append a diagnostics line to the shared log so device transitions can be
    /// inspected after a test run (NSLog string args are redacted as <private>).
    private static func diag(_ message: String) {
        let line = "\(Date()) [Audio] \(message)\n"
        NSLog("MacWhisper[Audio]: \(message)")
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/macwhisper-diag.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Whether we muted (vs. the device was already muted) so restore is exact.
    private static var didMute = false
    /// The exact device we muted, so restore targets it even if the default output
    /// device changes while dictating (switching the input to the built-in mic can
    /// re-route a Bluetooth headset, changing which device is "default").
    private static var mutedDevice: AudioDeviceID?
    /// The default input device that was active before we forced the built-in mic,
    /// so it can be restored exactly. nil means we didn't change it.
    private static var savedInputDevice: AudioDeviceID?

    /// Mute the current default output device. Safe to call repeatedly.
    static func muteOutput() {
        guard !didMute, let device = defaultOutputDeviceID() else { return }
        guard mutePropertyIsSettable(device) else {
            NSLog("MacWhisper[Audio]: default output mute not settable; skipping")
            return
        }
        guard currentMute(device) == false else { return } // already muted by user
        if setMute(device, muted: true) {
            didMute = true
            mutedDevice = device
            NSLog("MacWhisper[Audio]: muted output device=\(device)")
        }
    }

    /// Restore output if we were the one who muted it. Targets the exact device we
    /// muted rather than the current default, which may have changed.
    static func restoreOutput() {
        defer { didMute = false; mutedDevice = nil }
        guard didMute, let device = mutedDevice else { return }
        _ = setMute(device, muted: false)
        NSLog("MacWhisper[Audio]: restored output device=\(device)")
    }

    /// Force the system default input to the Mac's built-in microphone. Capturing
    /// through a Bluetooth headset's own mic forces it into the low-quality 16 kHz
    /// HFP "call" profile (muffled output + poor recognition); the built-in mic
    /// keeps the headset in A2DP and gives the recognizer full-rate audio.
    ///
    /// The switch is made once and kept for the app's lifetime (restored on quit
    /// via `restoreInput()`), NOT flipped back after every dictation. Flipping the
    /// global default input on every Fn press/release raced the next session and
    /// intermittently left the engine bound to the wrong device.
    static func useBuiltInInput() {
        guard let builtIn = builtInInputDeviceID() else {
            diag("built-in mic not found; leaving default input")
            return
        }
        let current = defaultInputDeviceID()
        if current == builtIn { return } // already built-in, nothing to do
        // Remember the very first non-built-in default so quit can restore it.
        if savedInputDevice == nil { savedInputDevice = current }
        guard setDefaultInputDevice(builtIn) else { return }
        // The property set returns immediately but the HAL applies it
        // asynchronously; block briefly until it takes effect so the AVAudioEngine
        // (created right after) binds to the built-in mic rather than the old
        // device. Without this the engine captures the previous (Bluetooth) input
        // and recognition gets silence / 16 kHz HFP audio.
        let deadline = Date().addingTimeInterval(1.0)
        var applied = false
        while Date() < deadline {
            if defaultInputDeviceID() == builtIn { applied = true; break }
            usleep(20_000) // 20 ms
        }
        diag("input switch -> builtIn=\(builtIn) was=\(current.map(String.init) ?? "nil") applied=\(applied) final=\(defaultInputDeviceID().map(String.init) ?? "nil")")
    }

    /// Restore the input device we replaced in `useBuiltInInput()`.
    static func restoreInput() {
        guard let previous = savedInputDevice else { return }
        savedInputDevice = nil
        let ok = setDefaultInputDevice(previous)
        diag("input restore -> \(previous) ok=\(ok)")
    }

    // MARK: - CoreAudio plumbing

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func mutePropertyIsSettable(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func currentMute(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress()
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    @discardableResult
    private static func setMute(_ device: AudioDeviceID, muted: Bool) -> Bool {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        if status != noErr {
            NSLog("MacWhisper[Audio]: setMute(\(muted)) failed status=\(status)")
        }
        return status == noErr
    }

    // MARK: - Input device selection

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    @discardableResult
    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value
        )
        if status != noErr {
            NSLog("MacWhisper[Audio]: setDefaultInputDevice failed status=\(status)")
        }
        return status == noErr
    }

    /// The first built-in (non-Bluetooth/USB) input device, or nil if none exists.
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for id in deviceIDs where deviceHasInput(id) && deviceTransportType(id) == kAudioDeviceTransportTypeBuiltIn {
            return id
        }
        return nil
    }

    private static func deviceHasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return false }
        return dataSize > 0
    }

    private static func deviceTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }
}
