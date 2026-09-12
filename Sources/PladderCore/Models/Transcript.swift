import Foundation

public struct Transcript: Sendable, Equatable {
    public var text: String
    /// BCP 47 language tag when the engine detects it, else nil.
    public var language: String?
    /// Duration of the audio that produced this transcript.
    public var audioDuration: TimeInterval
    /// Wall clock time the engine spent.
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

    /// Speed relative to realtime. 100 means one minute of audio in 0.6 s.
    public var realtimeFactor: Double {
        guard processingTime > 0 else { return 0 }
        return audioDuration / processingTime
    }
}
