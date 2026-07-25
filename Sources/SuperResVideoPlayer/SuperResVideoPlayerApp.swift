import SwiftUI
import AppKit

@main
struct SuperResVideoPlayerApp: App {
    /// Owned here (rather than in ContentView) so the menu-bar commands
    /// below can drive playback too — that's what gives us real keyboard
    /// shortcuts (Space, arrows) instead of mouse-only controls.
    ///
    /// Deliberately a plain `static let`, NOT `@StateObject`: observing the
    /// view model here would re-evaluate this App's `body` — and with it the
    /// whole `.commands` tree — on every `currentTime` publish (several
    /// times a second during playback). That rebuilds the open menu-bar
    /// menus continuously, making them flash and swallow clicks. Views that
    /// genuinely need to re-render on playback state (ContentView) observe
    /// it themselves; menus observe the narrow `menuState` instead.
    /// `static` guarantees a single instance even if SwiftUI re-creates the
    /// App struct.
    private static let sharedViewModel = PlayerViewModel()
    private var playerViewModel: PlayerViewModel { Self.sharedViewModel }

    init() {
        // A plain SPM executable has no .app bundle, so macOS launches it
        // as a background process: no Dock icon, no menu bar, and the
        // window can appear behind everything (or not at all). Promote it
        // to a regular foreground app and bring it to the front.
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(playerViewModel: playerViewModel)
        }
        .windowResizability(.contentSize)
        .commands {
            PlaybackCommands(viewModel: playerViewModel)
            VideoSettingsCommands(viewModel: playerViewModel)
        }
    }
}

/// Menu-bar commands — these are what register the keyboard shortcuts.
///
/// Observes `menuState` rather than the view model itself, for the same
/// reason as `SettingsMenuContent`: the view model publishes `currentTime`
/// several times a second, and any observation at this level rebuilds the
/// menu-bar menus continuously (flashing, unclickable). `menuState` fires
/// only on the values these items display — play/pause, mute, whether a
/// video is loaded, whether an export is running.
struct PlaybackCommands: Commands {
    let viewModel: PlayerViewModel
    @ObservedObject private var menuState: PlayerViewModel.MenuState

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        self.menuState = viewModel.menuState
    }

    var body: some Commands {
        // Replace "New" with "Open Video…" (⌘O).
        CommandGroup(replacing: .newItem) {
            Button("Open Video…") {
                viewModel.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(viewModel.isExportingVideo)
        }

        CommandMenu("Playback") {
            Button(viewModel.isPlaying ? "Pause" : "Play") {
                viewModel.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(viewModel.duration == 0)

            Divider()

            Button("Back 10 Seconds") { viewModel.step(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(viewModel.duration == 0)
            Button("Forward 10 Seconds") { viewModel.step(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(viewModel.duration == 0)

            Divider()

            Button("Volume Up") { viewModel.adjustVolume(by: 5) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Volume Down") { viewModel.adjustVolume(by: -5) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button(viewModel.isMuted ? "Unmute" : "Mute") { viewModel.toggleMute() }
                .keyboardShortcut("m", modifiers: [])

            Divider()

            Button("Toggle Full Screen") { WindowControl.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [])
        }
    }
}

/// The "Video" settings menu — same items as the video's right-click menu
/// (in full screen: move the pointer to the top of the screen to reveal the
/// menu bar). Kept OUT of `PlaybackCommands` on purpose: that struct
/// observes the whole view model (it needs the Play/Pause label), so it
/// re-evaluates on every time-position tick — nesting this menu there made
/// it flash and un-clickable during playback. Here the view model is a plain
/// reference and `SettingsMenuContent` subscribes only to `menuState`.
struct VideoSettingsCommands: Commands {
    let viewModel: PlayerViewModel

    var body: some Commands {
        CommandMenu("Video") {
            SettingsMenuContent(viewModel: viewModel)
        }
    }
}

/// Full-screen toggling. SwiftUI has no direct API for this on macOS, so we
/// reach for the key window — which is also what makes plain `F` (no
/// modifier) work as a player-style shortcut alongside macOS's own ⌃⌘F.
enum WindowControl {
    static func toggleFullScreen() {
        (NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first)?
            .toggleFullScreen(nil)
    }
}
