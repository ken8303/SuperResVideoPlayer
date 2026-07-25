import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    /// Owned by the App scene so the menu-bar commands can drive playback
    /// with keyboard shortcuts.
    @ObservedObject var playerViewModel: PlayerViewModel

    /// Highlights the video area while a file is dragged over it.
    @State private var isDropTargeted = false

    // Auto-hiding controls (full screen only).
    @State private var isFullScreen = false
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isFullScreen {
                // Overlay the controls so hiding them yields full-frame video.
                ZStack(alignment: .bottom) {
                    videoArea
                    controlsBar
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                }
            } else {
                VStack(spacing: 0) {
                    videoArea
                    controlsBar
                }
                .frame(minWidth: 720, minHeight: 480)
            }
        }
        .navigationTitle(playerViewModel.videoTitle)
        // Opening a video from Finder ("Open With", or dropping it on the
        // Dock icon) delivers the file here — without this the app would
        // launch but never load the file, since Info.plist advertises
        // CFBundleDocumentTypes.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            playerViewModel.load(url: url)
        }
        // Track full-screen state so the layout and auto-hide follow it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
            showControlsTemporarily()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
            hideControlsTask?.cancel()
            controlsVisible = true
        }
        .onChange(of: playerViewModel.translationTargetIdentifier) { _, _ in
            playerViewModel.startSubtitleTranslation()
        }
        .onChange(of: playerViewModel.subtitleLanguage) { _, _ in
            // Start the (one-time) speech model download as soon as a
            // not-yet-installed language is picked.
            playerViewModel.ensureSpeechModelDownloaded()
        }
        .onChange(of: playerViewModel.subtitleCues) { _, _ in
            // Newly generated cues: retranslate if a target is active.
            playerViewModel.startSubtitleTranslation()
        }
    }

    private var videoArea: some View {
        ZStack(alignment: .bottom) {
            MetalVideoView(playerViewModel: playerViewModel)
                .background(Color.black)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 4)
                            .background(Color.accentColor.opacity(0.12))
                            .allowsHitTesting(false)
                    }
                }

            if let text = playerViewModel.subtitleText(at: playerViewModel.currentTime) {
                Text(text)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    // Sit above the controls bar when it's showing.
                    .padding(.bottom, isFullScreen && controlsVisible ? 140 : 24)
                    .padding(.horizontal, 40)
                    .shadow(radius: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        // Right-click the picture for the full settings menu — the only
        // always-reachable settings surface in full screen once the
        // controls bar has auto-hidden.
        .contextMenu {
            SettingsMenuContent(viewModel: playerViewModel)
        }
        // Any mouse movement over the picture reveals the controls again.
        .onContinuousHover { phase in
            if case .active = phase { showControlsTemporarily() }
        }
        // Drag a video file straight onto the picture to open it.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    playerViewModel.load(url: url)
                }
            }
            return true
        }
    }

    private var controlsBar: some View {
        controls
            .padding()
            .background(.regularMaterial)
            // Keep the bar alive while the pointer is over it — otherwise
            // the auto-hide timer fires mid-interaction (e.g. while dragging
            // the volume slider in full screen) and the controls vanish.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hideControlsTask?.cancel()
                    if !controlsVisible {
                        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
                    }
                case .ended:
                    showControlsTemporarily()   // restart the countdown on exit
                }
            }
    }

    /// Shows the controls and (in full screen) schedules them to fade out
    /// after a few seconds of no mouse movement.
    private func showControlsTemporarily() {
        hideControlsTask?.cancel()
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
        guard isFullScreen else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isFullScreen else { return }
            withAnimation(.easeOut(duration: 0.4)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(playerViewModel.videoTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if playerViewModel.isExportingVideo {
                    Button("Cancel Export") {
                        playerViewModel.cancelVideoExport()
                    }
                } else {
                    Button("Test 10s") {
                        playerViewModel.exportEnhancedVideo(durationLimit: 10)
                    }
                    .disabled(playerViewModel.duration == 0)
                    .help("Export just the first 10 seconds — quick way to compare enhancer engines.")

                    Button("Export Video…") {
                        playerViewModel.exportEnhancedVideo()
                    }
                    .disabled(playerViewModel.duration == 0)
                }
                Button("Open Video…") {
                    playerViewModel.presentOpenPanel()
                }
                .disabled(playerViewModel.isExportingVideo)
            }

            if let error = playerViewModel.playbackErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    playerViewModel.togglePlayPause()
                } label: {
                    Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                .disabled(playerViewModel.duration == 0)

                Slider(
                    value: Binding(
                        get: { playerViewModel.currentTime },
                        set: { playerViewModel.seek(toSeconds: $0) }
                    ),
                    in: 0...max(playerViewModel.duration, 0.01),
                    onEditingChanged: { editing in
                        playerViewModel.isScrubbing = editing
                    }
                )
                .disabled(playerViewModel.duration == 0)

                Text(timeString(playerViewModel.currentTime) + " / " + timeString(playerViewModel.duration))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(minWidth: 100, alignment: .trailing)

                // Volume (also on ↑/↓ and M via the Playback menu).
                Button {
                    playerViewModel.toggleMute()
                } label: {
                    Image(systemName: playerViewModel.isMuted || playerViewModel.volume == 0
                          ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .help("Mute (M)")

                Slider(value: $playerViewModel.volume, in: 0...100)
                    .frame(width: 80)
                    .disabled(playerViewModel.isMuted)

                Button {
                    WindowControl.toggleFullScreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 18)
                }
                .help("Full screen (F)")
            }

            Divider()

            HStack {
                Toggle("AI Image Enhancer", isOn: $playerViewModel.imageEnhancementEnabled)

                Spacer()

                Picker("Engine", selection: $playerViewModel.enhancementEngine) {
                    Text("Classic").tag(EnhancerEngine.classic)
                    Text("Neural").tag(EnhancerEngine.neural)
                    Text("Max").tag(EnhancerEngine.max)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .disabled(!playerViewModel.imageEnhancementEnabled)

                Slider(value: $playerViewModel.enhancementStrength, in: 0...1)
                    .frame(width: 110)
                    .disabled(!playerViewModel.imageEnhancementEnabled)
                Text("\(Int(playerViewModel.enhancementStrength * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            if playerViewModel.imageEnhancementEnabled && playerViewModel.enhancementEngine == .max {
                Text(NeuralEnhancer.isModelAvailable
                     ? "Max (Real-ESRGAN) applies during export — playback previews with the Neural engine."
                     : "Max needs an optional Real-ESRGAN model that isn't installed. Use Classic or Neural, which need nothing extra.")
                    .font(.caption)
                    .foregroundStyle(NeuralEnhancer.isModelAvailable ? Color.secondary : Color.orange)
            }

            HStack {
                Toggle("Super Resolution", isOn: $playerViewModel.superResolutionEnabled)

                Spacer()

                Text("Scale:")
                    .foregroundStyle(.secondary)
                Picker("Scale", selection: $playerViewModel.upscaleFactor) {
                    Text("1.3x").tag(1.3)
                    Text("1.5x").tag(1.5)
                    Text("2.0x").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!playerViewModel.superResolutionEnabled)
            }

            if playerViewModel.superResolutionUnsupported {
                Text("Not supported on this Mac's GPU — the toggle above has no effect.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("AI Frame Interpolation")
                Spacer()
                Picker("Smoothing", selection: $playerViewModel.frameInterpolationMultiplier) {
                    Text("Off").tag(1)
                    Text("2x").tag(2)
                    Text("3x").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if playerViewModel.frameInterpolationMultiplier > 1 && playerViewModel.nativeFrameInterpolationUnsupported {
                Text("Native MetalFX interpolation isn't supported here — using the custom warp fallback instead.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let stats = playerViewModel.pipelineStatus {
                Text(stats)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Audio-track / embedded-subtitle pickers appear only when the
            // file actually offers a choice (multi-language MKV, etc.).
            if playerViewModel.audioTracks.count > 1 || !playerViewModel.subtitleTracks.isEmpty {
                Divider()
                trackControls
            }

            Divider()

            subtitleControls
        }
    }

    /// Selectors for the container's own audio tracks and embedded subtitle
    /// tracks — distinct from the AI subtitle generator below.
    private var trackControls: some View {
        HStack {
            if playerViewModel.audioTracks.count > 1 {
                Text("Audio")
                    .foregroundStyle(.secondary)
                Picker("Audio", selection: Binding(
                    get: { playerViewModel.currentAudioTrackID },
                    set: { playerViewModel.selectAudioTrack($0) }
                )) {
                    ForEach(playerViewModel.audioTracks) { track in
                        Text(trackLabel(for: track)).tag(track.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            Spacer()

            if !playerViewModel.subtitleTracks.isEmpty {
                Text("Subtitle Track")
                    .foregroundStyle(.secondary)
                Picker("Subtitle Track", selection: Binding(
                    get: { playerViewModel.currentSubtitleTrackID },
                    set: { playerViewModel.selectSubtitleTrack($0) }
                )) {
                    Text("Off").tag(Int64(0))
                    ForEach(playerViewModel.subtitleTracks) { track in
                        Text(trackLabel(for: track)).tag(track.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .help("Subtitles embedded in the file, rendered by the player — separate from AI-generated subtitles below.")
            }
        }
    }

    private func trackLabel(for track: MPVPlayer.Track) -> String {
        videoTrackLabel(for: track)
    }

    private var subtitleControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Subtitles", isOn: $playerViewModel.subtitlesEnabled)
                    .disabled(playerViewModel.subtitleCues.isEmpty)

                Spacer()

                Picker("Language", selection: $playerViewModel.subtitleLanguage) {
                    ForEach(playerViewModel.availableSubtitleLocales, id: \.identifier) { locale in
                        Text(languageLabel(for: locale))
                            .tag(locale)
                    }
                }
                .frame(width: 200)
                .disabled(playerViewModel.isGeneratingSubtitles)

                if playerViewModel.isGeneratingSubtitles {
                    ProgressView(value: playerViewModel.subtitleGenerationProgress)
                        .frame(width: 90)
                    Button("Cancel") {
                        playerViewModel.cancelSubtitleGeneration()
                    }
                } else {
                    Button("Generate Subtitles") {
                        playerViewModel.generateSubtitles()
                    }
                    .disabled(playerViewModel.duration == 0)

                    Button("Export .srt…") {
                        playerViewModel.exportSRT()
                    }
                    .disabled(playerViewModel.subtitleCues.isEmpty)
                }
            }

            HStack {
                Text("Translate to")
                    .foregroundStyle(.secondary)

                Spacer()

                if playerViewModel.isTranslatingSubtitles {
                    ProgressView()
                        .controlSize(.small)
                }

                Picker("Translate to", selection: $playerViewModel.translationTargetIdentifier) {
                    Text("Off").tag("")
                    Text("Traditional Chinese").tag("zh-Hant")
                    Text("Simplified Chinese").tag("zh-Hans")
                    Text("English").tag("en")
                    Text("Japanese").tag("ja")
                    Text("Korean").tag("ko")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                }
                .labelsHidden()
                .frame(width: 200)
                .disabled(playerViewModel.subtitleCues.isEmpty || playerViewModel.isGeneratingSubtitles)
            }

            if let status = playerViewModel.statusMessage {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if let error = playerViewModel.subtitleErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func languageLabel(for locale: Locale) -> String {
        let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        let installed = playerViewModel.installedSpeechLocaleIdentifiers
            .contains(locale.identifier(.bcp47))
        return installed ? "\(name) (downloaded)" : name
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// Human-readable label for an audio/subtitle track: title and/or language,
/// falling back to the track number, with a default marker. Shared by the
/// controls-bar pickers, the video context menu, and the Video menu.
func videoTrackLabel(for track: MPVPlayer.Track) -> String {
    var parts: [String] = []
    if let title = track.title, !title.isEmpty { parts.append(title) }
    if let lang = track.lang, !lang.isEmpty { parts.append("(\(lang))") }
    if parts.isEmpty { parts.append("Track \(track.id)") }
    var label = parts.joined(separator: " ")
    if track.isDefault { label += " — default" }
    return label
}

/// The player's settings, as menu items. Used in two places so settings stay
/// reachable everywhere: the right-click context menu on the video (works in
/// full screen after the controls auto-hide) and the "Video" menu in the
/// menu bar. Pickers render as submenus with checkmarks; Toggles as
/// checkmarked items.
///
/// IMPORTANT: this view must not observe `PlayerViewModel` directly.
/// `currentTime` publishes several times a second during playback, and every
/// publish would rebuild the open NSMenu — making it flash and impossible to
/// interact with. Instead it observes `viewModel.menuState`, which fires
/// only when a value these menus actually display changes; the view model is
/// held as a plain reference and all bindings are built by hand.
struct SettingsMenuContent: View {
    let viewModel: PlayerViewModel
    @ObservedObject private var menuState: PlayerViewModel.MenuState

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        self.menuState = viewModel.menuState
    }

    var body: some View {
        // --- Container streams -------------------------------------------
        if viewModel.audioTracks.count > 1 {
            Picker("Audio Track", selection: Binding(
                get: { viewModel.currentAudioTrackID },
                set: { viewModel.selectAudioTrack($0) }
            )) {
                ForEach(viewModel.audioTracks) { track in
                    Text(videoTrackLabel(for: track)).tag(track.id)
                }
            }
        }
        if !viewModel.subtitleTracks.isEmpty {
            Picker("Subtitle Track", selection: Binding(
                get: { viewModel.currentSubtitleTrackID },
                set: { viewModel.selectSubtitleTrack($0) }
            )) {
                Text("Off").tag(Int64(0))
                ForEach(viewModel.subtitleTracks) { track in
                    Text(videoTrackLabel(for: track)).tag(track.id)
                }
            }
        }
        if viewModel.audioTracks.count > 1 || !viewModel.subtitleTracks.isEmpty {
            Divider()
        }

        // --- Enhancement pipeline ----------------------------------------
        Toggle("AI Image Enhancer", isOn: Binding(
            get: { viewModel.imageEnhancementEnabled },
            set: { viewModel.imageEnhancementEnabled = $0 }
        ))
        Picker("Enhancer Engine", selection: Binding(
            get: { viewModel.enhancementEngine },
            set: { viewModel.enhancementEngine = $0 }
        )) {
            Text("Classic").tag(EnhancerEngine.classic)
            Text("Neural").tag(EnhancerEngine.neural)
            Text("Max").tag(EnhancerEngine.max)
        }
        .disabled(!viewModel.imageEnhancementEnabled)

        Toggle("Super Resolution", isOn: Binding(
            get: { viewModel.superResolutionEnabled },
            set: { viewModel.superResolutionEnabled = $0 }
        ))
        Picker("Upscale Factor", selection: Binding(
            get: { viewModel.upscaleFactor },
            set: { viewModel.upscaleFactor = $0 }
        )) {
            Text("1.3x").tag(1.3)
            Text("1.5x").tag(1.5)
            Text("2.0x").tag(2.0)
        }
        .disabled(!viewModel.superResolutionEnabled)

        Picker("AI Frame Interpolation", selection: Binding(
            get: { viewModel.frameInterpolationMultiplier },
            set: { viewModel.frameInterpolationMultiplier = $0 }
        )) {
            Text("Off").tag(1)
            Text("2x").tag(2)
            Text("3x").tag(3)
        }

        Divider()

        // --- AI subtitles -------------------------------------------------
        Toggle("AI Subtitles", isOn: Binding(
            get: { viewModel.subtitlesEnabled },
            set: { viewModel.subtitlesEnabled = $0 }
        ))
        .disabled(viewModel.subtitleCues.isEmpty)
        if viewModel.isGeneratingSubtitles {
            Button("Cancel Subtitle Generation") {
                viewModel.cancelSubtitleGeneration()
            }
        } else {
            Button("Generate Subtitles") {
                viewModel.generateSubtitles()
            }
            .disabled(viewModel.duration == 0)
        }
    }
}

#Preview {
    ContentView(playerViewModel: PlayerViewModel())
}
