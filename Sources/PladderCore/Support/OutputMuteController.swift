import Foundation

/// Decides when the output device is muted and, more importantly, when it is
/// put back. Everything here is ordering: the CoreAudio calls themselves are
/// three lines in `OutputMuteControl`.
///
/// Three rules it exists to keep:
///
/// - A tap-and-release never toggles anything. The mute is armed at key-down
///   and lands `delay` later, so a mistaken press is invisible.
/// - A device the user had already muted is never unmuted. The controller
///   remembers only what it muted itself.
/// - Two overlapping sessions cannot unmute early, and the device that gets
///   unmuted is the one that was muted, not whatever is the default by then.
///   A generation counter covers the first, a remembered device ID the second.
public actor OutputMuteController: OutputMuter {
    private let control: any OutputMuteControl
    private let delay: Duration
    private let log: @Sendable (String) -> Void

    /// Bumped by every start and every end. A pending arm that wakes to find
    /// it changed belongs to a session that is already over.
    private var generation = 0
    /// The device this controller muted, if any. Nil means there is nothing
    /// to restore — either nothing was muted, or the user had muted it.
    private var mutedDevice: UInt32?

    public init(
        control: any OutputMuteControl,
        delay: Duration = .milliseconds(200),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.control = control
        self.delay = delay
        self.log = log
    }

    /// How many start/end calls the controller has seen. Internal, for tests
    /// that fire `recordingStarted()` without awaiting it and need to know
    /// the arm has been taken before they end the session; the ordering rules
    /// are exactly what would otherwise be raced.
    var armedGeneration: Int { generation }

    public func recordingStarted() async {
        generation += 1
        let mine = generation
        try? await Task.sleep(for: delay)
        // Released, cancelled, or superseded while we waited.
        guard generation == mine else { return }
        guard let device = control.defaultOutputDevice() else {
            log("no default output device, nothing to mute")
            return
        }
        guard let muted = control.isMuted(device) else {
            log("output device \(device) has no mute control, leaving it")
            return
        }
        guard !muted else {
            // Remember nothing, so `recordingEnded` cannot undo the user.
            log("output device \(device) already muted by the user, leaving it")
            return
        }
        do {
            try control.setMuted(true, on: device)
            mutedDevice = device
            log("muted output device \(device)")
        } catch {
            log("could not mute output device \(device): \(error.localizedDescription)")
        }
    }

    public func recordingEnded() async {
        // Disarms a mute that has not landed yet, as well as ending the one
        // that has.
        generation += 1
        guard let device = mutedDevice else { return }
        mutedDevice = nil
        do {
            // The remembered device, not the current default: the user may
            // have switched output mid-recording, and unmuting the new one
            // would leave the old stuck and touch a device we never muted.
            try control.setMuted(false, on: device)
            log("unmuted output device \(device)")
        } catch {
            // Never thrown on: a stuck mute is bad, but so is a failed
            // dictation, and the log line is how this gets diagnosed.
            log("could not unmute output device \(device): \(error.localizedDescription)")
        }
    }
}
