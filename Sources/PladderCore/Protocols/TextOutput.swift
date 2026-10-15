import Foundation

public enum InsertResult: Sendable, Equatable {
    case pasted
    // No Return follows a copy, whatever `submit` said.
    case copied
}

public enum OutputError: Error, Equatable, Sendable {
    case eventCreationFailed
}

public protocol TextOutput: Sendable {
    // With `submit`, Return follows once the text has landed, after this returns:
    // it is not on the release-to-paste path.
    @discardableResult
    func insert(_ text: String, submit: Bool) async throws -> InsertResult

    // Called at key-down and again at release, beside the engine pass, to catch a
    // clipboard changed while speaking; a call with nothing changed is cheap.
    func prepare() async

    // Does now what would otherwise wait on a timer, the clipboard restore: called
    // when the app quits and a detached timer would die with it.
    func flush() async
}

extension TextOutput {
    public func prepare() async {}
    public func flush() async {}
}
