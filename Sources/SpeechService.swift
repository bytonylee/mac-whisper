import Foundation
import AVFoundation
import CoreAudio
import Speech

/// Streaming speech recognition built on Apple's Speech framework. Captures audio with
/// AVAudioEngine, feeds it to SFSpeechRecognizer for live partial results, and emits
/// real-time RMS audio levels to drive the waveform.
final class SpeechService {
    /// Live transcription updates (partial + final).
    var onTranscript: ((String) -> Void)?
    /// Real-time normalized RMS level in 0...1 for the waveform.
    var onLevel: ((Float) -> Void)?
    /// Called when recognition stops with the final transcript.
    var onFinished: ((String) -> Void)?
    /// Fired when the silence auto-stop (VAD) ends the session on its own — wired
    /// to the same path as a manual Fn-release so the transcript is finalized.
    var onAutoStop: (() -> Void)?

    // MARK: Silence auto-stop configuration

    /// When true, the session auto-stops after `silenceTimeout` seconds of silence
    /// once the user has spoken at least once, even while Fn is still held.
    var silenceAutoStopEnabled = false
    /// Normalized RMS level (matching `level(from:)`, 0...1) at or above which a
    /// buffer counts as voice activity. Below it is treated as silence/ambient.
    /// Conservative so normal speech easily clears it; calibrate via the diag log.
    var silenceThreshold: Float = 0.02
    /// Continuous silence (seconds) after speech that triggers the auto-stop.
    var silenceTimeout: TimeInterval = 2.5

    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var latestTranscript = ""
    /// Text from recognition segments the recognizer already finalized mid-hold
    /// (it auto-finalizes after pauses); accumulated so push-to-talk dictation
    /// survives across pauses instead of ending the session.
    private var finalizedPrefix = ""
    private var isRunning = false
    private var isStarting = false
    /// True once stop() has been requested (Fn-release or VAD) and we're flushing
    /// the final result. Distinguishes a real session end from the recognizer's
    /// own mid-hold segment finalizations.
    private var isStopping = false
    /// Session generation. Bumped on every start()/cancel() so that every async
    /// path which can fire finish() (the stop() fallback timer and the recognizer
    /// callback) can detect that it belongs to a superseded session and no-op.
    /// Without this, a rapid Fn press during a previous session's flush window
    /// would let the stale session's late finish() tear down the new session.
    private var gen = 0
    /// Cancellable wrapper around the stop() fallback timer so cancel() can kill
    /// it; DispatchQueue.main.asyncAfter returns nothing we can cancel.
    private var stopFallback: DispatchWorkItem?

    /// Serializes access to the fields touched from both the audio tap thread and
    /// the recognition callback thread (vs. main-thread methods). Without this,
    /// `request` could be nilled mid-`append` and `latestTranscript` could be
    /// torn-read while `combinedTranscript` is being built.
    private let stateLock = NSLock()

    /// Timestamp of the last dispatched `onLevel`, used to throttle the ~86 Hz tap
    /// down to the waveform's animation rate so we don't flood the main queue.
    private var lastLevelDispatchAt: Date = .distantPast

    /// Silence-detection (VAD) bookkeeping for the auto-stop feature.
    private var silenceTimer: Timer?
    private var lastVoiceAt = Date()
    private var hasDetectedVoice = false
    /// Loudest level seen this session, written to the diagnostics log so the
    /// voice threshold can be calibrated against real mic input.
    private var sessionPeakLevel: Float = 0

    /// Verbose per-tap / per-callback logging. Off by default — these fire on
    /// the audio tap thread (~86 Hz) and the recognition callback thread, where
    /// NSLog + synchronous diag-file I/O waste real CPU during long recordings.
    /// Flip to true only when calibrating the VAD threshold or debugging.
    private static let debugLogging = false

    /// Full transcript so far: finalized segments plus the in-progress one.
    private var combinedTranscript: String {
        if finalizedPrefix.isEmpty { return latestTranscript }
        if latestTranscript.isEmpty { return finalizedPrefix }
        return finalizedPrefix + " " + latestTranscript
    }

