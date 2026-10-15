import Foundation

// Recorders are told apart by tokens, never addresses: a recorder freed mid-recording would hand
// its address to the next one. Held weakly, so a holder that is gone is taken over by the next
// claim rather than leaving the hotkey down.
@MainActor
public final class HotkeyRecordingSlot<Holder: AnyObject> {
    public struct Token: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    private var session = HotkeyRecordingSession<Token>()
    private weak var holder: Holder?
    // The closure that suspended the hotkey: it is the one that resumes it.
    private var setHotkeySuspended: ((Bool) -> Void)?
    private var issued: UInt64 = 0
    private let cancel: (Holder) -> Void

    public init(cancel: @escaping (Holder) -> Void) {
        self.cancel = cancel
    }

    public func makeToken() -> Token {
        issued += 1
        return Token(value: issued)
    }

    public var isSuspended: Bool { session.isSuspended }

    public func claim(_ token: Token, by holder: Holder, setHotkeySuspended: @escaping (Bool) -> Void) {
        if self.holder == nil, let stale = session.recorder, stale != token {
            // Freed without ending: nothing to cancel, and the hotkey stays down for this one.
            _ = session.end(stale)
        }
        let begin = session.begin(token)
        let displaced = self.holder
        self.holder = holder
        self.setHotkeySuspended = setHotkeySuspended
        // After the session has moved on, so the displaced recorder's own release is a no-op.
        if begin.displaced != nil, let displaced { cancel(displaced) }
        if begin.suspends { setHotkeySuspended(true) }
    }

    public func release(_ token: Token) {
        guard session.end(token) else { return }
        holder = nil
        let resume = setHotkeySuspended
        setHotkeySuspended = nil
        resume?(false)
    }
}
