import Foundation

public struct Transcript: Sendable, Equatable {
    public var text: String
    // BCP 47, when the engine detects it.
    public var language: String?
    public var audioDuration: TimeInterval
    public var processingTime: TimeInterval
    public var engineID: EngineID

    public init(
        text: String,
        language: String? = nil,
        audioDuration: TimeInterval,
        processingTime: TimeInterval,
        engineID: EngineID
    ) {
        self.text = text
        self.language = language
        self.audioDuration = audioDuration
        self.processingTime = processingTime
        self.engineID = engineID
    }

    public var realtimeFactor: Double {
        guard processingTime > 0 else { return 0 }
        return audioDuration / processingTime
    }
}
