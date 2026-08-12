// Speech's Objective-C request types have not adopted Sendable annotations,
// although their asynchronous request API is designed to be fed from a
// worker queue. Import with pre-concurrency semantics until Apple annotates
// the framework.
@preconcurrency import Speech
import AVFoundation
import Foundation
import SuperResCore

enum SubtitleGenerationError: LocalizedError {
    case authorizationDenied
    case recognizerUnavailable
    case recognitionFailed(Error)
    case legacyDurationLimit

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech recognition permission was denied. Enable it in System Settings > Privacy & Security > Speech Recognition, then try again."
        case .recognizerUnavailable:
            return "Speech recognition isn't available for the selected language on this Mac."
        case .recognitionFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        case .legacyDurationLimit:
            return "This language uses the older speech engine on this Mac, which can only transcribe clips under a minute. Pick a language supported by the on-device model, or use a shorter clip."
        }
    }
}

/// Generates subtitle cues by transcribing audio.
///
/// Two engines, tried in order:
///  1. **SpeechAnalyzer/SpeechTranscriber (macOS 26+)** — Apple's modern
///     long-form transcription API. Fully on-device, handles arbitrarily
///     long audio, and attributes every word with its audio time range.
///     This is the primary path.
///  2. **SFSpeechRecognizer (legacy)** — fallback for locales the modern
///     API doesn't support. NOTE: for long audio the legacy API segments
///     input into "utterances" and its final result frequently covers only
///     the last utterance (the classic "my subtitles are one line" bug),
///     so it's only used when there's no alternative.
final class SubtitleGenerator {

    /// Narrow bridge from the GCD audio-feeder closure back to the generator.
    /// Swift weak references are thread-safe; the generator's continuation is
    /// itself protected by `continuationLock`.
    private final class LegacyReadFailureHandler: @unchecked Sendable {
        weak var generator: SubtitleGenerator?

        init(generator: SubtitleGenerator) {
            self.generator = generator
        }

        func report(_ error: Error) {
            generator?.resumePending(
                throwing: SubtitleGenerationError.recognitionFailed(error))
        }
    }

