import Foundation

/// A streaming engine's one utterance in progress, and the handles that name
/// it.
///
/// Each `begin` mints a new handle and claims the slot, and only a call
/// naming the handle that holds it reaches the session. An engine is an
/// actor and reentrant across its awaits, so a cancelled recording's late
/// abandon, or a `begin` overtaken by another while it built its session,
/// would otherwise act on whichever utterance happened to be current.
public struct UtteranceSlot<Session> {
    public private(set) var current: Utterance?
    private var session: Session?
    private var begun = 0

    public init() {}

    /// Claims the slot for a new utterance. Returns its handle, and the
    /// session of the utterance it replaces, for the caller to cancel.
    public mutating func begin() -> (utterance: Utterance, replaced: Session?) {
        begun += 1
        let utterance = Utterance(id: begun)
        let replaced = session
        current = utterance
        session = nil
        return (utterance, replaced)
    }

    /// Hands `utterance` the session it began with. False when another
    /// `begin` or a `release` has claimed the slot since: the session belongs
    /// to nobody, and the caller cancels it.
    public mutating func install(_ session: Session, for utterance: Utterance) -> Bool {
        guard current == utterance else { return false }
        self.session = session
        return true
    }

    /// The session, if `utterance` holds the slot and has one.
    public func session(for utterance: Utterance) -> Session? {
        current == utterance ? session : nil
    }

    /// Ends `utterance` if it holds the slot, and returns its session; a
    /// stale handle changes nothing and gets nil. `wasCurrent` tells a stale
    /// handle from a current one still beginning, which has no session yet.
    @discardableResult
    public mutating func release(_ utterance: Utterance) -> (wasCurrent: Bool, session: Session?) {
        guard current == utterance else { return (false, nil) }
        let released = session
        current = nil
        session = nil
        return (true, released)
    }
}

extension UtteranceSlot: Sendable where Session: Sendable {}
