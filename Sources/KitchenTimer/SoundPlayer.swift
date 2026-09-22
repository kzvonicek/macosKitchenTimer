import AppKit
import AVFoundation

/// One retained player instead of a fresh instance per ring.
///
/// A brand-new `AVAudioPlayer` that is played immediately is unreliable:
/// if the audio device went to sleep in the meantime, the first playback is
/// swallowed. A retained, prepared player keeps the audio unit alive, so the
/// sound comes out every time.
@MainActor
final class SoundPlayer {

    static let shared = SoundPlayer()

    private var player: AVAudioPlayer?
    private var loadedID: String?

    var duration: TimeInterval { player?.duration ?? 0 }

    /// Loads the sound if the selection changed. Called at launch and after
    /// every change in the menu, not at the moment it has to be heard.
    func prepare() {
        let id = Settings.shared.soundID
        if loadedID == id, player != nil {
            player?.prepareToPlay()
            return
        }
        player?.stop()
        player = Settings.shared.makePlayer()
        loadedID = player == nil ? nil : id
    }

    /// - Parameter times: how many times in a row (the repeat is handled by
    ///   AVAudioPlayer itself; a timer would drift against the sound length).
    @discardableResult
    func play(times: Int = 1) -> Bool {
        prepare()
        guard let p = player else { return false }
        p.stop()
        p.currentTime = 0
        p.numberOfLoops = max(0, times - 1)
        return p.play()
    }

    /// How much of the sound actually played. `play() == true` only means
    /// playback started — this shows whether it ran.
    var progress: TimeInterval { player?.currentTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        // stays loaded and ready for next time
        player?.prepareToPlay()
    }
}
