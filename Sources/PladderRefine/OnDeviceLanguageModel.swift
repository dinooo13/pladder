import Foundation
import FoundationModels
import PladderCore
import Synchronization

public enum OnDeviceModelAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unavailable
}

public enum OnDeviceModelError: Error, Sendable, Equatable {
    case unavailable(OnDeviceModelAvailability)
    case timedOut
    case decodingFailure
    case unsupportedGuide
    case generation(String)
}

// Measured: a `respond` awaited inside an actor ran on its executor and turned
// sub-second replies into multi-second timeouts, so every call runs detached. Sessions
// carry a transcript, so one serves one exchange and is dropped.
public struct OnDeviceLanguageModel: Sendable {
    public let instructions: String
    // Greedy: the same transcript gives the same answer, so a harness measures the
    // prompt. The macOS 27 SDK renamed the label to `samplingMode:`; the macOS 26 SDK,
    // which CI builds with, has only `sampling:`.
    #if compiler(>=6.4)
    public var options = GenerationOptions(samplingMode: .greedy)
    #else
    public var options = GenerationOptions(sampling: .greedy)
    #endif
    public var timeout: Duration

    public init(instructions: String, timeout: Duration = .seconds(8)) {
        self.instructions = instructions
        self.timeout = timeout
    }

    // The input is the user's own words to rewrite, the case these guardrails exist for.
    private static let model = SystemLanguageModel(
        useCase: .general, guardrails: .permissiveContentTransformations)

    public static var availability: OnDeviceModelAvailability {
        switch model.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .unavailable
        }
    }

    public func makeSession() -> LanguageModelSession {
        let session = LanguageModelSession(model: Self.model, instructions: instructions)
        // Off any actor: work the framework starts from an actor's executor runs slowly
        // enough to matter.
        Task.detached(priority: .utility) { session.prewarm() }
        return session
    }

    // `deadline` replaces `timeout` for a caller whose budget covers several calls.
    public func respond(
        to prompt: String, session: LanguageModelSession? = nil, deadline: ContinuousClock.Instant? = nil
    ) async throws -> String {
        let session = try ready(session)
        let options = options
        return try await Self.race(until: deadline ?? .now + timeout) {
            try await session.respond(to: prompt, options: options).content
        }
    }

    public func respond<Content: Generable & Sendable>(
        to prompt: String,
        generating type: Content.Type,
        session: LanguageModelSession? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> Content {
        let session = try ready(session)
        let options = options
        return try await Self.race(until: deadline ?? .now + timeout) {
            try await session.respond(to: prompt, generating: type, options: options).content
        }
    }

    // MARK: Plumbing

    private func ready(_ session: LanguageModelSession?) throws -> LanguageModelSession {
        let availability = Self.availability
        guard availability == .available else { throw OnDeviceModelError.unavailable(availability) }
        return session ?? LanguageModelSession(model: Self.model, instructions: instructions)
    }

    // Draining an abandoned call happens inside the budget: one that never comes back
    // would otherwise hold every later paste. A deadline already past starts nothing.
    static func race<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard ContinuousClock.now < deadline else { throw OnDeviceModelError.timedOut }
        let (outcome, call) = await firstOf(until: deadline, priority: .userInitiated) {
            await Self.drain()
            do {
                return Result<Value, OnDeviceModelError>.success(try await work())
            } catch {
                return .failure(Self.modelError(from: error))
            }
        }
        guard let outcome else {
            Self.leftover.withLock { $0 = call }
            throw OnDeviceModelError.timedOut
        }
        return try outcome.get()
    }

    // By type, never by text: on macOS 27 the description can quote the model's input
    // or output, the user's words. The macOS 27 SDK moves these cases to new types, so
    // both are mapped.
    static func modelError(from error: any Error) -> OnDeviceModelError {
        if let error = error as? OnDeviceModelError { return error }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .decodingFailure: return .decodingFailure
            case .unsupportedGuide: return .unsupportedGuide
            default: break
            }
        }
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            if error is GeneratedContent.ParsingError { return .decodingFailure }
            if case .unsupportedGenerationGuide = error as? LanguageModelError { return .unsupportedGuide }
        }
        #endif
        return .generation(logName(of: error))
    }

    static func logName(of error: any Error) -> String {
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return label }
        return String(describing: type(of: error))
    }

    // Cancellation reaches the system model late or not at all, and it serialises
    // requests, so the next call drains this first. Static: the model is shared.
    private static let leftover = Mutex<Task<Void, Never>?>(nil)

    private static func drain() async {
        guard let pending = leftover.withLock({ $0 }) else { return }
        await pending.value
        leftover.withLock { if $0 == pending { $0 = nil } }
    }
}

