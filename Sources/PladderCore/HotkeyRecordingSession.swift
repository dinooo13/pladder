import Foundation

// One recorder at a time, app-wide: beginning one displaces the other, and only the
// recorder holding the session resumes the hotkey.
public struct HotkeyRecordingSession<Recorder: Hashable & Sendable>: Sendable, Equatable {
    public struct Begin: Sendable, Equatable {
        public var displaced: Recorder?
        public var suspends: Bool

        public init(displaced: Recorder? = nil, suspends: Bool) {
            self.displaced = displaced
            self.suspends = suspends
        }
    }

    public private(set) var recorder: Recorder?

    public init() {}

    public var isSuspended: Bool { recorder != nil }

    public mutating func begin(_ recorder: Recorder) -> Begin {
        let previous = self.recorder
        self.recorder = recorder
        return Begin(displaced: previous == recorder ? nil : previous, suspends: previous == nil)
    }

    public mutating func end(_ recorder: Recorder) -> Bool {
        guard self.recorder == recorder else { return false }
        self.recorder = nil
        return true
    }
}
