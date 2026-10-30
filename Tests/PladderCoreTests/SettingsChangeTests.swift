import Foundation
import Testing
@testable import PladderCore

@Suite struct SettingsChangeTests {
    private let old = Settings(engineID: EngineID("echo"))

    private func change(_ edit: (inout Settings) -> Void) -> SettingsChange {
        var new = old
        edit(&new)
        return SettingsChange(from: old, to: new)
    }

    @Test func eachReactionFollowsOnlyItsOwnKeys() {
        #expect(change { $0.hotkey = .rightCommand } == SettingsChange(hotkey: true))
        #expect(change { $0.appearance = .dark } == SettingsChange(appearance: true))
        #expect(change { $0.overlayStyle = .minimal } == SettingsChange(overlayStyle: true))
        #expect(change { $0.overlayGlass.toggle() } == SettingsChange(overlayStyle: true))
        #expect(change { $0.overlayAnimationSpeed = .instant } == SettingsChange(overlaySpeed: true))
        #expect(change { $0.polishModel = .s1Mini8Bit } == SettingsChange(polish: true))
        #expect(change { $0.polishDictations.toggle() } == SettingsChange(polish: true))
    }

    @Test func keysOnlyTheCoordinatorReadsRedoNothingInTheApp() {
        #expect(change { $0.dictionary = [DictionaryEntry(from: "a", to: "b")] } == SettingsChange())
        #expect(change { $0.engineID = EngineID("other") } == SettingsChange())
        #expect(change { $0.toggleHotkey = .rightOption } == SettingsChange())
        #expect(change { $0.submitKey = .rightOption } == SettingsChange())
        #expect(change { $0.playSounds.toggle() } == SettingsChange())
    }

    @Test func editsTogetherRedoEachOfTheirReactions() {
        let both = change {
            $0.appearance = .light
            $0.polishModel = .s1Mini
        }
        #expect(both == SettingsChange(appearance: true, polish: true))
    }
}
