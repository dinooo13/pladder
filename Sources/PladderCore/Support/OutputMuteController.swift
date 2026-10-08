import Foundation

/// Decides when the output device is muted and, more importantly, when it is
/// put back. Everything here is ordering: the CoreAudio calls themselves are
/// a read and a write in `OutputMuteControl`.
///
/// Four rules it exists to keep:
///
/// - A tap-and-release never toggles anything. The mute is armed at key-down
///   and lands `delay` later, so a mistaken press is invisible.
/// - A switch the user had already muted is never unmuted. The controller
///   reads every element before it mutes, changes only the ones that were
///   off, and later turns back off exactly those: a device the user muted
///   whole is left alone, one with a channel muted keeps that channel muted.
/// - The start and the end of a recording arrive on tasks nothing orders, so
///   the end can come first. Each names its session: an end disarms its
///   session whenever it comes, and a start whose session has already ended
///   does nothing, instead of muting with no end left to follow.
/// - Two overlapping sessions cannot unmute early, and the device that gets
///   unmuted is the one that was muted, not whatever is the default by then.
///   The session numbers and a generation counter cover the first, a
///   remembered device ID the second.
public actor OutputMuteController: OutputMuter {
    private let control: any OutputMuteControl
    private let delay: Duration
    private let log: @Sendable (String) -> Void

    /// Bumped by every start that arms and every end. A pending arm that
    /// wakes to find it changed belongs to a session that is already over.
    private var generation = 0
    /// The newest session any call has named. A start for it or an older one
    /// is late: its session has ended, or a newer one has begun.
    private var latestSession: Int?
    /// What this controller muted: the device, and the elements it turned on
    /// with the value each had before, which is what the end writes back.
    /// Nil means there is nothing to restore — either nothing was muted, or
    /// the user had muted all of it.
    private var restore: (device: UInt32, state: MuteState)?

    public init(
        control: any OutputMuteControl,
        delay: Duration = .milliseconds(200),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.control = control
        self.delay = delay
        self.log = log
    }

    /// How many arming starts and ends the controller has seen. Internal, for
    /// tests that fire `recordingStarted(session:)` without awaiting it and
    /// need to know the arm has been taken before they end the session; the
    /// ordering rules are exactly what would otherwise be raced.
    var armedGeneration: Int { generation }

    public func recordingStarted(session: Int) async {
        if let latestSession, session <= latestSession { return }
        latestSession = session
        generation += 1
        let mine = generation
        try? await Task.sleep(for: delay)
        // Released, cancelled, or superseded while we waited.
        guard generation == mine else { return }
        guard restore == nil else {
            // An earlier session muted it and its end has not come; this
            // session's end restores it now.
            log("output still muted from the previous recording")
            return
        }
        guard let device = control.defaultOutputDevice() else {
            log("no default output device, nothing to mute")
            return
        }
        guard let before = control.muteState(of: device), !before.elements.isEmpty else {
            log("output device \(device) has no mute control, leaving it")
            return
        }
        let ours = before.elements.filter { !$0.value }
        guard !ours.isEmpty else {
            // Remember nothing, so `recordingEnded` cannot undo the user.
            log("output device \(device) already muted by the user, leaving it")
            return
        }
        do {
            try control.apply(MuteState(ours.mapValues { _ in true }), to: device)
            restore = (device, MuteState(ours))
            log("muted output device \(device)")
        } catch {
            log("could not mute output device \(device): \(error.localizedDescription)")
            // A set that failed half way still muted some of it, and those
            // are ours to put back.
            let after = control.muteState(of: device)?.elements ?? [:]
            let landed = ours.filter { after[$0.key] == true }
            if !landed.isEmpty { restore = (device, MuteState(landed)) }
        }
    }

    public func recordingEnded(session: Int) async {
        // An older session's end: a newer one is running and owns the mute.
        if let latestSession, session < latestSession { return }
        latestSession = session
        // Disarms a mute that has not landed yet, as well as ending the one
        // that has.
        generation += 1
        guard let restore else { return }
        self.restore = nil
        do {
            // The remembered device, not the current default: the user may
            // have switched output mid-recording, and unmuting the new one
            // would leave the old stuck and touch a device we never muted.
            try control.apply(restore.state, to: restore.device)
            log("unmuted output device \(restore.device)")
        } catch {
            // Never thrown on: a stuck mute is bad, but so is a failed
            // dictation, and the log line is how this gets diagnosed.
            log("could not unmute output device \(restore.device): \(error.localizedDescription)")
        }
    }

    /// Transitional: the next session, for a caller that does not number them.
    public func recordingStarted() async {
        await recordingStarted(session: (latestSession ?? 0) + 1)
    }

    /// Transitional: ends the newest session.
    public func recordingEnded() async {
        await recordingEnded(session: latestSession ?? 0)
    }
}
