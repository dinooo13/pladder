import Foundation

public struct DictationSettings: Sendable, Equatable {
    public var engineID: EngineID
    public var hotkey: Hotkey
    public var submitKey: Hotkey
    public var toggleHotkey: Hotkey
    public var polishDictations: Bool
    public var disabledProcessors: Set<String>
    public var dictionary: [DictionaryEntry]
    public var appendTrailingSpace: Bool
    public var muteOutputWhileDictating: Bool
    public var liveTranscript: Bool
    public var copiedHoldDuration: Duration

    public init(_ settings: Settings) {
        engineID = settings.engineID
        hotkey = settings.hotkey
        submitKey = settings.submitKey
        toggleHotkey = settings.toggleHotkey
        polishDictations = settings.polishDictations
        disabledProcessors = settings.disabledProcessors
        dictionary = settings.dictionary
        appendTrailingSpace = settings.appendTrailingSpace
        muteOutputWhileDictating = settings.muteOutputWhileDictating
        liveTranscript = settings.overlayStyle == .liveTranscript
        copiedHoldDuration = settings.overlayAnimationSpeed.copiedHoldDuration
    }

    public init(engineID: EngineID) {
        self.init(Settings(engineID: engineID))
    }
}
