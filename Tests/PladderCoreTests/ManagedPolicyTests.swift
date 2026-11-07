import Foundation
import Testing
@testable import PladderCore

@Suite struct ManagedPolicyTests {
    private static let ultra = EngineID("parakeet-ultra-incremental")
    private static let v3 = EngineID("parakeet-tdt-v3-incremental")
    private static let engines = [ultra, v3]

    private static func read(_ values: [ManagedPolicy.Key: Any]) -> (policy: ManagedPolicy, problems: [ManagedPolicy.Problem]) {
        ManagedPolicy.read({ values[$0] }, knownEngines: engines)
    }

    private static var user: Settings {
        var settings = Settings(engineID: ultra)
        settings.polishModel = .s1Mini
        return settings
    }

    @Test func noForcedValueIsNoPolicy() {
        let (policy, problems) = Self.read([:])
        #expect(policy == .none)
        #expect(policy.isEmpty)
        #expect(problems.isEmpty)
    }

    @Test func everyKeyIsRead() {
        let (policy, problems) = Self.read([
            .allowedEngines: [Self.v3.rawValue],
            .polishDictations: false,
            .allowedPolishModels: ["appleIntelligence"],
            .learnCorrections: true,
            .clipboardMode: true,
            .updateChecks: false,
        ])
        #expect(problems.isEmpty)
        #expect(policy == ManagedPolicy(
            allowedEngines: [Self.v3], allowedPolishModels: [.appleIntelligence],
            polishDictations: false, learnCorrections: true, updateChecks: false, clipboardMode: true))
        #expect(policy.managedKeys == ManagedPolicy.Key.allCases)
    }

    @Test func anUnknownEngineIsDroppedAndTheRestKept() {
        let (policy, problems) = Self.read([.allowedEngines: ["whisper", Self.v3.rawValue]])
        #expect(policy.allowedEngines == [Self.v3])
        #expect(problems == [.unknownValues(.allowedEngines, ["whisper"])])
    }

    @Test func aListWithNoKnownEngineIsIgnoredAsAWhole() {
        let (policy, problems) = Self.read([.allowedEngines: ["whisper"]])
        #expect(policy.allowedEngines == nil)
        #expect(problems == [.unknownValues(.allowedEngines, ["whisper"]), .noKnownValue(.allowedEngines)])
    }

    @Test func anEmptyListIsIgnored() {
        let (policy, problems) = Self.read([.allowedEngines: [String](), .allowedPolishModels: [String]()])
        #expect(policy == .none)
        #expect(problems == [.noKnownValue(.allowedEngines), .noKnownValue(.allowedPolishModels)])
    }

    @Test func anUnknownPolishModelIsDropped() {
        let (policy, problems) = Self.read([.allowedPolishModels: ["gpt", "s1Mini8Bit", "s1Mini8Bit"]])
        #expect(policy.allowedPolishModels == [.s1Mini8Bit])
        #expect(problems == [.unknownValues(.allowedPolishModels, ["gpt"])])
    }

    @Test func aValueOfTheWrongTypeIsIgnored() {
        let (policy, problems) = Self.read([
            .allowedEngines: Self.v3.rawValue,
            .polishDictations: "false",
            .learnCorrections: 0,
            .clipboardMode: 1,
        ])
        #expect(policy == .none)
        #expect(problems == [
            .wrongType(.allowedEngines), .wrongType(.polishDictations),
            .wrongType(.learnCorrections), .wrongType(.clipboardMode),
        ])
    }

    @Test func clipboardModeFalseIsNoPolicy() {
        #expect(Self.read([.clipboardMode: false]).policy == .none)
    }

    @Test func noPolicyLeavesTheSettingsAlone() {
        #expect(ManagedPolicy.none.apply(to: Self.user) == Self.user)
    }

    @Test func aStoredEngineOutsideTheListRunsTheFirstAllowed() {
        let policy = ManagedPolicy(allowedEngines: [Self.v3])
        #expect(policy.apply(to: Self.user).engineID == Self.v3)
        #expect(policy.pinsEngine)
    }

    @Test func aStoredEngineInsideTheListStays() {
        let policy = ManagedPolicy(allowedEngines: [Self.v3, Self.ultra])
        #expect(policy.apply(to: Self.user).engineID == Self.ultra)
        #expect(!policy.pinsEngine)
        #expect(policy.engines(from: Self.engines) == [Self.ultra, Self.v3])
    }

    @Test func polishIsForcedOnOrOff() {
        var user = Self.user
        user.polishDictations = true
        #expect(!ManagedPolicy(polishDictations: false).apply(to: user).polishDictations)
        user.polishDictations = false
        #expect(ManagedPolicy(polishDictations: true).apply(to: user).polishDictations)
    }

    @Test func aPinnedPolishModelReplacesTheStoredOne() {
        let policy = ManagedPolicy(allowedPolishModels: [.appleIntelligence])
        #expect(policy.apply(to: Self.user).polishModel == .appleIntelligence)
        #expect(policy.pinsPolishModel)
        #expect(policy.polishModels == [.appleIntelligence])
        #expect(ManagedPolicy.none.polishModels == PolishModel.allCases)
    }

    @Test func learnedCorrectionsAreForcedOnOrOff() {
        var user = Self.user
        #expect(!ManagedPolicy(learnCorrections: false).apply(to: user).learnCorrections)
        user.learnCorrections = false
        #expect(ManagedPolicy(learnCorrections: true).apply(to: user).learnCorrections)
    }

    @Test func updateChecksAreForcedOnOrOff() {
        var user = Self.user
        #expect(ManagedPolicy(updateChecks: true).apply(to: user).checksForUpdatesAutomatically)
        user.checksForUpdatesAutomatically = true
        let off = ManagedPolicy(updateChecks: false)
        #expect(!off.apply(to: user).checksForUpdatesAutomatically)
        #expect(!off.allowsUpdateChecks)
        #expect(ManagedPolicy(updateChecks: true).allowsUpdateChecks)
        #expect(ManagedPolicy.none.allowsUpdateChecks)
    }

    @Test func clipboardModeChangesNoSetting() {
        #expect(ManagedPolicy(clipboardMode: true).apply(to: Self.user) == Self.user)
    }

    @Test func anEditElsewhereKeepsTheUsersOwnManagedValues() {
        let policy = ManagedPolicy(
            allowedEngines: [Self.v3], allowedPolishModels: [.appleIntelligence],
            polishDictations: true, learnCorrections: false, updateChecks: true)
        var edited = policy.apply(to: Self.user)
        edited.playSounds = false
        var expected = Self.user
        expected.playSounds = false
        #expect(policy.userSettings(from: edited, stored: Self.user) == expected)
    }

    @Test func aChoiceAmongSeveralAllowedIsTheUsersOwn() {
        let policy = ManagedPolicy(allowedEngines: [Self.ultra, Self.v3])
        var edited = policy.apply(to: Self.user)
        edited.engineID = Self.v3
        #expect(policy.userSettings(from: edited, stored: Self.user).engineID == Self.v3)
    }

    @Test func withoutAPolicyAnEditIsTakenAsIs() {
        var edited = Self.user
        edited.engineID = Self.v3
        edited.learnCorrections = false
        #expect(ManagedPolicy.none.userSettings(from: edited, stored: Self.user) == edited)
    }
}
