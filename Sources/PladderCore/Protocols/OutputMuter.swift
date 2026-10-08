import Foundation

/// Mutes the system's output device while the microphone is open.
///
/// Dictating over music or a call puts that audio into the microphone. The
/// implementation lives outside `PladderCore` because the device itself is a
/// CoreAudio object; the state machine that decides when to touch it does not
/// have to be, and is in `OutputMuteController`.
///
/// Every call names its recording. The caller numbers recordings, one session
/// per recording, increasing, and fires the start and the end on tasks that
/// nothing orders, so the end can arrive first; the number is what lets the
/// muter tell a late start from a live one.
public protocol OutputMuter: Sendable {
    /// Capture of recording `session` has started. Arms the mute; it lands
    /// after a short delay so a tap-and-release never toggles it. Does nothing
    /// at all for a session that has already ended or been overtaken by a
    /// newer one.
    func recordingStarted(session: Int) async
    /// Capture of recording `session` has ended for any reason: release,
    /// cancel, or the watchdog. Disarms a pending mute and restores what this
    /// muter muted, whether it arrives before or after the session's start;
    /// never waits for the start's delay. The end of an older session than
    /// the newest seen does nothing.
    func recordingEnded(session: Int) async

    /// Transitional, for the coordinator until it numbers its recordings:
    /// the session-less pair, a start opening the next session and an end
    /// closing the newest. Remove with the defaults below once nothing calls
    /// it.
    func recordingStarted() async
    /// Transitional; see `recordingStarted()`.
    func recordingEnded() async
}

/// Transitional defaults, so a conformer written against either pair still
/// conforms. The session pair forwards to the session-less one, which does
/// nothing by default, so neither can recurse into the other.
extension OutputMuter {
    public func recordingStarted(session: Int) async { await recordingStarted() }
    public func recordingEnded(session: Int) async { await recordingEnded() }
    public func recordingStarted() async {}
    public func recordingEnded() async {}
}

/// The mute switches of one output device, element → muted. Element 0 is the
/// device's master mute (`kAudioObjectPropertyElementMain`), 1 and up its
/// channels; a device has one or the other, or neither. Per element rather
/// than one Bool, because a user can mute one channel of a stereo pair, and
/// putting the device back means putting back exactly that.
public struct MuteState: Sendable, Equatable {
    public var elements: [UInt32: Bool]

    public init(_ elements: [UInt32: Bool]) {
        self.elements = elements
    }

    /// Every switch is on: muted by the user, nothing for us to do.
    public var isFullyMuted: Bool { !elements.isEmpty && elements.values.allSatisfy { $0 } }
}

/// The one thing `OutputMuteController` needs from the audio system. Small
/// enough that a fake in a test is a handful of lines, which is the point:
/// the ordering rules are what break, not the CoreAudio calls.
public protocol OutputMuteControl: Sendable {
    /// Current default output device, or nil when there is none.
    func defaultOutputDevice() -> UInt32?
    /// Every mute switch the device has and whether it is on, or nil when it
    /// has none.
    func muteState(of device: UInt32) -> MuteState?
    /// Sets each element listed in `state` and leaves the rest alone. Tries
    /// every element before throwing the first failure, so a restore puts
    /// back as much as it can.
    func apply(_ state: MuteState, to device: UInt32) throws
}
