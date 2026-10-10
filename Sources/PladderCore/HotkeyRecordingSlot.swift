import Foundation

/// The app's one `HotkeyRecordingSession` and the recorder holding it. The
/// session decides; the slot keeps the recorder to cancel and the closure
/// that suspended the hotkey, which is the one that resumes it.
///
/// Recorders are told apart by a token the slot hands out, never by their
/// address: a recorder freed while it held the session would leave its
/// address to the next one, whose `claim` then looked like the same recorder
/// beginning again and suspended nothing. The holder is held weakly, so one
/// freed without ending its recording shows as gone: the next `claim` takes
/// the session over from it rather than leaving the hotkey down for good.
@MainActor
public final class HotkeyRecordingSlot<Holder: AnyObject> {
    public struct Token: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    private var session = HotkeyRecordingSession<Token>()
    private weak var holder: Holder?
    private var setHotkeySuspended: ((Bool) -> Void)?
    private var issued: UInt64 = 0
    private let cancel: (Holder) -> Void

    /// `cancel` ends a recorder's recording when another one begins.
    public init(cancel: @escaping (Holder) -> Void) {
        self.cancel = cancel
    }

    /// A token for one recorder, for its whole life.
    public func makeToken() -> Token {
        issued += 1
        return Token(value: issued)
    }

    /// True while a recorder records: the hotkey stays down.
    public var isSuspended: Bool { session.isSuspended }

    /// `holder` starts recording under `token`. A recorder still recording
    /// is cancelled, and the hotkey is suspended unless it already was.
    public func claim(_ token: Token, by holder: Holder, setHotkeySuspended: @escaping (Bool) -> Void) {
        if self.holder == nil, let stale = session.recorder, stale != token {
            // Freed without ending: nothing to cancel. The hotkey is still
            // down, and this recorder's `begin` keeps it so.
            _ = session.end(stale)
        }
        let begin = session.begin(token)
        let displaced = self.holder
        self.holder = holder
        self.setHotkeySuspended = setHotkeySuspended
        // After the session has moved on, so the displaced recorder's own
        // `release` is a no-op and the hotkey stays down.
        if begin.displaced != nil, let displaced { cancel(displaced) }
        if begin.suspends { setHotkeySuspended(true) }
    }

    /// The recorder under `token` stopped, however: committed, cancelled,
    /// displaced or freed. The hotkey resumes if it held the session.
    public func release(_ token: Token) {
        guard session.end(token) else { return }
        holder = nil
        let resume = setHotkeySuspended
        setHotkeySuspended = nil
        resume?(false)
    }
}
