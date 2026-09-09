import AppKit
import Foundation

/// Short feedback sounds for record start and stop.
///
/// The overlay is non-activating and easy to miss when you are looking at the
/// text field you are dictating into, so audio is the primary feedback.
public enum SoundPlayer {
    /// Built-in alert sounds from /System/Library/Sounds. They always exist on a
    /// stock system, but a user can delete them, hence the `guard` on nil.
    private static let startSoundName = "Tink"
    private static let stopSoundName = "Pop"

    public static func playStart() {
        play(named: startSoundName)
    }

    public static func playStop() {
        play(named: stopSoundName)
    }

    /// `NSSound.play()` returns immediately and plays on its own thread, so this
    /// never blocks the hotkey path. A fresh instance per call means overlapping
    /// start/stop sounds do not cut each other off.
    private static func play(named name: String) {
        guard let sound = NSSound(named: name) else { return }
        sound.play()
    }
}
