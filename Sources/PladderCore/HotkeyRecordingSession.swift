import Foundation

/// Which settings recorder is recording a new chord, if any. One at a time,
/// app-wide, and the live hotkey is suspended exactly while one is. Pure
/// value type: the recorders act on what it returns.
///
/// Three fields, push-to-talk, toggle and send, share one hotkey. Each used
/// to set the coordinator's suspension from its own recorder alone, so with
/// two recording, clicking one field while the other listened, the first to
/// finish brought the hotkey back while the second still recorded, and
/// pressing the old chord into it started a dictation. Now beginning one
/// ends the other, and only the recorder holding the session resumes the
/// hotkey, once.
public struct HotkeyRecordingSession<Recorder: Hashable & Sendable>: Sendable, Equatable {
    /// What `begin` asks of the caller.
    public struct Begin: Sendable, Equatable {
        /// The recorder that was recording and has to stop now. Its own end
        /// then changes nothing: the session has already moved on.
        public var displaced: Recorder?
        /// True when nothing was recording: suspend the hotkey. A hand-over
        /// from one recorder to another keeps it suspended throughout.
        public var suspends: Bool

        public init(displaced: Recorder? = nil, suspends: Bool) {
            self.displaced = displaced
            self.suspends = suspends
        }
    }

    /// The recorder recording now.
    public private(set) var recorder: Recorder?

    public init() {}

    /// True while a recorder records: the hotkey stays down.
    public var isSuspended: Bool { recorder != nil }

    /// `recorder` starts recording. Beginning again while it already holds
    /// the session changes nothing.
    public mutating func begin(_ recorder: Recorder) -> Begin {
        let previous = self.recorder
        self.recorder = recorder
        return Begin(displaced: previous == recorder ? nil : previous, suspends: previous == nil)
    }

    /// `recorder` stopped, however: committed, cancelled, displaced, its view
    /// gone. True when it held the session and the hotkey resumes; anyone
    /// else ending, or the holder ending twice, is a no-op.
    public mutating func end(_ recorder: Recorder) -> Bool {
        guard self.recorder == recorder else { return false }
        self.recorder = nil
        return true
    }
}
