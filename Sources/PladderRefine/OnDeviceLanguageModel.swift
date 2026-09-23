import Foundation
import FoundationModels
import Synchronization

/// Why the model cannot be used right now, as a value; the app words it.
public enum OnDeviceModelAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// A reason this build does not know about yet.
    case unavailable
}

public enum OnDeviceModelError: Error, Sendable, Equatable {
    case unavailable(OnDeviceModelAvailability)
    case timedOut
    /// `String(describing:)` of what the framework threw, for the log.
    case generation(String)
}

/// One instruction set for Apple's on-device model: a session factory, a
/// plain and a guided call, a wall-clock budget, and the drain of a call that
/// ran past it. Value type; hold one per prompt.
///
/// What the earlier tidy pass measured, and how this honours it:
/// - A `respond` awaited from inside an actor ran on that actor's executor
///   and turned sub-second replies into multi-second timeouts, so the call
///   always runs in a detached task and the caller only awaits its value.
/// - The system model serialises requests, so a call abandoned at the
///   timeout blocks the next one. It is parked and the next call drains it
///   before it starts, within that call's own budget.
/// - Sessions carry a transcript: one session per exchange, then dropped,
///   so nothing leaks from one dictation into the next.
/// - Greedy sampling: the same prompt gives the same answer, so a harness
///   measures the prompt and not the dice.
public struct OnDeviceLanguageModel: Sendable {
    public let instructions: String
    /// Greedy: same transcript, same answer, so the CLI harness measures the
    /// prompt and not the dice. The macOS 27 SDK renamed the label to
    /// `samplingMode:` and deprecated `sampling:`; the macOS 26 SDK, which CI
    /// builds with, has only `sampling:`. Both run on macOS 26.
    #if compiler(>=6.4)
    public var options = GenerationOptions(samplingMode: .greedy)
    #else
    public var options = GenerationOptions(sampling: .greedy)
    #endif
    /// Wall-clock budget for one call. Past it the call is abandoned and
    /// `respond` throws `.timedOut`.
    public var timeout: Duration

    public init(instructions: String, timeout: Duration = .seconds(8)) {
        self.instructions = instructions
        self.timeout = timeout
    }

    /// `.permissiveContentTransformations`: the input is the user's own words
    /// to rewrite, which is the case those guardrails exist for.
    private static let model = SystemLanguageModel(
        useCase: .general, guardrails: .permissiveContentTransformations)

    /// Cheap; read where it is shown and before every call.
    public static var availability: OnDeviceModelAvailability {
        switch model.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .unavailable
        }
    }

    /// A session with these instructions, prewarmed. Sessions carry a
    /// transcript, so one is used for one exchange and dropped.
    public func makeSession() -> LanguageModelSession {
        let session = LanguageModelSession(model: Self.model, instructions: instructions)
        // Off any actor for the same reason the call is: work the framework
        // starts from an actor's executor runs slowly enough to matter.
        Task.detached(priority: .utility) { session.prewarm() }
        return session
    }

    /// A plain text reply to `prompt`.
    public func respond(to prompt: String, session: LanguageModelSession? = nil) async throws -> String {
        let session = try ready(session)
        let options = options
        return try await race {
            try await session.respond(to: prompt, options: options).content
        }
    }

    /// A reply filled into `Content`. Guided generation is what keeps a small
    /// model from answering the text instead of working on it.
    public func respond<Content: Generable & Sendable>(
        to prompt: String,
        generating type: Content.Type,
        session: LanguageModelSession? = nil
    ) async throws -> Content {
        let session = try ready(session)
        let options = options
        return try await race {
            try await session.respond(to: prompt, generating: type, options: options).content
        }
    }

    // MARK: Plumbing

    private func ready(_ session: LanguageModelSession?) throws -> LanguageModelSession {
        let availability = Self.availability
        guard availability == .available else { throw OnDeviceModelError.unavailable(availability) }
        return session ?? LanguageModelSession(model: Self.model, instructions: instructions)
    }

    /// Runs `work` against the wall clock and returns whichever finishes
    /// first.
    ///
    /// Not a task group: that waits for every child before returning, so a
    /// model call that ignores cancellation would still hold the paste. A
    /// one-shot `AsyncStream` lets the loser be abandoned. Both tasks are
    /// detached so neither inherits the caller's actor.
    ///
    /// The drain of an abandoned call runs inside the budget, not before it:
    /// a call that never comes back would otherwise hold every later paste
    /// with no limit at all.
    private func race<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let (stream, continuation) = AsyncStream<Attempt<Value>>.makeStream()
        let call = Task.detached(priority: .userInitiated) {
            await Self.drain()
            do {
                continuation.yield(.value(try await work()))
            } catch {
                continuation.yield(.failed(String(describing: error)))
            }
        }
        let timer = Task.detached { [timeout] in
            try? await Task.sleep(for: timeout)
            continuation.yield(.timedOut)
        }
        defer {
            call.cancel()
            timer.cancel()
            continuation.finish()
        }

        var results = stream.makeAsyncIterator()
        switch await results.next() ?? .timedOut {
        case .value(let value):
            return value
        case .failed(let description):
            throw OnDeviceModelError.generation(description)
        case .timedOut:
            Self.leftover.withLock { $0 = call }
            throw OnDeviceModelError.timedOut
        }
    }

    /// The most recent call that ran past its budget and was abandoned.
    /// Cancellation reaches the system model late or not at all, and the model
    /// serialises requests, so the next call would queue behind it and time
    /// out too. Static because the model is one shared resource, whichever
    /// prompt is talking to it.
    private static let leftover = Mutex<Task<Void, Never>?>(nil)

    /// Waits for an abandoned call, if any, to run its course.
    private static func drain() async {
        guard let pending = leftover.withLock({ $0 }) else { return }
        await pending.value
        leftover.withLock { if $0 == pending { $0 = nil } }
    }
}

/// A raced call's outcome. Not `Result<Value, any Error>`: `any Error` is not
/// `Sendable`, and the error is only ever described anyway.
private enum Attempt<Value: Sendable>: Sendable {
    case value(Value)
    case failed(String)
    case timedOut
}
