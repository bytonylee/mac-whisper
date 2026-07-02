import AVFoundation
import Foundation
import Speech

/// Long-form transcription for locked (meeting-style) recordings, built on the
/// macOS 26 SpeechAnalyzer / SpeechTranscriber API.
///
/// Unlike SFSpeechRecognizer — a dictation API that treats sustained silence as
/// a failed utterance and kills the task — SpeechAnalyzer is designed for long,
/// continuous audio: silence is simply "no results yet", so a session can idle
/// through a quiet pre-meeting stretch indefinitely. No segment-restart chain,
/// no error backoff.
///
/// The raw audio is simultaneously written to `audioBackupURL` (AAC) so even a
/// total transcription failure can never lose the capture itself.
final class LongFormTranscriber {
    /// Real-time normalized RMS level in 0...1 for the waveform HUD.
    var onLevel: ((Float) -> Void)?
    /// Full accumulated transcript (finalized + volatile tail), on main.
    var onTranscript: ((String) -> Void)?
    /// Final transcript once the session fully drains, on main. Fires exactly once.
    var onFinished: ((String) -> Void)?
    /// When set, every captured buffer is also written to this file (AAC).
    var audioBackupURL: URL?

    private var audioEngine: AVAudioEngine?
    private var backupFile: AVAudioFile?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var finalizedText = ""
    private var volatileText = ""
    private var isRunning = false
    private var didFinish = false
    private let stateLock = NSLock()
    private var lastLevelDispatchAt = Date.distantPast

    /// Loudest level seen this session — distinguishes "nobody spoke" from
    /// "speech happened but transcription failed" when the transcript is empty.
    private(set) var sessionPeakLevel: Float = 0

