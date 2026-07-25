import Foundation
import CryptoKit

enum MediaImportError: LocalizedError {
    case ffmpegNotFound
    case extractionFailed(exitCode: Int32, log: String)
    case noAudioTrack
    case cancelled

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "Generating subtitles for this container needs its audio extracted first, which requires ffmpeg. Install it with `brew install ffmpeg`, then try again."
        case .extractionFailed(let code, let log):
            let tail = log.split(separator: "\n").suffix(2).joined(separator: " ")
            return "Audio extraction failed (ffmpeg exited \(code)). \(tail)"
        case .noAudioTrack:
            return "This video has no audio track, so there's nothing to transcribe into subtitles."
        case .cancelled:
            return "Audio extraction was cancelled."
        }
    }
}

/// Extracts the audio track of containers the Speech framework can't read.
///
/// Playback is handled natively by libmpv (`MPVPlayer`) — *no video
/// conversion happens anywhere*. This class exists only because the AI
/// Subtitle Generator uses Apple's Speech framework, which reads files
/// through AVFoundation and therefore can't open MKV/WebM/etc. Pulling just
/// the audio track into a small temporary .m4a (stream-copy when it's
/// already AAC/ALAC, transcode otherwise) is fast and leaves the video
/// untouched. Results are cached keyed on the source's path/size/mtime.
///
/// `@unchecked Sendable`: all mutable state (`runningProcess`) is guarded by
/// `processLock`, and work is dispatched onto a serial queue — the safety
/// the compiler can't verify is enforced manually here.
final class MediaImporter: @unchecked Sendable {

    /// Pure audio files that `AVAudioFile` (used by both speech engines) can
    /// open directly. Everything else — including video containers like
    /// .mp4/.mov that AVAudioFile CANNOT demux — needs its audio extracted
    /// first for transcription.
    static func isPureAudioFile(_ url: URL) -> Bool {
        ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif", "aifc", "flac", "au", "m4b"]
            .contains(url.pathExtension.lowercased())
    }