    /// Requests Speech Recognition authorization if not already granted
    /// (only the legacy engine needs this; SpeechAnalyzer transcribes
    /// app-provided files on-device without TCC authorization).
    static func requestAuthorizationIfNeeded() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// All locales this Mac's Speech framework can recognize, sorted by
    /// localized display name, for populating a language picker.
    static var supportedLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted {
            ($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) <
            ($1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
    }

    // MARK: Cancellation plumbing

    private var task: SFSpeechRecognitionTask?

    /// Strong reference held for the lifetime of the legacy recognition
    /// task — `SFSpeechRecognitionTask` is not documented to retain its
    /// recognizer, and letting it deallocate mid-task kills recognition
    /// silently. Guarded by `continuationLock`.
    private var activeRecognizer: SFSpeechRecognizer?

    /// Guards `pendingContinuation`, `activeRecognizer`, and
    /// `cancelModernAnalysis` against concurrent access from the caller,
    /// the recognition result-handler thread, and `cancel()`.
    private let continuationLock = NSLock()
    private var pendingContinuation: CheckedContinuation<[SubtitleCue], Error>?

    /// Cancellation hook for an in-flight SpeechAnalyzer session.
    private var cancelModernAnalysis: (() -> Void)?

    /// Synchronous helper so async contexts never touch NSLock directly
    /// (unavailable-from-async in Swift 6 mode).
    private func setCancelModernAnalysis(_ handler: (() -> Void)?) {
        continuationLock.lock()
        cancelModernAnalysis = handler
        continuationLock.unlock()
    }

    /// Optional UI hook: called (on the main queue) with human-readable
    /// descriptions of long-running internal phases.
    var onStatus: ((String) -> Void)?

    private func reportStatus(_ status: String) {
        Task { @MainActor in self.onStatus?(status) }
    }

    /// Cancels any in-flight transcription (either engine).
    func cancel() {
        task?.cancel()
        task = nil

        continuationLock.lock()
        let cancelModern = cancelModernAnalysis
        cancelModernAnalysis = nil
        continuationLock.unlock()
        cancelModern?()

        resumePending(throwing: CancellationError())
    }

    // MARK: Entry point

    /// Transcribes `url`'s audio and returns subtitle cues built from
    /// word-level timings. `onProgress` receives a rough 0...1 estimate.
    func generate(
        for url: URL,
        locale: Locale,
        totalDuration: TimeInterval,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [SubtitleCue] {
        print("SuperResVideoPlayer: transcribing \(url.path) [\(locale.identifier)]")

        let modernLocales = await SpeechTranscriber.supportedLocales
        let modernSupported = modernLocales
            .contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        print("SuperResVideoPlayer: SpeechTranscriber locales: \(modernLocales.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", "))")
        print("SuperResVideoPlayer: modern engine supported for \(locale.identifier(.bcp47)): \(modernSupported)")

        // AVAudioFile can open audio files and most audio-in-video
        // containers; when it can't, the legacy path (which reads via
        // AVFoundation's movie stack) gets a chance instead.
        if modernSupported {
            do {
                let audioFile = try AVAudioFile(forReading: url)
                print("SuperResVideoPlayer: using SpeechAnalyzer (modern engine)")
                return try await generateModern(
                    audioFile: audioFile,
                    locale: locale,
                    totalDuration: totalDuration,
                    onProgress: onProgress
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let nsError = error as NSError
                print("SuperResVideoPlayer: modern engine failed [\(nsError.domain) \(nsError.code)] \(nsError) — falling back to SFSpeechRecognizer.")
            }
        }

        print("SuperResVideoPlayer: using SFSpeechRecognizer (legacy engine)")
        return try await generateLegacy(
            for: url,
            locale: locale,
            totalDuration: totalDuration,
            onProgress: onProgress
        )
    }

    // MARK: Modern engine (SpeechAnalyzer, macOS 26+)

    private func generateModern(
        audioFile: AVAudioFile,
        locale: Locale,
        totalDuration: TimeInterval,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [SubtitleCue] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],                 // final results only
            attributeOptions: [.audioTimeRange]   // per-word timestamps
        )

        // Download the on-device language model for this locale if it
        // isn't installed yet (one-time, may take a moment on first use).
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("SuperResVideoPlayer: downloading speech model for \(locale.identifier)…")
            reportStatus("Downloading speech model for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)… (one-time)")
            try await installation.downloadAndInstall()
            print("SuperResVideoPlayer: speech model installed.")
            reportStatus("Transcribing audio…")
        } else {
            print("SuperResVideoPlayer: speech model already installed.")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Feed the file through the analyzer concurrently with consuming
        // the results stream below.
        let analysisTask = Task {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }

        setCancelModernAnalysis {
            analysisTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        defer { setCancelModernAnalysis(nil) }

        var words: [WordTiming] = []
        for try await result in transcriber.results where result.isFinal {
            for run in result.text.runs {
                guard let timeRange = run.audioTimeRange else { continue }
                let text = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                words.append(WordTiming(
                    text: text,
                    start: timeRange.start.seconds,
                    end: timeRange.end.seconds
                ))
                if totalDuration > 0 {
                    let progress = min(1.0, max(0.0, timeRange.end.seconds / totalDuration))
                    Task { @MainActor in onProgress(progress) }
                }
            }
        }
        try await analysisTask.value

        return SubtitleGrouping.buildCues(
            from: words,
            joiningWith: SubtitleGrouping.wordSeparator(forLanguageCode: locale.identifier))
    }

    // MARK: Legacy engine (SFSpeechRecognizer)

    private func generateLegacy(
        for url: URL,
        locale: Locale,
        totalDuration: TimeInterval,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [SubtitleCue] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SubtitleGenerationError.recognizerUnavailable
        }

        // SFSpeechRecognizer caps on-device recognition at ~1 minute of
        // audio; beyond that it silently truncates. Fail clearly instead of
        // returning subtitles that only cover the first minute. (60s minus a
        // safety margin; totalDuration == 0 means unknown, so allow it.)
        if totalDuration > 58 {
            throw SubtitleGenerationError.legacyDurationLimit
        }

        guard await Self.requestAuthorizationIfNeeded() else {
            throw SubtitleGenerationError.authorizationDenied
        }

        // Read the audio ourselves and stream PCM buffers into Speech via
        // SFSpeechAudioBufferRecognitionRequest, instead of the file-based
        // SFSpeechURLRecognitionRequest. The URL request builds an internal
        // AVAssetReaderAudioMixOutput that throws an *uncatchable* ObjC
        // exception on macOS 27 beta for some inputs (crashing the app). The
        // buffer request never touches that code path.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw SubtitleGenerationError.recognitionFailed(error)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let separator = SubtitleGrouping.wordSeparator(forLanguageCode: locale.identifier)

        return try await withCheckedThrowingContinuation { continuation in
            continuationLock.lock()
            // If a previous generate() is somehow still pending, resume it
            // rather than leaking its suspended task.
            let stale = pendingContinuation
            pendingContinuation = continuation
            activeRecognizer = recognizer
            continuationLock.unlock()
            stale?.resume(throwing: CancellationError())

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }

                if let error {
                    let nsError = error as NSError
                    print("SuperResVideoPlayer: legacy engine failed [\(nsError.domain) \(nsError.code)] \(nsError)")
                    self.resumePending(throwing: SubtitleGenerationError.recognitionFailed(error))
                    return
                }
                guard let result else { return }

                if let lastSegment = result.bestTranscription.segments.last, totalDuration > 0 {
                    let elapsed = lastSegment.timestamp + lastSegment.duration
                    let progress = min(1.0, max(0.0, elapsed / totalDuration))
                    Task { @MainActor in onProgress(progress) }
                }

                if result.isFinal {
                    let words = result.bestTranscription.segments.map {
                        WordTiming(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    self.resumePending(returning: SubtitleGrouping.buildCues(from: words, joiningWith: separator))
                }
            }

            // Stream the whole file into the recognizer in PCM chunks.
            let readFailureHandler = LegacyReadFailureHandler(generator: self)
            DispatchQueue.global(qos: .userInitiated).async {
                let format = audioFile.processingFormat
                let chunkFrames: AVAudioFrameCount = 16384
                do {
                    while true {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
                        try audioFile.read(into: buffer)
                        if buffer.frameLength == 0 { break }  // EOF
                        request.append(buffer)
                    }
                } catch {
                    print("SuperResVideoPlayer: legacy audio read failed: \(error)")
                    request.endAudio()
                    readFailureHandler.report(error)
                    return
                }
                request.endAudio()
            }
        }
    }

    private func resumePending(returning cues: [SubtitleCue]) {
        continuationLock.lock()
        let continuation = pendingContinuation
        pendingContinuation = nil
        activeRecognizer = nil
        continuationLock.unlock()
        continuation?.resume(returning: cues)
    }

    private func resumePending(throwing error: Error) {
        continuationLock.lock()
        let continuation = pendingContinuation
        pendingContinuation = nil
        activeRecognizer = nil
        continuationLock.unlock()
        continuation?.resume(throwing: error)
    }

}