    private var combinedTranscript: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        if volatileText.isEmpty { return finalizedText }
        return finalizedText + volatileText
    }

    /// Session generation. Bumped on every start() so a stale async pipeline —
    /// a run() still awaiting model download, a superseded results task, the
    /// stop() fallback timer — can never touch a newer session. Rapid Fn
    /// mashing previously let those overlap and trap inside the Speech
    /// framework (EXC_BREAKPOINT).
    private var gen = 0

    func start(language: RecognitionLanguage) {
        guard !isRunning else { return }
        gen &+= 1
        let myGen = gen
        isRunning = true
        didFinish = false
        finalizedText = ""
        volatileText = ""
        sessionPeakLevel = 0
        tapBufferCount = 0
        Task { await run(language: language, gen: myGen) }
    }

    /// Ends the session: stops capture, lets the analyzer drain, then fires
    /// onFinished with everything transcribed so far.
    func stop() {
        let myGen = gen
        guard isRunning else {
            deliverFinish(gen: myGen)
            return
        }
        isRunning = false
        stopEngine()
        inputBuilder?.finish()
        inputBuilder = nil
        onLevel?(0)
        let analyzer = self.analyzer
        Task {
            // Wait for the analyzer to process everything already yielded, so
            // the last words are not cut off.
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        // Safety net: if the results stream never terminates, deliver anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.deliverFinish(gen: myGen)
        }
    }

    // MARK: - Session pipeline

    private func run(language: RecognitionLanguage, gen myGen: Int) async {
        SpeechService.diag("longform start lang=\(language.rawValue)")
        // The session may be stopped (or superseded) while any of the awaits
        // below are in flight; continuing to set up a dead session corrupts
        // the newer one and can trap inside the Speech framework.
        func stale() -> Bool { myGen != gen || !isRunning }
        do {
            // fastResults trades a little accuracy for much lower latency on
            // the volatile (caption) results; finals are unaffected.
            let transcriber = SpeechTranscriber(
                locale: language.locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )

            // Download the long-form model for this locale if it's missing.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                SpeechService.diag("longform downloading speech assets…")
                try await request.downloadAndInstall()
            }
            guard !stale() else { deliverFinish(gen: myGen); return }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                SpeechService.diag("longform FAILED: no compatible audio format")
                deliverFinish(gen: myGen)
                return
            }
            guard !stale() else { deliverFinish(gen: myGen); return }
            self.transcriber = transcriber
            analyzerFormat = format

            let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: stream)
            guard !stale() else {
                builder.finish()
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                deliverFinish(gen: myGen)
                return
            }
            inputBuilder = builder
            self.analyzer = analyzer

            startResultsTask(transcriber, gen: myGen)

            // Prefer the built-in mic (matches SpeechService behavior) so a
            // Bluetooth headset isn't dragged into low-quality call mode.
            SystemAudio.useBuiltInInput()
            guard !stale() else { deliverFinish(gen: myGen); return }
            try await MainActor.run { try startEngine() }
            SpeechService.diag("longform running")
        } catch {
            SpeechService.diag("longform FAILED: \(error)")
            stopEngine()
            deliverFinish(gen: myGen)
        }
    }

    private func startResultsTask(_ transcriber: SpeechTranscriber, gen myGen: Int) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, myGen == self.gen else { return }
                    let combined = self.fold(text: String(result.text.characters), isFinal: result.isFinal)
                    DispatchQueue.main.async { self.onTranscript?(combined) }
                }
            } catch {
                SpeechService.diag("longform results error: \(error)")
            }
            // Results stream ended — the analyzer has fully drained.
            self?.deliverFinish(gen: myGen)
        }
    }

    /// Merges one recognizer result into the accumulated transcript and returns
    /// the combined text. Synchronous so it is safe to call from the async
    /// results loop without touching the lock in an async context.
    private func fold(text: String, isFinal: Bool) -> String {
        stateLock.lock()
        if isFinal {
            finalizedText += text
            volatileText = ""
        } else {
            volatileText = text
        }
        stateLock.unlock()
        return combinedTranscript
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MacWhisper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid input format"])
        }
        var boundDevice: AudioDeviceID = 0
        if let unit = inputNode.audioUnit {
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &boundDevice, &size)
        }
        SpeechService.diag("longform input \(format.sampleRate)Hz ch=\(format.channelCount) engineDevice=\(boundDevice) analyzerFormat=\(analyzerFormat.map { "\($0.sampleRate)Hz ch=\($0.channelCount)" } ?? "nil")")

        if let url = audioBackupURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            backupFile = try? AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            SpeechService.diag("longform audio backup \(backupFile == nil ? "FAILED" : "recording") -> \(url.lastPathComponent)")
        }

        if let analyzerFormat, analyzerFormat != format {
            converter = AVAudioConverter(from: format, to: analyzerFormat)
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private var tapBufferCount = 0
    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let backup = backupFile
        let builder = inputBuilder
        stateLock.unlock()

        try? backup?.write(from: buffer)

        // Waveform level, throttled to ~50 Hz.
        let level = Self.level(from: buffer)
        if level > sessionPeakLevel { sessionPeakLevel = level }
        tapBufferCount += 1
        if tapBufferCount <= 3 || tapBufferCount % 500 == 0 {
            SpeechService.diag("longform tap #\(tapBufferCount) level=\(level) frames=\(buffer.frameLength)")
        }
        let now = Date()
        if now.timeIntervalSince(lastLevelDispatchAt) >= 0.02 {
            lastLevelDispatchAt = now
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }

        guard let builder else { return }
        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: converted, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if convError == nil, converted.frameLength > 0 {
                builder.yield(AnalyzerInput(buffer: converted))
            }
        } else {
            builder.yield(AnalyzerInput(buffer: buffer))
        }
    }

    private func stopEngine() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            engine.reset()
        }
        audioEngine = nil
        stateLock.lock()
        backupFile = nil // closes the file
        stateLock.unlock()
    }

    private func deliverFinish(gen myGen: Int) {
        stateLock.lock()
        let alreadyDone = didFinish || myGen != gen
        if !alreadyDone { didFinish = true }
        stateLock.unlock()
        guard !alreadyDone else { return }
        isRunning = false
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        let transcript = combinedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        SpeechService.diag("longform end chars=\(transcript.count) peak=\(sessionPeakLevel)")
        DispatchQueue.main.async { [weak self] in self?.onFinished?(transcript) }
    }

    private static func level(from buffer: AVAudioPCMBuffer) -> Float {
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
        return min(1.0, max(0.0, rms * 12.0))
    }
}