    /// Whether the video exporter's AVAssetReader needs this repackaged
    /// first. Decided by sniffing the actual file content, not the
    /// extension — files are often mislabeled (e.g. an .mkv renamed to .mp4
    /// plays fine in mpv but is still Matroska inside). AVAssetReader reads
    /// mp4/mov natively, so those return false here (unlike the audio path).
    static func needsAudioExtraction(_ url: URL) -> Bool {
        if let handle = try? FileHandle(forReadingFrom: url),
           let header = try? handle.read(upToCount: 12) {
            try? handle.close()
            // Matroska/WebM: EBML magic 1A 45 DF A3 at offset 0.
            if header.count >= 4, header.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) {
                return true
            }
            // ISO base media (MP4/MOV/M4A/...): "ftyp" at offset 4.
            if header.count >= 8, header.subdata(in: 4..<8) == Data("ftyp".utf8) {
                return false
            }
        }
        // Unrecognized header — fall back to an extension-based guess.
        return !["mp4", "m4v", "mov", "qt", "m4a", "mp3", "wav", "aac", "caf", "aiff"]
            .contains(url.pathExtension.lowercased())
    }

    static var isFFmpegAvailable: Bool { findExecutable("ffmpeg") != nil }

    // MARK: State

    private let workQueue = DispatchQueue(label: "SuperResVideoPlayer.MediaImporter", qos: .userInitiated)
    private let processLock = NSLock()
    private var runningProcess: Process?

    /// Terminates any in-flight ffmpeg process. The awaiting `extractAudio`
    /// call then throws `MediaImportError.cancelled`.
    func cancel() {
        processLock.lock()
        let process = runningProcess
        processLock.unlock()
        process?.terminate()
    }

    /// Extracts one of `url`'s audio tracks to a temporary WAV, reporting
    /// rough progress (0...1) on the main queue. `audioStreamIndex` is the
    /// zero-based position among the file's audio streams (container order —
    /// matches the order mpv lists them in the app's Audio picker). Returns
    /// the cached output immediately if this exact file+track was extracted
    /// before.
    func extractAudio(from url: URL, audioStreamIndex: Int = 0,
                      onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do {
                    continuation.resume(returning: try self.extractAudioSync(
                        url: url, audioStreamIndex: audioStreamIndex, onProgress: onProgress))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Transcodes to a baseline H.264 8-bit 4:2:0 .mp4 that AVAssetReader
    /// can always decode. Used as an export fallback when the reader can't
    /// handle the source directly (e.g. 10-bit HEVC). The player's Metal
    /// pipeline is 8-bit anyway, so no additional precision is lost.
    func transcodeForExport(from url: URL, audioStreamIndex: Int = 0,
                            onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do {
                    continuation.resume(returning: try self.transcodeForExportSync(
                        url: url, audioStreamIndex: audioStreamIndex, onProgress: onProgress))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func transcodeForExportSync(url: URL, audioStreamIndex: Int,
                                        onProgress: @escaping (Double) -> Void) throws -> URL {
        guard let ffmpeg = Self.findExecutable("ffmpeg") else {
            throw MediaImportError.ffmpegNotFound
        }
        let kind = audioStreamIndex == 0 ? "compat" : "compat-a\(audioStreamIndex)"
        let outputURL = try cachedOutputURL(for: url, kind: kind, ext: "mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }
        let info = probe(url: url)
        let partialURL = outputURL.deletingPathExtension().appendingPathExtension("part.mp4")
        try? FileManager.default.removeItem(at: partialURL)

        let args = [
            "-y", "-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1",
            "-i", url.path,
            "-map", "0:v:0", "-map", "0:a:\(audioStreamIndex)?", "-sn",
            "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p", "-b:v", "20M",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", partialURL.path
        ]
        do {
            try runFFmpeg(arguments: args, ffmpegPath: ffmpeg,
                          durationSeconds: info.duration, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
        try FileManager.default.moveItem(at: partialURL, to: outputURL)
        return outputURL
    }

    /// Repackages an AVFoundation-unreadable container (MKV, WebM, ...)
    /// into an .mp4 that AVAssetReader can decode, for the video exporter.
    /// Stream-copies H.264/HEVC video (lossless, fast); transcodes other
    /// codecs via the VideoToolbox hardware encoder. Audio goes to AAC
    /// unless already MP4-compatible.
    func remuxVideoToMP4(from url: URL, audioStreamIndex: Int = 0,
                         onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                do {
                    continuation.resume(returning: try self.remuxVideoSync(
                        url: url, audioStreamIndex: audioStreamIndex, onProgress: onProgress))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func remuxVideoSync(url: URL, audioStreamIndex: Int,
                                onProgress: @escaping (Double) -> Void) throws -> URL {
        guard let ffmpeg = Self.findExecutable("ffmpeg") else {
            throw MediaImportError.ffmpegNotFound
        }

        // Keyed per audio track — see extractAudioSync.
        let kind = audioStreamIndex == 0 ? "video" : "video-a\(audioStreamIndex)"
        let outputURL = try cachedOutputURL(for: url, kind: kind, ext: "mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let info = probe(url: url)
        let copyableVideo: Set<String> = ["h264", "hevc"]
        let copyableAudio: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]
        let videoCopy = info.videoCodec.map { copyableVideo.contains($0) } ?? false
        // The probe reports the codec of the *first* audio stream only; for
        // any other selected track just re-encode to AAC rather than trust a
        // codec we didn't probe.
        let audioCopy = audioStreamIndex == 0
            && (info.audioCodec.map { copyableAudio.contains($0) } ?? false)

        let partialURL = outputURL.deletingPathExtension().appendingPathExtension("part.mp4")
        try? FileManager.default.removeItem(at: partialURL)

        func arguments(videoCopy: Bool, audioCopy: Bool) -> [String] {
            var args = [
                "-y", "-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1",
                "-i", url.path,
                "-map", "0:v:0", "-map", "0:a:\(audioStreamIndex)?", "-sn"
            ]
            if videoCopy {
                args += ["-c:v", "copy"]
                if info.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
            } else {
                args += ["-c:v", "hevc_videotoolbox", "-b:v", "12M", "-tag:v", "hvc1"]
            }
            args += audioCopy ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
            args += ["-movflags", "+faststart", partialURL.path]
            return args
        }

        do {
            try runFFmpeg(arguments: arguments(videoCopy: videoCopy, audioCopy: audioCopy),
                          ffmpegPath: ffmpeg, durationSeconds: info.duration, onProgress: onProgress)
        } catch let error as MediaImportError {
            if case .cancelled = error {
                try? FileManager.default.removeItem(at: partialURL)
                throw error
            }
            guard videoCopy || audioCopy else {
                try? FileManager.default.removeItem(at: partialURL)
                throw error
            }
            // Stream copy can fail on quirky packets — retry with a full
            // transcode before giving up.
            try? FileManager.default.removeItem(at: partialURL)
            try runFFmpeg(arguments: arguments(videoCopy: false, audioCopy: false),
                          ffmpegPath: ffmpeg, durationSeconds: info.duration, onProgress: onProgress)
        }

        try FileManager.default.moveItem(at: partialURL, to: outputURL)
        return outputURL
    }

    private func extractAudioSync(url: URL, audioStreamIndex: Int,
                                  onProgress: @escaping (Double) -> Void) throws -> URL {
        guard let ffmpeg = Self.findExecutable("ffmpeg") else {
            throw MediaImportError.ffmpegNotFound
        }

        // The cache must be keyed per track, or switching the Audio picker
        // and regenerating subtitles would silently reuse the previous
        // track's extraction. ("audio" for track 0 keeps old caches valid.)
        let kind = audioStreamIndex == 0 ? "audio" : "audio-a\(audioStreamIndex)"
        let outputURL = try cachedOutputURL(for: url, kind: kind, ext: "wav")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        let info = probe(url: url)

        // Probe found video but no audio (both nil only when ffprobe itself
        // is unavailable, in which case we let ffmpeg try and report). A
        // video-only file has nothing to transcribe.
        if info.videoCodec != nil, info.audioCodec == nil {
            throw MediaImportError.noAudioTrack
        }

        // Write to a partial file and rename on success, so a cancelled or
        // failed extraction never leaves a truncated file in the cache.
        let partialURL = outputURL.deletingPathExtension().appendingPathExtension("part.wav")
        try? FileManager.default.removeItem(at: partialURL)

        // Extract to 16 kHz mono 16-bit PCM WAV — the canonical input for
        // Apple's speech engines, read natively by AVAudioFile, and free of
        // any container/movflags quirks (an m4a + `-movflags +faststart`
        // output was rejected by some ffmpeg builds with EINVAL).
        let args = [
            "-y", "-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1",
            "-i", url.path,
            "-vn", "-sn", "-map", "0:a:\(audioStreamIndex)",
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
            partialURL.path
        ]

        do {
            try runFFmpeg(arguments: args, ffmpegPath: ffmpeg,
                          durationSeconds: info.duration, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            // When ffprobe wasn't available to pre-detect it, a video-only
            // file surfaces here as ffmpeg's "matches no streams" — map it
            // to the clear no-audio message.
            if case let MediaImportError.extractionFailed(_, log) = error,
               log.localizedCaseInsensitiveContains("matches no streams")
                || log.localizedCaseInsensitiveContains("does not contain any stream") {
                throw MediaImportError.noAudioTrack
            }
            throw error
        }

        try FileManager.default.moveItem(at: partialURL, to: outputURL)
        return outputURL
    }

    private func runFFmpeg(
        arguments: [String],
        ffmpegPath: String,
        durationSeconds: Double,
        onProgress: @escaping (Double) -> Void
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let logLock = NSLock()
        var errorLog = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logLock.lock()
            errorLog.append(data)
            logLock.unlock()
        }

        // `-progress pipe:1` emits key=value lines; out_time_us is the
        // current output timestamp in microseconds.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            guard durationSeconds > 0,
                  let text = String(data: handle.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)) {
                    let progress = min(1.0, max(0.0, (us / 1_000_000) / durationSeconds))
                    DispatchQueue.main.async { onProgress(progress) }
                }
            }
        }

        processLock.lock()
        runningProcess = process
        processLock.unlock()

        defer {
            processLock.lock()
            runningProcess = nil
            processLock.unlock()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            throw MediaImportError.cancelled
        }
        guard process.terminationStatus == 0 else {
            logLock.lock()
            let log = String(data: errorLog, encoding: .utf8) ?? ""
            logLock.unlock()
            throw MediaImportError.extractionFailed(exitCode: process.terminationStatus, log: log)
        }
    }

    // MARK: Probing

    private struct ProbeInfo {
        var videoCodec: String?
        var audioCodec: String?
        var duration: Double
    }

    /// Asks ffprobe what's inside the file. Failing softly just means the
    /// audio gets transcoded rather than stream-copied.
    private func probe(url: URL) -> ProbeInfo {
        let fallback = ProbeInfo(videoCodec: nil, audioCodec: nil, duration: 0)
        guard let ffprobe = Self.findExecutable("ffprobe") else { return fallback }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error", "-print_format", "json",
            "-show_streams", "-show_format", url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return fallback }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }

        var result = fallback
        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                let type = stream["codec_type"] as? String
                if type == "video", result.videoCodec == nil {
                    result.videoCodec = stream["codec_name"] as? String
                }
                if type == "audio", result.audioCodec == nil {
                    result.audioCodec = stream["codec_name"] as? String
                }
            }
        }
        if let format = json["format"] as? [String: Any],
           let durationString = format["duration"] as? String,
           let duration = Double(durationString) {
            result.duration = duration
        }
        return result
    }

    // MARK: Locating ffmpeg

    /// A GUI-launched process doesn't inherit the shell's PATH, so check
    /// the app bundle's own Helpers directory first (distribution builds
    /// ship ffmpeg/ffprobe there — see make-dist.sh), then the common
    /// install locations, then fall back to `which`.
    private static func findExecutable(_ name: String) -> String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            "/opt/homebrew/bin/\(name)",   // Homebrew on Apple Silicon
            "/usr/local/bin/\(name)",      // Homebrew on Intel / manual installs
            "/opt/local/bin/\(name)"       // MacPorts
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        guard (try? which.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        guard which.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    // MARK: Cache

    private func cachedOutputURL(for url: URL, kind: String, ext: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperResVideoPlayer-Media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Keep the cache from growing without bound (remuxed .mp4s can be
        // large). Evict oldest files first, before writing a new one.
        Self.pruneCache(directory: directory, maxTotalBytes: 3_000_000_000)

        // Key on path + size + mtime so an edited/replaced source file
        // doesn't serve a stale cached extraction.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(size)|\(mtime)|\(kind)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)

        return directory.appendingPathComponent("\(digest)-\(kind).\(ext)")
    }

    /// Evicts the oldest cache files (by modification date) until the total
    /// size is within `maxTotalBytes`. Skips in-progress `.part.*` files so
    /// an active extraction isn't deleted out from under itself.
    private static func pruneCache(directory: URL, maxTotalBytes: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: keys) else { return }

        var files = items.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard !url.lastPathComponent.contains(".part."),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true,
                  let size = v.fileSize, let date = v.contentModificationDate else { return nil }
            return (url, size, date)
        }

        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxTotalBytes else { return }

        files.sort { $0.date < $1.date }   // oldest first
        for file in files {
            if total <= maxTotalBytes { break }
            if (try? fm.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }
}
