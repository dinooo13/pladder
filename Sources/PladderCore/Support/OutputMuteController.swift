import Foundation

// Everything here is ordering; the rules it keeps are in docs/ARCHITECTURE.md,
// "Muting the speakers".
public actor OutputMuteController: OutputMuter {
    private let control: any OutputMuteControl
    private let delay: Duration
    private let log: @Sendable (String) -> Void

    // A pending arm that wakes to find this changed belongs to a session already over.
    private var generation = 0
    private var latestSession: Int?
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

    var armedGeneration: Int { generation }

    public func recordingStarted(session: Int) async {
        if let latestSession, session <= latestSession { return }
        latestSession = session
        generation += 1
        let mine = generation
        try? await Task.sleep(for: delay)
        guard generation == mine else { return }
        guard restore == nil else {
            // An earlier session muted it and its end has not come; this session's end restores it.
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
            // A set that failed half way still muted some of it, and those are ours to put back.
            let after = control.muteState(of: device)?.elements ?? [:]
            let landed = ours.filter { after[$0.key] == true }
            if !landed.isEmpty { restore = (device, MuteState(landed)) }
        }
    }

    public func recordingEnded(session: Int) async {
        // An older session's end: a newer one is running and owns the mute.
        if let latestSession, session < latestSession { return }
        latestSession = session
        // Also disarms a mute that has not landed yet.
        generation += 1
        guard let restore else { return }
        self.restore = nil
        do {
            // The remembered device, not the current default: the user may have switched output
            // mid-recording, and the old device would stay muted.
            try control.apply(restore.state, to: restore.device)
            log("unmuted output device \(restore.device)")
        } catch {
            // Never thrown: a stuck mute is bad, but so is a failed dictation.
            log("could not unmute output device \(restore.device): \(error.localizedDescription)")
        }
    }
}
