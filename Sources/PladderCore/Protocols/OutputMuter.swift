import Foundation

/// Mutes the system's output device while the microphone is open.
///
/// Dictating over music or a call puts that audio into the microphone. The
/// implementation lives outside `PladderCore` because the device itself is a
/// CoreAudio object; the state machine that decides when to touch it does not
/// have to be, and is in `OutputMuteController`.
public protocol OutputMuter: Sendable {
    /// Capture has started. Arms the mute; it lands after a short delay so a
    /// tap-and-release never toggles it.
    func recordingStarted() async
    /// Capture has ended for any reason: release, cancel, or the watchdog.
    /// Disarms a pending mute and restores the device this muter muted.
    func recordingEnded() async
}

/// The one thing `OutputMuteController` needs from the audio system. Small
/// enough that a fake in a test is a handful of lines, which is the point:
/// the ordering rules are what break, not the CoreAudio calls.
public protocol OutputMuteControl: Sendable {
    /// Current default output device, or nil when there is none.
    func defaultOutputDevice() -> UInt32?
    /// Whether the device is muted, or nil when it has no mute control.
    func isMuted(_ device: UInt32) -> Bool?
    func setMuted(_ muted: Bool, on device: UInt32) throws
}
