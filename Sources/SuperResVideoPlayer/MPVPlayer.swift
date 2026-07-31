import Foundation
import CoreVideo
import Metal          // MTLPixelFormat, for the renderer's format handshake
import Cmpv
import SuperResCore

/// Playback engine backed by libmpv — the same engine IINA embeds — so the
/// app plays every container/codec mpv's bundled ffmpeg supports (MKV, WebM,
/// AVI, FLAC audio, ...) natively, with no conversion step.
///
/// Division of labor:
///  - libmpv: demuxing, decoding (VideoToolbox hardware where possible),
///    audio output, and A/V sync — all internal.
///  - This class: pulls decoded video frames out via mpv's *software* render
///    API into BGRA `CVPixelBuffer`s, which flow into the existing Metal
///    pipeline (zero-copy texture wrap → MetalFX Super Resolution → frame
///    interpolation) exactly like AVPlayerItemVideoOutput frames used to.
///
/// Why the software render API (not OpenGL like IINA): IINA lets mpv render
/// straight into a view. This app instead needs each frame *as a texture* to
/// feed MetalFX, so mpv renders into CPU-visible pixel buffers we wrap for
/// Metal. That costs one extra copy per frame vs. IINA, in exchange for the
/// SR/interpolation pipeline working untouched.
///
/// Threading model:
///  - mpv's update callback fires when a frame is ready; the actual
///    software render runs on the dedicated `renderQueue` (never on the UI
///    or MTKView draw path — doing mpv work there deadlocked against menu
///    tracking). The draw loop only consumes finished frames via
///    `latestFrame`, which satisfies the render API's single-render-thread
///    requirement.
///  - A dedicated event thread runs `mpv_wait_event` and forwards property
///    changes (time/duration/pause/EOF/errors) to the main queue.
///  - The mpv client API itself (commands, get/set property) is thread-safe.
final class MPVPlayer {

