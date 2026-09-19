import Combine
import Foundation

/// High-frequency playback position isolated from the rest of the player's
/// observable state. libmpv updates this several times per second; keeping it
/// separate prevents every settings control and Metal bridge from being
/// invalidated just to advance the timeline and subtitle overlay.
final class PlaybackClock: ObservableObject {
    @Published var currentTime: TimeInterval = 0
}
