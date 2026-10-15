import AppKit
import Foundation

public enum SoundPlayer {
    // System sounds, which a user can delete; hence the `guard` below.
    private static let startSoundName = "Tink"
    private static let stopSoundName = "Pop"

    public static func playStart() {
        play(named: startSoundName)
    }

    public static func playStop() {
        play(named: stopSoundName)
    }

    // A fresh instance per call, so overlapping start and stop sounds do not cut each
    // other off.
    private static func play(named name: String) {
        guard let sound = NSSound(named: name) else { return }
        sound.play()
    }
}
