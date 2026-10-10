import Foundation

// Only a call naming the handle that holds the slot reaches the session; see
// docs/ARCHITECTURE.md, "Engine".
public struct UtteranceSlot<Session> {
    public private(set) var current: Utterance?
    private var session: Session?
    private var begun = 0

    public init() {}

    // Returns the session of the utterance it replaces, for the caller to cancel.
    public mutating func begin() -> (utterance: Utterance, replaced: Session?) {
        begun += 1
        let utterance = Utterance(id: begun)
        let replaced = session
        current = utterance
        session = nil
        return (utterance, replaced)
    }

    // False when another `begin` or a `release` claimed the slot meanwhile: the session
    // belongs to nobody, and the caller cancels it.
    public mutating func install(_ session: Session, for utterance: Utterance) -> Bool {
        guard current == utterance else { return false }
        self.session = session
        return true
    }

    public func session(for utterance: Utterance) -> Session? {
        current == utterance ? session : nil
    }

    // `wasCurrent` tells a stale handle from a current one still beginning, which has
    // no session yet.
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