    /// One decoded-and-rendered video frame. `serial` increments per frame
    /// so the renderer can cheaply detect "new frame since last draw".
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let timeSeconds: Double
        let serial: UInt64
    }

    /// Color characteristics of the decoded video, read from mpv's
    /// `video-params`. Used to tell the user when an HDR source is being
    /// tone-mapped down to SDR — which this player always does, because
    /// mpv's *software* render API can only output 8 bits per channel
    /// (see the note in `createRenderContext`).
    struct ColorInfo: Equatable {
        /// Transfer function, from `video-params/gamma`. mpv's current names
        /// are "pq" (HDR10/Dolby Vision) and "hlg" (broadcast HDR); SDR is
        /// "bt.1886", "srgb", "gamma2.2", ...
        let gamma: String?
        /// Color primaries: "bt.2020" for wide-gamut HDR, "bt.709" for SDR.
        let primaries: String?
        /// Peak luminance in cd/m² from HDR10 metadata, 0 when untagged.
        /// (SDR reference white is ~100 cd/m²; HDR10 typically tags
        /// 1000–4000.)
        let maxLuminance: Double
        /// Bit depth of the *decoded* video, before our 8-bit render path.
        let bitDepth: Int

        /// The transfer function is the reliable signal; a luminance tag well
        /// above SDR reference white is a secondary one for files that are
        /// HDR but carry an unrecognized gamma name.
        var isHDR: Bool {
            if let gamma {
                // Current mpv uses "pq"/"hlg"; the older spellings are kept
                // so this still works against pre-0.38 builds.
                let known = ["pq", "hlg", "st2084", "smpte-st2084", "arib-std-b67"]
                if known.contains(gamma.lowercased()) { return true }
            }
            return maxLuminance > 200
        }

        /// Short human-readable summary for the UI.
        var description: String {
            guard isHDR else {
                return bitDepth > 8 ? "SDR \(bitDepth)-bit" : "SDR"
            }
            let flavour: String
            switch gamma?.lowercased() {
            case "pq", "st2084", "smpte-st2084": flavour = "HDR10 (PQ)"
            case "hlg", "arib-std-b67": flavour = "HLG"
            default: flavour = "HDR"
            }
            var text = "\(flavour) \(bitDepth)-bit"
            if maxLuminance > 0 {
                text += String(format: " · %.0f nits", maxLuminance)
            }
            return text
        }
    }

    /// One selectable stream inside the container — an audio track (language,
    /// commentary) or an embedded subtitle track. Mirrors an entry of mpv's
    /// `track-list`. Only plain value types so it can cross to the main queue.
    struct Track: Identifiable, Equatable {
        enum Kind: String { case video, audio, sub, unknown }
        /// mpv's per-type track id (1-based); the value passed to `aid`/`sid`.
        let id: Int64
        let kind: Kind
        let title: String?
        let lang: String?
        let isDefault: Bool
        let isSelected: Bool
    }

    // MARK: Callbacks (all invoked on the main queue)

    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Fired when mpv's own pause state changes (including pauses mpv
    /// initiates itself, e.g. during a buffering stall) — lets the UI's
    /// play/pause button track reality instead of inferring it.
    var onPauseChanged: ((Bool) -> Void)?
    /// Fired once a file's streams are known (and whenever they change) with
    /// the full track list, so the UI can offer audio/subtitle track pickers.
    var onTracksChanged: (([Track]) -> Void)?
    /// Fired when the decoded video's color characteristics are known, so the
    /// UI can tell the user an HDR source is being tone-mapped.
    var onColorInfoChanged: ((ColorInfo) -> Void)?

    // MARK: State

    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?

    private let stateLock = NSLock()
    private var _latestFrame: Frame?
    private var frameSerial: UInt64 = 0
    private var shuttingDown = false
    private var _pendingTimePos: Double?

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)

    /// Whether frames are being produced at 16 bits per channel. Starts
    /// optimistic and latches to false if this libmpv build rejects the
    /// (undocumented) format — see `renderNewFrame`. Guarded by `stateLock`
    /// because the renderer reads it from the draw thread to pick matching
    /// Metal texture formats.
    private var _usingHighBitDepth = true
    var usingHighBitDepth: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _usingHighBitDepth
    }

    /// Metal pixel format of the buffers currently being produced. The
    /// renderer builds its textures and pipeline state to match.
    var activeMetalFormat: MTLPixelFormat {
        usingHighBitDepth ? PipelineFormat.metal : PipelineFormat.Fallback.metal
    }

    /// All mpv software rendering happens on this queue — NEVER on the UI
    /// or MTKView draw path. Rendering inside the draw callback deadlocked
    /// the app whenever an NSMenu opened during playback (menu tracking
    /// run-loop + per-frame mpv render/property calls vs. mpv's internal
    /// threads). The mpv update callback enqueues work here; the draw loop
    /// only ever picks up finished frames via `latestFrame`.
    private let renderQueue = DispatchQueue(label: "SuperResVideoPlayer.MPVRender", qos: .userInteractive)

    /// Indirection for the C update callback so that neither the callback
    /// nor the blocks it enqueues ever hold a strong reference to the
    /// player. The box owns the queue (queues safely outlive the player);
    /// the player is only ever resolved through the weak reference, which
    /// reads as nil once deinit has begun.
    private final class WeakBox {
        weak var player: MPVPlayer?
        let queue: DispatchQueue
        init(queue: DispatchQueue) { self.queue = queue }
    }
    private var callbackBox: Unmanaged<WeakBox>?

    /// Marks renderQueue so deinit can tell whether it's already running ON
    /// that queue (which happens when a render-queue block drops the last
    /// reference). Calling renderQueue.sync from there would trap with
    /// "dispatch_sync called on queue already owned by current thread".
    private static let renderQueueKey = DispatchSpecificKey<Bool>()

    // MARK: Output mode

    // MARK: Lifecycle

    init() {
        renderQueue.setSpecific(key: Self.renderQueueKey, value: true)

        guard let handle = mpv_create() else {
            print("SuperResVideoPlayer: mpv_create failed — playback unavailable.")
            return
        }
        self.handle = handle

        // Options must be set before mpv_initialize.
        mpv_set_option_string(handle, "vo", "libmpv")          // we drive rendering
        mpv_set_option_string(handle, "hwdec", "auto-copy")    // hw decode, frames copied back for CPU access
        mpv_set_option_string(handle, "keep-open", "yes")      // stay on last frame at EOF (matches old AVPlayer behavior)
        mpv_set_option_string(handle, "input-default-bindings", "no")
        mpv_set_option_string(handle, "audio-display", "no")
        mpv_set_option_string(handle, "terminal", "no")
        mpv_set_option_string(handle, "msg-level", "all=warn")

        // Recent macOS moved its bundled CJK font (PingFang) into a protected
        // PrivateFrameworks path that libass/FreeType can't open — so
        // Chinese/Japanese/Korean subtitles fall back to nothing and render
        // as boxes with the default sans-serif. Point libass at a system CJK
        // font that lives in a readable location (Songti, in
        // /System/Library/Fonts/Supplemental) so those glyphs render.
        // (For guaranteed coverage across all of C/J/K in the shipped app,
        // bundle a font like Noto Sans CJK and name it here instead.)
        mpv_set_option_string(handle, "sub-font", "Songti SC")
        // Detect the encoding of external non-UTF-8 subtitle files (embedded
        // subs are already UTF-8; harmless there).
        mpv_set_option_string(handle, "sub-codepage", "auto")

        // --- HDR handling -------------------------------------------------
        // HDR sources are tone-mapped to SDR, and that is a hard constraint
        // of this architecture rather than a choice: mpv's *software* render API
        // (which we use so each frame arrives as a CPU-visible buffer we can
        // wrap as a Metal texture for MetalFX) only outputs 8 bits per
        // channel — its documented formats are "rgb0"/"bgr0"/"0bgr"/"0rgb",
        // all 4x8-bit, and libmpv's own header warns that "HDR may not work
        // properly" on this path.
        //
        // Given that, make the tone-map deliberate rather than default:
        // BT.2390 is the ITU-recommended curve and preserves highlight detail
        // noticeably better than a naive clip.
        mpv_set_option_string(handle, "tone-mapping", "bt.2390")
        // Measure each scene's actual peak instead of trusting static
        // metadata, which is frequently wrong or absent.
        mpv_set_option_string(handle, "hdr-compute-peak", "yes")
        // Map out-of-gamut BT.2020 colors instead of clipping them.
        mpv_set_option_string(handle, "gamut-mapping-mode", "perceptual")

        guard mpv_initialize(handle) >= 0 else {
            print("SuperResVideoPlayer: mpv_initialize failed — playback unavailable.")
            mpv_terminate_destroy(handle)
            self.handle = nil
            return
        }

        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        // Format NONE = "notify me it changed" without marshalling a value;
        // we re-read the whole list when it fires (see readTracks()).
        mpv_observe_property(handle, 0, "track-list", MPV_FORMAT_NONE)
        mpv_observe_property(handle, 0, "video-params", MPV_FORMAT_NONE)

        createRenderContext()
        startEventThread()
    }

    deinit {
        shutdown()
    }

    /// Tears the engine down deterministically. Idempotent, and safe to call
    /// explicitly before dropping the last reference — which
    /// `PlayerViewModel.rebuild` does when switching output modes.
    ///
    /// The ordering here is load-bearing. The previous version sent "quit"
    /// and let the event thread call `mpv_terminate_destroy` when it saw
    /// MPV_EVENT_SHUTDOWN. That races: the event thread can free the handle
    /// while `mpv_command` is still executing on this thread, which segfaults
    /// inside libmpv's run_client_command. It never showed up while the only
    /// teardown was at process exit; destroying a player mid-session (an
    /// output-mode switch) makes it reproducible.
    ///
    /// So: stop the event loop and *wait for that thread to exit* before
    /// destroying the handle. After the join, nothing else can touch it.
    func shutdown() {
        stateLock.lock()
        if shuttingDown {
            stateLock.unlock()
            return
        }
        shuttingDown = true
        let context = renderContext
        renderContext = nil
        stateLock.unlock()

        // The render context must be freed before the handle is destroyed,
        // and only after any in-flight render on renderQueue has drained.
        // If this is running ON renderQueue (a render-queue block dropped the
        // last reference), the queue is serial so nothing else can be
        // mid-render — and a sync here would deadlock-trap.
        if let context {
            mpv_render_context_set_update_callback(context, nil, nil)
            if DispatchQueue.getSpecific(key: Self.renderQueueKey) != true {
                renderQueue.sync { }
            }
            mpv_render_context_free(context)
        }
        callbackBox?.release()
        callbackBox = nil

        guard let handle else { return }
        self.handle = nil   // no further commands can reach libmpv

        // Ask the loop to stop, then join it. It polls with a short timeout,
        // so this returns promptly; the timeout is a backstop against a
        // wedged thread rather than an expected path.
        eventControl.stop()
        if eventThreadStarted {
            _ = eventThreadFinished.wait(timeout: .now() + 2)
        }
        // Sole owner now — safe to destroy.
        mpv_terminate_destroy(handle)
    }

    private func createRenderContext() {
        guard let handle else { return }
        var context: OpaquePointer?
        let status = "sw".withCString { apiType -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                 data: UnsafeMutableRawPointer(mutating: apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            return mpv_render_context_create(&context, handle, &params)
        }
        guard status >= 0, let context else {
            print("SuperResVideoPlayer: mpv_render_context_create failed (\(status)) — no video output.")
            return
        }
        renderContext = context

        // mpv tells us when a new frame is ready; render it on our
        // dedicated queue. Neither the callback nor the enqueued block may
        // retain self — a block holding the last reference would run
        // deinit on the render queue (see WeakBox/renderQueueKey).
        let box = WeakBox(queue: renderQueue)
        box.player = self
        let retainedBox = Unmanaged.passRetained(box)
        callbackBox = retainedBox
        mpv_render_context_set_update_callback(context, { userdata in
            guard let userdata else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(userdata).takeUnretainedValue()
            box.queue.async { box.player?.renderNewFrame() }
        }, retainedBox.toOpaque())
    }

    // MARK: Event loop

    /// Stop flag for the event loop, in its own object so the thread can own
    /// it strongly without keeping the player alive.
    private final class EventLoopControl {
        private let lock = NSLock()
        private var _stopped = false
        var isStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return _stopped
        }
        func stop() { lock.lock(); _stopped = true; lock.unlock() }
    }
    private let eventControl = EventLoopControl()
    private let eventThreadFinished = DispatchSemaphore(value: 0)
    private var eventThreadStarted = false

    private func startEventThread() {
        guard let handle else { return }
        eventThreadStarted = true
        // Captured strongly: these must outlive the player so `shutdown()`
        // can join the thread even as the last reference goes away.
        let control = eventControl
        let finished = eventThreadFinished
        let thread = Thread { [weak self] in
            defer { finished.signal() }
            while true {
                // Poll rather than block forever, so shutdown() can stop the
                // loop without needing to interrupt libmpv from outside.
                guard !control.isStopped else { return }
                guard let event = mpv_wait_event(handle, 0.1) else { continue }
                if event.pointee.event_id == MPV_EVENT_NONE { continue }
                if event.pointee.event_id == MPV_EVENT_SHUTDOWN {
                    // Do NOT destroy the handle here — shutdown() owns that,
                    // and doing it on both sides is what caused the crash.
                    return
                }
                self?.handleEvent(event)
            }
        }
        thread.name = "SuperResVideoPlayer.MPVEvents"
        thread.start()
    }

    private func handleEvent(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)

            switch name {
            case "time-pos":
                if property.format == MPV_FORMAT_DOUBLE, let raw = property.data {
                    let seconds = raw.assumingMemoryBound(to: Double.self).pointee
                    // Coalesce: mpv emits this many times per second, and
                    // main-queue blocks pile up while a menu is being
                    // tracked. Keep at most one dispatch in flight, always
                    // delivering the newest value.
                    stateLock.lock()
                    let alreadyScheduled = _pendingTimePos != nil
                    _pendingTimePos = seconds
                    stateLock.unlock()
                    if !alreadyScheduled {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.stateLock.lock()
                            let latest = self._pendingTimePos
                            self._pendingTimePos = nil
                            self.stateLock.unlock()
                            if let latest { self.onTimeChanged?(latest) }
                        }
                    }
                }
            case "duration":
                if property.format == MPV_FORMAT_DOUBLE, let raw = property.data {
                    let seconds = raw.assumingMemoryBound(to: Double.self).pointee
                    DispatchQueue.main.async { [weak self] in self?.onDurationChanged?(seconds) }
                }
            case "eof-reached":
                if property.format == MPV_FORMAT_FLAG, let raw = property.data,
                   raw.assumingMemoryBound(to: Int32.self).pointee != 0 {
                    DispatchQueue.main.async { [weak self] in self?.onPlaybackEnded?() }
                }
            case "pause":
                if property.format == MPV_FORMAT_FLAG, let raw = property.data {
                    let paused = raw.assumingMemoryBound(to: Int32.self).pointee != 0
                    DispatchQueue.main.async { [weak self] in self?.onPauseChanged?(paused) }
                }
            case "track-list":
                publishTracks()
            case "video-params":
                publishColorInfo()
            default:
                break
            }

        case MPV_EVENT_FILE_LOADED:
            // Streams are fully known here — reliable point to populate the
            // audio/subtitle pickers even if the track-list observer already
            // fired with partial info.
            publishTracks()
            publishColorInfo()

        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data else { return }
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if endFile.reason == MPV_END_FILE_REASON_ERROR {
                let message = String(cString: mpv_error_string(endFile.error))
                DispatchQueue.main.async { [weak self] in self?.onError?(message) }
            }

        default:
            break
        }
    }

    // MARK: Transport

    func load(url: URL) {
        // Drop the previous video's last frame so it can't linger on
        // screen while the new file spins up.
        stateLock.lock()
        _latestFrame = nil
        stateLock.unlock()

        command(["loadfile", url.path, "replace"])
        setPaused(false)
    }

    func setPaused(_ paused: Bool) {
        guard let handle else { return }
        var flag: Int32 = paused ? 1 : 0
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func seek(to seconds: Double) {
        command(["seek", String(seconds), "absolute+exact"])
    }

    /// mpv's software volume, 0...100 (values above 100 amplify; we don't).
    func setVolume(_ percent: Double) {
        guard let handle else { return }
        var value = min(100, max(0, percent))
        mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &value)
    }

    func setMuted(_ muted: Bool) {
        guard let handle else { return }
        var flag: Int32 = muted ? 1 : 0
        mpv_set_property(handle, "mute", MPV_FORMAT_FLAG, &flag)
    }

    // MARK: HDR output

    /// Switches mpv between tone-mapping HDR down to SDR and handing the HDR
    /// signal through untouched.
    ///
    /// With `passthrough` on, mpv is told the render target is PQ / BT.2020,
    /// so it stops compressing the signal to SDR range and writes PQ-encoded
    /// values into our 16-bit buffers. The layer is then told those values
    /// are PQ (see `MetalVideoView`), and macOS maps them onto the display's
    /// extended dynamic range.
    ///
    /// Only meaningful because the software render path is 16-bit — at 8 bits
    /// per channel, PQ banding would be severe.
    /// - Returns: whether mpv actually accepted the HDR target. `target-trc`
    ///   and `target-prim` are `vo=gpu` options and may be ignored on the
    ///   software render path, so the values are read back rather than
    ///   assumed. Setting `tone-mapping=clip` while mpv is still mapping to
    ///   SDR would hard-clip highlights — a blown-out picture — so that is
    ///   only applied once passthrough is confirmed.
    @discardableResult
    func setHDRPassthrough(_ passthrough: Bool) -> Bool {
        guard let handle else { return false }

        guard passthrough else {
            mpv_set_property_string(handle, "target-trc", "auto")
            mpv_set_property_string(handle, "target-prim", "auto")
            mpv_set_property_string(handle, "tone-mapping", "bt.2390")
            return false
        }

        mpv_set_property_string(handle, "target-trc", "pq")
        mpv_set_property_string(handle, "target-prim", "bt.2020")

        let trc = getPropertyString("target-trc") ?? "?"
        let prim = getPropertyString("target-prim") ?? "?"
        let accepted = trc.lowercased() == "pq"
        print("SuperResVideoPlayer: requested PQ target — mpv reports target-trc=\(trc), target-prim=\(prim)")

        if accepted {
            // Safe now: the target covers the source, so there is nothing to
            // compress and "clip" is a no-op rather than a highlight crusher.
            mpv_set_property_string(handle, "tone-mapping", "clip")
        } else {
            // Fall back to a good tone-map rather than leaving the signal
            // half-converted.
            print("SuperResVideoPlayer: libmpv ignored the PQ target on the software render path — tone-mapping to SDR instead.")
            mpv_set_property_string(handle, "target-trc", "auto")
            mpv_set_property_string(handle, "target-prim", "auto")
            mpv_set_property_string(handle, "tone-mapping", "bt.2390")
        }
        return accepted
    }

    // MARK: Track selection

    /// Switch the active audio track by its mpv id (from `Track.id`).
    func setAudioTrack(_ id: Int64) {
        guard let handle else { return }
        mpv_set_property_string(handle, "aid", String(id))
    }

    /// Switch the active embedded subtitle track by id, or pass `nil` to turn
    /// embedded subtitles off. (These are the container's own subtitles,
    /// rendered by mpv into the frame — separate from the app's AI subtitles.)
    func setSubtitleTrack(_ id: Int64?) {
        guard let handle else { return }
        mpv_set_property_string(handle, "sid", id.map(String.init) ?? "no")
    }

    /// Reads the decoded video's color characteristics and delivers them on
    /// the main queue. Only publishes once the values are actually known
    /// (mpv reports empty video-params before the first frame is decoded).
    private func publishColorInfo() {
        guard let handle else { return }
        let gamma = getPropertyString("video-params/gamma")
        let primaries = getPropertyString("video-params/primaries")
        guard gamma != nil || primaries != nil else { return }

        // Peak luminance. `max-luma` (absolute cd/m²) is the current
        // property; `sig-peak` is deprecated and expressed as a multiple of
        // SDR reference white, so older mpv builds are converted at the
        // conventional 100 cd/m² reference.
        var maxLuma: Double = 0
        if mpv_get_property(handle, "video-params/max-luma", MPV_FORMAT_DOUBLE, &maxLuma) < 0
            || maxLuma <= 0 {
            var legacyPeak: Double = 0
            if mpv_get_property(handle, "video-params/sig-peak", MPV_FORMAT_DOUBLE, &legacyPeak) >= 0,
               legacyPeak > 1.01 {
                maxLuma = legacyPeak * 100
            } else {
                maxLuma = 0
            }
        }

        // mpv has no bit-depth property — the depth is encoded in the pixel
        // format name (yuv420p10le, p010, gbrp12le, ...).
        let bitDepth = VideoMath.bitDepth(fromPixelFormat: getPropertyString("video-params/pixelformat"))

        let info = ColorInfo(
            gamma: gamma,
            primaries: primaries,
            maxLuminance: maxLuma,
            bitDepth: bitDepth
        )
        DispatchQueue.main.async { [weak self] in self?.onColorInfoChanged?(info) }
    }

    /// Reads mpv's current `track-list` and delivers it on the main queue.
    /// Safe to call from the event thread — the mpv client API is thread-safe.
    private func publishTracks() {
        let tracks = readTracks()
        DispatchQueue.main.async { [weak self] in self?.onTracksChanged?(tracks) }
    }

    private func readTracks() -> [Track] {
        guard let handle else { return [] }
        var count: Int64 = 0
        guard mpv_get_property(handle, "track-list/count", MPV_FORMAT_INT64, &count) >= 0,
              count > 0 else { return [] }

        var tracks: [Track] = []
        for index in 0..<count {
            var id: Int64 = 0
            mpv_get_property(handle, "track-list/\(index)/id", MPV_FORMAT_INT64, &id)
            let type = getPropertyString("track-list/\(index)/type") ?? "unknown"
            let title = getPropertyString("track-list/\(index)/title")
            let lang = getPropertyString("track-list/\(index)/lang")
            var isDefault: Int32 = 0
            mpv_get_property(handle, "track-list/\(index)/default", MPV_FORMAT_FLAG, &isDefault)
            var isSelected: Int32 = 0
            mpv_get_property(handle, "track-list/\(index)/selected", MPV_FORMAT_FLAG, &isSelected)
            tracks.append(Track(id: id,
                                kind: Track.Kind(rawValue: type) ?? .unknown,
                                title: title,
                                lang: lang,
                                isDefault: isDefault != 0,
                                isSelected: isSelected != 0))
        }
        return tracks
    }

    /// mpv returns a heap-allocated C string that must be freed with mpv_free.
    /// Empty strings become nil so the UI can fall back to a generic label.
    private func getPropertyString(_ name: String) -> String? {
        guard let handle, let cString = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cString) }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }

    /// Current playback position in seconds. Thread-safe; used by the
    /// renderer every draw to compute the interpolation phase.
    var playbackTime: Double {
        getDouble("time-pos") ?? 0
    }

    // MARK: Frame output

    /// Runs exclusively on `renderQueue` (triggered by mpv's update
    /// callback). If mpv has a new video frame ready, software-renders it
    /// into a fresh BGRA CVPixelBuffer and publishes it via `latestFrame`,
    /// which the Metal draw loop consumes without doing any mpv work itself.
    private func renderNewFrame() {
        stateLock.lock()
        let context = renderContext
        let isShuttingDown = shuttingDown
        stateLock.unlock()
        guard let context, !isShuttingDown else { return }

        let flags = mpv_render_context_update(context)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else {
            return
        }

        let width = Int(getInt64("dwidth") ?? 0)
        let height = Int(getInt64("dheight") ?? 0)
        guard width > 0, height > 0 else { return }

        if pixelBufferPool == nil || poolSize != (width, height) {
            rebuildPixelBufferPool(width: width, height: height)
        }
        guard let pool = pixelBufferPool else { return }

        var newBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &newBuffer) == kCVReturnSuccess,
              let pixelBuffer = newBuffer else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        var size: [Int32] = [Int32(width), Int32(height)]
        var stride: Int = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // 16-bit ("rgba64le") when the build accepts it, else 8-bit "bgr0".
        // Both match their CVPixelBuffer layout byte for byte; the alpha
        // channel is ignored downstream, as the pipeline never blends.
        let formatName = usingHighBitDepth
            ? PipelineFormat.mpvSoftwareFormat
            : PipelineFormat.Fallback.mpvSoftwareFormat

        let status = formatName.withCString { format -> Int32 in
            size.withUnsafeMutableBufferPointer { sizePointer in
                withUnsafeMutablePointer(to: &stride) { stridePointer -> Int32 in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE,
                                         data: UnsafeMutableRawPointer(sizePointer.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT,
                                         data: UnsafeMutableRawPointer(mutating: format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE,
                                         data: UnsafeMutableRawPointer(stridePointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER,
                                         data: baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    return mpv_render_context_render(context, &params)
                }
            }
        }

        guard status >= 0 else {
            // The 16-bit format is undocumented, so a libmpv build that
            // doesn't accept it must not break playback — drop to 8-bit
            // permanently and pick up from the next frame.
            if usingHighBitDepth {
                print("SuperResVideoPlayer: libmpv rejected \(formatName) (\(status)) — falling back to 8-bit output.")
                stateLock.lock()
                _usingHighBitDepth = false
                stateLock.unlock()
                pixelBufferPool = nil   // reallocate in the fallback format
            }
            return
        }

        let timeSeconds = getDoubleUnlocked("time-pos") ?? 0
        stateLock.lock()
        frameSerial &+= 1
        _latestFrame = Frame(pixelBuffer: pixelBuffer,
                             timeSeconds: timeSeconds,
                             serial: frameSerial)
        stateLock.unlock()
    }

    /// Most recently rendered frame; consumed by the Metal draw loop.
    /// Thread-safe.
    var latestFrame: Frame? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _latestFrame
    }

    private func rebuildPixelBufferPool(width: Int, height: Int) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: usingHighBitDepth
                ? PipelineFormat.coreVideo
                : PipelineFormat.Fallback.coreVideo,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        pixelBufferPool = pool
        poolSize = (width, height)
    }

    // MARK: Property/command plumbing

    private func command(_ args: [String]) {
        guard let handle else { return }
        let cStrings = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        argv.append(nil)
        mpv_command(handle, &argv)
    }

    private func getDouble(_ name: String) -> Double? {
        getDoubleUnlocked(name)
    }

    private func getDoubleUnlocked(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value
    }

    private func getInt64(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var value: Int64 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return value
    }
}
