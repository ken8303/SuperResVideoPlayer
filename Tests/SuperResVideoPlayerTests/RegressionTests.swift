import SuperResCore
import XCTest
import AVFoundation
import Metal
@testable import SuperResVideoPlayer

final class RegressionTests: XCTestCase {
    @MainActor
    func testMPVFrameClockAndTextSubtitlesWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["SRV_TEST_PLAYBACK_FILE"] else {
            throw XCTSkip("Opt-in generated playback fixture")
        }
        let player = MPVPlayer()
        defer { player.shutdown() }
        var sawText = false
        var sawTextTrack = false
        player.onTracksChanged = { tracks in
            sawTextTrack = sawTextTrack || tracks.contains { $0.isTextSubtitle }
        }
        player.onSubtitleTextChanged = { text in
            sawText = sawText || text.contains("Overlay test")
        }
        player.setInterpolationEnabled(true)
        player.load(url: URL(fileURLWithPath: path))
        var frames: [MPVPlayer.Frame] = []
        for _ in 0..<160 {
            try await Task.sleep(nanoseconds: 15_000_000)
            if let frame = player.latestFrame, frame.serial != frames.last?.serial { frames.append(frame) }
        }
        XCTAssertGreaterThan(frames.count, 10)
        XCTAssertTrue(sawTextTrack)
        XCTAssertTrue(sawText)
        for frame in frames {
            XCTAssertTrue(frame.timeSeconds.isFinite)
            XCTAssertLessThan(abs(frame.timeSeconds - frame.arrivalHostTime), 0.5)
        }
        player.setInterpolationEnabled(false)
        player.seek(to: 0)
        player.setPaused(true)
    }

    func testFFmpegProgressBuffersSplitLines() {
        var parser = FFmpegProgressParser(duration: 10)
        XCTAssertEqual(parser.append(Data("out_time_".utf8)), [])
        XCTAssertEqual(parser.append(Data("us=500".utf8)), [])
        XCTAssertEqual(parser.append(Data("0000\nout_time_us=10000000\n".utf8)), [0.5, 1])
    }

    func testFFmpegRetainsFinalErrorAfterLargeOutput() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("input.mkv")
        try Data("source".utf8).write(to: source)
        let ffmpeg = try executable(in: directory, name: "ffmpeg", body: """
        i=0
        while [ "$i" -lt 12000 ]; do
            echo progress=continue
            echo diagnostic >&2
            i=$((i + 1))
        done
        printf 'FINAL_ERROR_WITHOUT_NEWLINE' >&2
        exit 7
        """)
        let importer = MediaImporter(executableResolver: { $0 == "ffmpeg" ? ffmpeg : nil })
        do {
            _ = try await importer.extractAudio(from: source) { _ in }
            XCTFail("Expected conversion failure")
        } catch MediaImportError.extractionFailed(let code, let log) {
            XCTAssertEqual(code, 7)
            XCTAssertTrue(log.hasSuffix("FINAL_ERROR_WITHOUT_NEWLINE"))
            XCTAssertLessThanOrEqual(log.utf8.count, 65_536)
        }
    }

    func testAudioTrimsSamplesBeforeVideoOrigin() throws {
        var asbd = AudioStreamBasicDescription(mSampleRate: 1000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 200, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 200, flags: 0, blockBufferOut: &block), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1000),
            presentationTimeStamp: CMTime(value: 950, timescale: 1000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = 2
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 100, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample), noErr)
        let input = try XCTUnwrap(sample)
        let kept = try XCTUnwrap(VideoExporter.trimAudio(input, startingAt: CMTime(value: 1, timescale: 1)))
        XCTAssertEqual(CMSampleBufferGetNumSamples(kept), 50)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(kept).seconds, 1, accuracy: 0.00001)
        XCTAssertNil(try VideoExporter.trimAudio(input, startingAt: CMTime(value: 2, timescale: 1)))
        XCTAssertEqual(CMSampleBufferGetNumSamples(try XCTUnwrap(VideoExporter.trimAudio(input, startingAt: .zero))), 100)
    }

    func testConcurrentMPVCommandsAndShutdown() {
        let player = MPVPlayer()
        let group = DispatchGroup()
        for _ in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<100 { player.setVolume(50); player.setPaused(true) }
                group.leave()
            }
        }
        player.shutdown()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        player.shutdown()
    }

    func testTranslationRejectsLanguageDriftAndBilingualOutput() {
        XCTAssertFalse(TranslationLanguageValidator.accepts("The Sect Master, the Wandering Mountain Immortal Crane.", target: "ja"))
        XCTAssertFalse(TranslationLanguageValidator.accepts("Hurry up.", target: "ja"))
        XCTAssertFalse(TranslationLanguageValidator.accepts("追赶这个男人叫小光|追いかけている男は小光です。", target: "ja"))
        XCTAssertTrue(TranslationLanguageValidator.accepts("宗主、山を渡る仙鶴です。", target: "ja"))
        XCTAssertTrue(TranslationLanguageValidator.accepts("急いで。", target: "ja"))
        XCTAssertFalse(TranslationLanguageValidator.accepts("急いでください。」}```json```{", target: "ja"))
        XCTAssertFalse(TranslationLanguageValidator.accepts("宗主、さまよう山霊の鶴。}, {", target: "ja"))
        XCTAssertTrue(TranslationLanguageValidator.accepts("宗主", target: "ja"))
        XCTAssertTrue(TranslationLanguageValidator.accepts("AI", target: "ja"))
        XCTAssertTrue(TranslationLanguageValidator.accepts("123…", target: "ja"))
        XCTAssertFalse(TranslationLanguageValidator.accepts("急いでください。", target: "en"))
        XCTAssertTrue(TranslationLanguageValidator.accepts("The Sect Master has arrived.", target: "en"))
        XCTAssertTrue(TranslationLanguageValidator.accepts("宗主已經到了，請大家安靜。", target: "zh-Hant"))
        XCTAssertTrue(TranslationLanguageValidator.accepts("빨리 돌아가야 합니다.", target: "ko"))
    }

    func testLiveJapaneseTranslationWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["SRV_TEST_LIVE_TRANSLATION"] == "1" else {
            throw XCTSkip("Opt-in on-device model smoke test")
        }
        let cues = [
            SubtitleCue(startTime: 1129.5, endTime: 1133.37, text: "The Sect Master, the Wandering Mountain Immortal Crane."),
            SubtitleCue(startTime: 1133.94, endTime: 1139.19, text: "Hurry up.")
        ]
        let skipped = try await SubtitleTranslator.translate(cues: cues, sourceLocale: Locale(identifier: "en"), targetIdentifier: "ja") { updates, completed in
            XCTAssertEqual(completed, 2)
            XCTAssertEqual(updates.count, 2)
            for text in updates.values {
                XCTAssertTrue(TranslationLanguageValidator.accepts(text, target: "ja"))
                print("Japanese translation smoke test: \(text)")
            }
        }
        XCTAssertEqual(skipped, 0)
    }

    private enum ExpectedFailure: Error { case failed }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFailedExportPreservesExistingDestination() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("saved.mp4")
        try Data("original".utf8).write(to: destination)
        XCTAssertThrowsError(try ExportDestination.write(to: destination) { staging in
            try Data("incomplete".utf8).write(to: staging)
            throw ExpectedFailure.failed
        })
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["saved.mp4"])
    }

    func testSuccessfulExportReplacesDestinationAndCleansStaging() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("saved.mp4")
        try Data("original".utf8).write(to: destination)
        try ExportDestination.write(to: destination) { staging in
            try Data("complete".utf8).write(to: staging)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("complete".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["saved.mp4"])
    }

    func testFailedExportDoesNotCreateDestination() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("new.mp4")
        XCTAssertThrowsError(try ExportDestination.write(to: destination) { staging in
            try Data("incomplete".utf8).write(to: staging)
            throw ExpectedFailure.failed
        })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSuccessfulExportCreatesNewDestination() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("new.mp4")
        try ExportDestination.write(to: destination) { staging in
            try Data("complete".utf8).write(to: staging)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("complete".utf8))
    }

    func testContainerSniffingOverridesExtension() throws {
        let directory = try temporaryDirectory()
        let mislabeled = directory.appendingPathComponent("movie.mp4")
        try Data([0x1A, 0x45, 0xDF, 0xA3]).write(to: mislabeled)
        XCTAssertTrue(MediaImporter.needsAudioExtraction(mislabeled))
        let mp4 = directory.appendingPathComponent("movie.mkv")
        try Data([0, 0, 0, 24] + Array("ftypisom".utf8)).write(to: mp4)
        XCTAssertFalse(MediaImporter.needsAudioExtraction(mp4))
    }

    private func executable(in directory: URL, name: String, body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testUnknownDurationStillDrainsFFmpegProgressPipe() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("input.mkv")
        try Data("source".utf8).write(to: source)
        // More output than a pipe can buffer: the old duration guard never
        // read these bytes, leaving FFmpeg permanently blocked in write().
        let ffmpeg = try executable(in: directory, name: "ffmpeg", body: """
        i=0
        while [ "$i" -lt 20000 ]; do
          echo out_time_us=1000000
          i=$((i + 1))
        done
        for destination do :; done
        printf media > "$destination"
        """)
        let importer = MediaImporter(executableResolver: { $0 == "ffmpeg" ? ffmpeg : nil })
        let watchdog = DispatchWorkItem { importer.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        let output = try await importer.extractAudio(from: source) { _ in
            XCTFail("Unknown duration must not report fractional progress")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(try Data(contentsOf: output), Data("media".utf8))
    }

    func testCancellationDuringProbePreventsFFmpegLaunch() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("input.mkv")
        let marker = directory.appendingPathComponent("probe-started")
        let launched = directory.appendingPathComponent("ffmpeg-started")
        try Data("source".utf8).write(to: source)
        let probe = try executable(in: directory, name: "ffprobe", body: """
        touch '\(marker.path)'
        exec /bin/sleep 20
        """)
        let ffmpeg = try executable(in: directory, name: "ffmpeg", body: "touch '\(launched.path)'\n")
        let importer = MediaImporter(executableResolver: { $0 == "ffprobe" ? probe : ffmpeg })
        let task = Task { try await importer.extractAudio(from: source) { _ in } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        importer.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled extraction must throw")
        } catch MediaImportError.cancelled {
            // Expected, including when ffprobe has not produced any output.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launched.path))
    }

    private var exportConfiguration: VideoExporter.Configuration {
        .init(superResolutionEnabled: false, upscaleFactor: 1,
              frameInterpolationMultiplier: 1, imageEnhancementEnabled: false,
              enhancementEngine: .classic, enhancementStrength: 0,
              durationLimitSeconds: nil)
    }

    func testCancelledExportPreservesExistingFile() async throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("existing.mp4")
        try Data("original".utf8).write(to: destination)
        let exporter = VideoExporter()
        exporter.cancel()
        do {
            try await exporter.export(source: directory.appendingPathComponent("missing.mp4"),
                                      to: destination, configuration: exportConfiguration) { _ in }
            XCTFail("Cancelled export must fail")
        } catch VideoExportError.cancelled { }
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    }

    func testExportRejectsSourceAsDestination() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.mp4")
        try Data("original".utf8).write(to: source)
        do {
            try await VideoExporter().export(source: source, to: source,
                                             configuration: exportConfiguration) { _ in }
            XCTFail("Must reject replacing the source")
        } catch VideoExportError.writerSetupFailed { }
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    func testGPUExportPreservesFrameCountAndRotation() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.mp4")
        let destination = directory.appendingPathComponent("export.mp4")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 32,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoPixelAspectRatioKey: [AVVideoPixelAspectRatioHorizontalSpacingKey: 4,
                                        AVVideoPixelAspectRatioVerticalSpacingKey: 3]
        ])
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        input.transform = rotation
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<4 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let frame = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(frame, [])
            memset(CVPixelBufferGetBaseAddress(frame), Int32(50 + index * 30),
                   CVPixelBufferGetBytesPerRow(frame) * 32)
            CVPixelBufferUnlockBaseAddress(frame, [])
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed)
        let exporter = VideoExporter()
        let watchdog = DispatchWorkItem { exporter.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        try await exporter.export(source: source, to: destination, configuration: exportConfiguration) { _ in }
        let result = AVURLAsset(url: destination)
        let track = try XCTUnwrap(result.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.preferredTransform, rotation)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let extensions = try XCTUnwrap(CMFormatDescriptionGetExtensions(format)) as NSDictionary
        XCTAssertEqual(extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String, AVVideoColorPrimaries_ITU_R_709_2)
        let aspect = try XCTUnwrap(extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary)
        XCTAssertEqual((aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber)?.intValue, 3)
        let reader = try AVAssetReader(asset: result)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        XCTAssertEqual(frames, 4)
        XCTAssertEqual(reader.status, .completed)
    }
    func testCancelledSubtitleRunDoesNotStartRecognition() async throws {
        let generator = SubtitleGenerator()
        generator.cancel()
        do {
            _ = try await generator.generate(for: URL(fileURLWithPath: "/missing-audio.m4a"),
                                             locale: Locale(identifier: "en-US"), totalDuration: 1) { _ in }
            XCTFail("A cancelled run must not restart recognition")
        } catch is CancellationError { }
    }

    func testEnhancementStrengthBlendsPixelsOnGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let library = Renderer.loadShaderLibrary(device: device)
        let enhancer = try XCTUnwrap(EnhancementProcessor(device: device, library: library))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                 width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let original = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let enhanced = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let result = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let dark = [UInt8](repeating: 0, count: 16)
        let bright = [UInt8](repeating: 200, count: 16)
        dark.withUnsafeBytes { original.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                                                withBytes: $0.baseAddress!, bytesPerRow: 8) }
        bright.withUnsafeBytes { enhanced.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                                                  withBytes: $0.baseAddress!, bytesPerRow: 8) }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let mixed = try XCTUnwrap(enhancer.blend(original: original, enhanced: enhanced,
                                               strength: 0.25, commandBuffer: commands))
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: mixed, to: result)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes.withUnsafeMutableBytes {
            result.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        }
        for offset in stride(from: 0, to: 16, by: 4) {
            XCTAssertEqual(Double(bytes[offset]), 50, accuracy: 1)
            XCTAssertEqual(Double(bytes[offset + 1]), 50, accuracy: 1)
            XCTAssertEqual(Double(bytes[offset + 2]), 50, accuracy: 1)
            XCTAssertEqual(bytes[offset + 3], 255)
        }
    }

    func testSubtitleLookupHandlesBoundariesGapsAndSeeking() {
        let timeline = SubtitleTimeline(cues: [
            SubtitleCue(startTime: 1, endTime: 2, text: "first"),
            SubtitleCue(startTime: 4, endTime: 5, text: "second")
        ])
        XCTAssertNil(timeline.text(at: 0))
        XCTAssertEqual(timeline.text(at: 1), "first")
        XCTAssertEqual(timeline.text(at: 2), "first")
        XCTAssertNil(timeline.text(at: 3))
        XCTAssertEqual(timeline.text(at: 4.5), "second")
        XCTAssertEqual(timeline.text(at: 1.5), "first")
        XCTAssertNil(timeline.text(at: 6))
        XCTAssertNil(timeline.text(at: .nan))
    }

    func testSubtitleLookupPreservesFirstActiveOverlappingCue() {
        let cues = [
            SubtitleCue(startTime: 0, endTime: 10, text: "long"),
            SubtitleCue(startTime: 2, endTime: 3, text: "short"),
            SubtitleCue(startTime: 9, endTime: 12, text: "last")
        ]
        let timeline = SubtitleTimeline(cues: cues)
        for step in 0...130 {
            let time = Double(step) / 10
            XCTAssertEqual(timeline.text(at: time),
                           cues.first { time >= $0.startTime && time <= $0.endTime }?.text)
        }
        XCTAssertNil(SubtitleTimeline(cues: []).text(at: 1))
    }

    func testAudioExtractionKeepsSelectedTrackAndWAVFormat() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("input.mkv")
        let arguments = directory.appendingPathComponent("arguments.txt")
        try Data("source".utf8).write(to: source)
        let ffmpeg = try executable(in: directory, name: "ffmpeg", body: """
        printf '%s\\n' "$@" > '\(arguments.path)'
        for destination do :; done
        printf media > "$destination"
        """)
        let importer = MediaImporter(executableResolver: { $0 == "ffmpeg" ? ffmpeg : nil })
        let output = try await importer.extractAudio(from: source, audioStreamIndex: 2) { _ in }
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(output.pathExtension, "wav")
        let invocation = try String(contentsOf: arguments, encoding: .utf8)
        XCTAssertTrue(invocation.contains("0:a:2"))
        XCTAssertTrue(invocation.contains("pcm_s16le"))
        XCTAssertEqual(try Data(contentsOf: output), Data("media".utf8))
    }
}
