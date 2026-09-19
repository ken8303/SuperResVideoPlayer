import SwiftUI

/// The only controls subtree that observes the rapidly changing playback
/// clock. The larger settings/export/subtitle controls tree stays untouched
/// while the video position advances.
struct PlaybackTransportView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject private var clock: PlaybackClock

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        self.clock = viewModel.playbackClock
    }

    var body: some View {
        HStack {
            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24)
            }
            .disabled(viewModel.duration == 0)

            Slider(
                value: Binding(
                    get: { clock.currentTime },
                    set: { viewModel.seek(toSeconds: $0) }
                ),
                in: 0...max(viewModel.duration, 0.01),
                onEditingChanged: { viewModel.isScrubbing = $0 }
            )
            .disabled(viewModel.duration == 0)

            Text(timeString(clock.currentTime) + " / " + timeString(viewModel.duration))
                .font(.caption)
                .monospacedDigit()
                .frame(minWidth: 100, alignment: .trailing)

            Button {
                viewModel.toggleMute()
            } label: {
                Image(systemName: viewModel.isMuted || viewModel.volume == 0
                      ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .help("Mute (M)")

            Slider(value: $viewModel.volume, in: 0...100)
                .frame(width: 80)
                .disabled(viewModel.isMuted)

            Button {
                WindowControl.toggleFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 18)
            }
            .help("Full screen (F)")
        }
    }
}

/// Small clock-driven overlay kept separate from ContentView so a subtitle
/// lookup does not invalidate the video view or controls hierarchy.
struct SubtitleOverlayView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject private var clock: PlaybackClock
    let bottomPadding: CGFloat

    init(viewModel: PlayerViewModel, bottomPadding: CGFloat) {
        self.viewModel = viewModel
        self.clock = viewModel.playbackClock
        self.bottomPadding = bottomPadding
    }

    var body: some View {
        if let text = viewModel.subtitleText(at: clock.currentTime) {
            Text(text)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, bottomPadding)
                .padding(.horizontal, 40)
                .shadow(radius: 2)
                .allowsHitTesting(false)
        }
    }
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