    /// Request microphone + speech permissions up front.
    static func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            let speechOK = speechStatus == .authorized
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async { completion(speechOK && micOK) }
            }
        }
    }

    func start(language: RecognitionLanguage) {
        guard !isRunning, !isStarting else { return }
        // New session generation: any in-flight finish()/fallback from a prior
        // session becomes a no-op. Also drop a pending fallback timer from a
        // previous stop() that never flushed.
        gen &+= 1
        stopFallback?.cancel()
        stopFallback = nil
        isStarting = true
        latestTranscript = ""
        finalizedPrefix = ""
        isStopping = false
        didFinish = false
        hasDetectedVoice = false
        sessionPeakLevel = 0
        lastVoiceAt = Date()
        Self.diag("session start lang=\(language.rawValue) autoStop=\(silenceAutoStopEnabled) thr=\(silenceThreshold)")

        guard let recognizer = SFSpeechRecognizer(locale: language.locale), recognizer.isAvailable else {
            NSLog("MacWhisper: recognizer unavailable for \(language.rawValue)")
            isStarting = false
            return
        }
        self.recognizer = recognizer
        NSLog("MacWhisper[Speech]: starting language=\(language.rawValue) onDevice=\(recognizer.supportsOnDeviceRecognition)")

        // Force the built-in mic for this session: capturing through a Bluetooth
        // headset's mic degrades it to 16 kHz HFP (muffled output + poor accuracy).
        // Must be set before the engine is created so the input node binds to it.
        // The HAL apply-wait can take up to 1 s, so do it off the main thread to
        // avoid freezing the UI / Fn HID callback during session start.
        DispatchQueue.global(qos: .userInitiated).async {
            SystemAudio.useBuiltInInput()
            DispatchQueue.main.async { self.startEngine() }
        }
    }

    private func startEngine() {
        // Bail if the session was cancelled (Fn released) during the off-main input
        // switch — finish() already ran and delivered an empty result.
        guard isStarting, !isRunning, !didFinish else {
            isStarting = false
            return
        }
        guard self.recognizer != nil else { isStarting = false; return }

        // Use a fresh engine each session and release it on teardown so the input
        // HAL client is closed. A retained engine keeps a Bluetooth headset pinned
        // in its low-quality HFP/SCO "call" profile even after the session ends.
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // The input node reports a zero/nil format before it's bound to a device;
        // installing a tap with such a format throws internally.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("MacWhisper[Speech]: invalid input format (rate=\(format.sampleRate) ch=\(format.channelCount))")
            isStarting = false
            cleanup()
            return
        }
        var boundDevice: AudioDeviceID = 0
        if let unit = inputNode.audioUnit {
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &boundDevice, &size)
        }
        Self.diag("input format \(format.sampleRate)Hz ch=\(format.channelCount) engineDevice=\(boundDevice)")

        inputNode.removeTap(onBus: 0)
        var tapBufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            tapBufferCount += 1
            let level = self.level(from: buffer)
            if level > self.sessionPeakLevel { self.sessionPeakLevel = level }
            let voiceActive = level >= self.silenceThreshold
            if Self.debugLogging && (tapBufferCount <= 3 || tapBufferCount % 100 == 0) {
                NSLog("MacWhisper[Speech][DEBUG]: tap #\(tapBufferCount) level=\(level) peak=\(self.sessionPeakLevel) voice=\(voiceActive)")
            }

            // Always forward the raw audio so recognition is never starved (dropping
            // or muting buffers based on a mis-tuned threshold previously broke
            // recognition entirely). The threshold is used only for voice-activity
            // detection below, which drives the silence auto-stop. Capture the
            // request under the lock so it can't be nilled mid-`append` by a
            // concurrent segment restart / cleanup.
            self.stateLock.lock()
            let req = self.request
            self.stateLock.unlock()
            if Self.debugLogging, req == nil, tapBufferCount <= 10 {
                NSLog("MacWhisper[Speech][DEBUG]: tap #\(tapBufferCount) request is NIL — buffer dropped!")
            }
            req?.append(buffer)

            if voiceActive {
                self.hasDetectedVoice = true
                self.lastVoiceAt = Date()
            }
            // Throttle level dispatches to ~50 Hz (the waveform animates at 60 Hz;
            // the tap fires ~86 Hz) so we don't flood the main queue.
            let now = Date()
            if now.timeIntervalSince(lastLevelDispatchAt) >= 0.02 {
                lastLevelDispatchAt = now
                DispatchQueue.main.async { self.onLevel?(level) }
            }
        }

        startRecognitionTask()

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            isStarting = false
            startSilenceMonitor()
            NSLog("MacWhisper[Speech]: audio engine started")
        } catch {
            NSLog("MacWhisper: audio engine failed to start: \(error)")
            isStarting = false
            cleanup()
        }
    }

    /// Creates the recognition request + task. Extracted so a mid-hold segment
    /// finalization can transparently restart a fresh segment (see the callback).
    private var recognitionTaskCount = 0
    private func startRecognitionTask() {
        guard let recognizer else { return }
        recognitionTaskCount += 1
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device when supported for responsiveness/privacy.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        NSLog("MacWhisper[Speech][DEBUG]: startRecognitionTask #\(recognitionTaskCount) onDevice=\(request.requiresOnDeviceRecognition)")

        // Capture the generation this task belongs to so a late callback from a
        // superseded session can't fire finish() on the current one.
        let taskGen = gen
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                if Self.debugLogging {
                    NSLog("MacWhisper[Speech][DEBUG]: callback result isFinal=\(result.isFinal) text='\(result.bestTranscription.formattedString)'")
                }
                self.stateLock.lock()
                self.latestTranscript = result.bestTranscription.formattedString
                let combined = self.combinedTranscript
                self.stateLock.unlock()
                DispatchQueue.main.async { self.onTranscript?(combined) }
            }
            if let error = error {
                let nsError = error as NSError
                NSLog("MacWhisper[Speech]: recognition error=\(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code)")
            }
            let segmentEnded = error != nil || (result?.isFinal ?? false)
            guard segmentEnded else { return }

            self.stateLock.lock()
            let stopping = self.isStopping
            self.stateLock.unlock()
            if stopping {
                // Flushing after Fn-release / VAD — this is the true session end.
                NSLog("MacWhisper[Speech][DEBUG]: segment ended, stopping -> finish()")
                self.finish(expectedGen: taskGen)
            } else {
                // The recognizer finalized a segment on its own (it does this after
                // a pause / on ambient noise). Push-to-talk must keep going until the
                // user releases Fn, so fold this segment in and restart — never end
                // the session here, which previously left the HUD stuck.
                NSLog("MacWhisper[Speech][DEBUG]: segment ended, not stopping -> restart")
                DispatchQueue.main.async {
                    guard self.isRunning, !self.isStopping else { return }
                    self.foldFinalizedSegment()
                    // Cancel/end the finalized segment's task+request before
                    // starting a fresh one. The segment is "final" but the
                    // underlying Speech framework objects can still hold internal
                    // buffers until explicitly ended; over a long hold with many
                    // pause-driven finalizations this previously leaked memory.
                    self.stateLock.lock()
                    self.task?.cancel()
                    self.task = nil
                    self.request?.endAudio()
                    self.request = nil
                    self.stateLock.unlock()
                    self.startRecognitionTask()
                }
            }
        }
    }

    /// Move the in-progress segment text into the accumulated finalized prefix.
    private func foldFinalizedSegment() {
        stateLock.lock()
        let seg = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seg.isEmpty {
            finalizedPrefix = finalizedPrefix.isEmpty ? seg : finalizedPrefix + " " + seg
        }
        latestTranscript = ""
        stateLock.unlock()
    }

    /// Starts the repeating timer that auto-stops the session after a sustained
    /// silence once the user has actually spoken (VAD). Also serves as a safety
    /// net if an Fn key-up HID event is ever missed.
    private func startSilenceMonitor() {
        silenceTimer?.invalidate()
        guard silenceAutoStopEnabled else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func checkSilence() {
        guard isRunning, !isStopping, hasDetectedVoice else { return }
        guard Date().timeIntervalSince(lastVoiceAt) >= silenceTimeout else { return }
        NSLog("MacWhisper[Speech]: silence auto-stop after \(silenceTimeout)s")
        silenceTimer?.invalidate()
        silenceTimer = nil
        onAutoStop?()
    }

    /// Stop capturing audio and end the recognition request; final transcript arrives
    /// via onFinished once the recognizer flushes. Called on Fn-release or VAD.
    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        NSLog("MacWhisper[Speech][DEBUG]: stop() called isRunning=\(isRunning) isStopping=\(isStopping) isStarting=\(isStarting) didFinish=\(didFinish)")
        // If we aren't actively running (e.g. the engine already torn down), still
        // deliver a final result exactly once so the HUD always dismisses.
        guard isRunning, !isStopping else {
            NSLog("MacWhisper[Speech][DEBUG]: stop() -> early finish (not running)")
            finish(expectedGen: gen)
            return
        }
        isStopping = true
        isRunning = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        request?.endAudio()
        onLevel?(0)
        NSLog("MacWhisper[Speech][DEBUG]: stop() -> endAudio sent, waiting for final callback")
        // The recognition callback will fire finish(); guarantee it with a fallback.
        // Stored as a cancellable work item so cancel() can kill it when a new Fn
        // press supersedes this session mid-flush.
        let stopGen = gen
        let fallback = DispatchWorkItem { [weak self] in
            NSLog("MacWhisper[Speech][DEBUG]: stop() fallback timer firing finish()")
            self?.finish(expectedGen: stopGen)
        }
        stopFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: fallback)
    }

    /// Hard-abort the current session without delivering a transcript. Used when a
    /// new Fn press supersedes a session that is still flushing its final result
    /// (the window between stop() and the recognizer's onFinished). Bumps the
    /// generation so every stale async finish() — the fallback timer and any late
    /// recognizer callback — becomes a no-op, then tears down audio/resources.
    func cancel() {
        NSLog("MacWhisper[Speech][DEBUG]: cancel() called isRunning=\(isRunning) isStopping=\(isStopping) isStarting=\(isStarting) didFinish=\(didFinish)")
        gen &+= 1
        stopFallback?.cancel()
        stopFallback = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        isRunning = false
        isStarting = false
        isStopping = false
        // Belt-and-suspenders: any in-flight finish() that already passed its
        // generation check before we bumped gen is stopped by didFinish.
        didFinish = true
        cleanup()
        onLevel?(0)
    }

    private var didFinish = false
    private func finish(expectedGen: Int) {
        // Ignore finishes from a superseded session (stale fallback timer or late
        // recognizer callback) and the guaranteed single-delivery guard.
        guard !didFinish, expectedGen == gen else { return }
        didFinish = true
        stopFallback?.cancel()
        stopFallback = nil
        isRunning = false
        isStopping = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        stateLock.lock()
        let transcript = combinedTranscript
        stateLock.unlock()
        NSLog("MacWhisper[Speech][DEBUG]: finish() transcript.len=\(transcript.count) peak=\(sessionPeakLevel) detectedVoice=\(hasDetectedVoice) taskCount=\(recognitionTaskCount)")
        // Log only metadata, never the transcript text — speech content is PII and
        // the diag file lives in a world-readable location.
        Self.diag("session end peakLevel=\(sessionPeakLevel) detectedVoice=\(hasDetectedVoice) chars=\(transcript.count)")
        cleanup()
        DispatchQueue.main.async { [weak self] in self?.onFinished?(transcript) }
    }

    private func cleanup() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        stateLock.lock()
        task?.cancel()
        task = nil
        request = nil
        stateLock.unlock()
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            engine.reset()
        }
        // Drop the only strong reference so the engine deallocates and its input
        // HAL client closes; this lets a Bluetooth headset leave the HFP/SCO call
        // profile and return to high-quality A2DP playback after dictation.
        audioEngine = nil
    }

    /// Reset state for the next session.
    func reset() {
        stateLock.lock()
        latestTranscript = ""
        finalizedPrefix = ""
        isStopping = false
        stateLock.unlock()
        didFinish = false
        hasDetectedVoice = false
    }

    /// Normalized 0...1 RMS level of a capture buffer, used for both the waveform
    /// and the noise gate / silence (VAD) thresholds.
    private func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.format.channelCount > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let samples = channelData[0]

        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        // Map RMS to a perceptual 0...1 range; speech RMS is typically small.
        return min(1.0, max(0.0, rms * 12.0))
    }

    /// Append a line to a diagnostics file so speech/VAD behavior can be inspected
    /// after a test run (unified-log NSLog args are redacted as <private>).
    private static let diagPath = "/tmp/macwhisper-diag.log"
    private static func diag(_ message: String) {
        let line = "\(Date()) \(message)\n"
        NSLog("MacWhisper[Speech]: \(message)")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: diagPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: diagPath))
        }
    }
}
