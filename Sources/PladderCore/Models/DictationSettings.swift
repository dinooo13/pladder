import Foundation

/// The part of `Settings` the coordinator acts on, and nothing else.
///
/// The app derives it from `Settings` and hands the coordinator a new value
/// only when it differs, so a click on an appearance card or the sounds
/// toggle never reaches the state machine and never rebuilds the processors.
/// The overlay's choices that matter here arrive already decided: whether
/// the Live Transcript style is on, and how long the "press ⌘V" hint stays.
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
    /// The Live Transcript style asks the engine for the text so far while
    /// the key is held, in place of the warm pass.
    public var liveTranscript: Bool
    /// How long the "press ⌘V" hint stays on screen before returning to idle.
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

    /// The defaults `Settings(engineID:)` has.
    public init(engineID: EngineID) {
        self.init(Settings(engineID: engineID))
    }
}
