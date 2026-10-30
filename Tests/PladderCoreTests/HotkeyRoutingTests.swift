import Foundation
import PladderTestSupport
import Testing
@testable import PladderCore

@Suite struct HotkeyRoutingTests {
    private let t0 = ContinuousClock.now

    private func observed(trusted: Bool, hotkey: Hotkey) -> HotkeyRouting {
        var routing = HotkeyRouting(accessibilityTrusted: trusted, hotkey: hotkey)
        _ = routing.observe(accessibilityTrusted: trusted, secureInputEnabled: false, at: t0)
        return routing
    }

    @Test func itStartsOnTheMonitorTheGrantCallsFor() {
        #expect(HotkeyRouting(accessibilityTrusted: true, hotkey: .rightCommand).source == .tap)
        #expect(HotkeyRouting(accessibilityTrusted: false, hotkey: .rightCommand).source == .carbon)
    }

    @Test func theFirstObservationAppliesTheStandInWithoutAFlip() {
        var routing = HotkeyRouting(accessibilityTrusted: false, hotkey: .rightCommand)
        let change = routing.observe(accessibilityTrusted: false, secureInputEnabled: false, at: t0)
        #expect(change == HotkeyRouting.Change(source: nil, standInHotkey: .optionSpace))
    }

    @Test func theFirstObservationWithAccessibilityAppliesNoStandIn() {
        var routing = HotkeyRouting(accessibilityTrusted: true, hotkey: .rightCommand)
        let change = routing.observe(accessibilityTrusted: true, secureInputEnabled: false, at: t0)
        #expect(change == HotkeyRouting.Change(source: nil, standInHotkey: nil))
    }

    @Test func aPollWithNothingChangedYieldsNothing() {
        var routing = observed(trusted: false, hotkey: .rightCommand)
        #expect(routing.observe(accessibilityTrusted: false, secureInputEnabled: false, at: t0 + .seconds(2)) == nil)
        #expect(routing.observe(accessibilityTrusted: false, secureInputEnabled: false, at: t0 + .seconds(4)) == nil)
    }

    @Test func aGrantFlipYieldsOneChangeWithTheNewSourceAndTheNewStandIn() {
        var routing = observed(trusted: true, hotkey: .rightCommand)
        let lost = routing.observe(accessibilityTrusted: false, secureInputEnabled: false, at: t0 + .seconds(2))
        #expect(lost == HotkeyRouting.Change(source: .carbon, standInHotkey: .optionSpace))
        #expect(routing.observe(accessibilityTrusted: false, secureInputEnabled: false, at: t0 + .seconds(4)) == nil)
        let granted = routing.observe(accessibilityTrusted: true, secureInputEnabled: false, at: t0 + .seconds(6))
        #expect(granted == HotkeyRouting.Change(source: .tap, standInHotkey: nil))
        #expect(routing.observe(accessibilityTrusted: true, secureInputEnabled: false, at: t0 + .seconds(8)) == nil)
    }

    @Test func sustainedSecureInputMovesARegistrableChordToCarbonAfterThreeSeconds() {
        var routing = observed(trusted: true, hotkey: .optionSpace)
        #expect(routing.observe(accessibilityTrusted: true, secureInputEnabled: true, at: t0) == nil)
        #expect(routing.observe(accessibilityTrusted: true, secureInputEnabled: true, at: t0 + .seconds(2)) == nil)
        let sustained = routing.observe(accessibilityTrusted: true, secureInputEnabled: true, at: t0 + .seconds(4))
        #expect(sustained == HotkeyRouting.Change(source: .carbon, standInHotkey: nil))
        #expect(routing.source == .carbon)
    }

    @Test func theTapComesBackOnTheFirstPollWithoutSecureInput() {
        var routing = observed(trusted: true, hotkey: .optionSpace)
        for seconds in [0, 2, 4] {
            _ = routing.observe(accessibilityTrusted: true, secureInputEnabled: true, at: t0 + .seconds(seconds))
        }
        let cleared = routing.observe(accessibilityTrusted: true, secureInputEnabled: false, at: t0 + .seconds(6))
        #expect(cleared == HotkeyRouting.Change(source: .tap, standInHotkey: nil))
    }

    @Test func aModifierOnlyChordStaysOnTheTapUnderSecureInput() {
        var routing = observed(trusted: true, hotkey: .rightCommand)
        for seconds in [0, 2, 4, 6] {
            #expect(routing.observe(accessibilityTrusted: true, secureInputEnabled: true, at: t0 + .seconds(seconds)) == nil)
        }
        #expect(routing.source == .tap)
    }

    @Test func aChordChangeUsesTheLastSecureInputReading() {
        var routing = observed(trusted: true, hotkey: .optionSpace)
        for seconds in [0, 2, 4] {
            _ = routing.observe(accessibilityTrusted: true, secureInputEnabled: true, at: t0 + .seconds(seconds))
        }
        #expect(routing.hotkeyChanged(to: .rightCommand) == .tap)
        #expect(routing.hotkeyChanged(to: .optionSpace) == .carbon)
    }

    @Test func aChordChangeBeforeSecureInputIsSustainedStaysOnTheTap() {
        var routing = observed(trusted: true, hotkey: .rightCommand)
        _ = routing.observe(accessibilityTrusted: true, secureInputEnabled: true, at: t0)
        #expect(routing.hotkeyChanged(to: .optionSpace) == nil)
        #expect(routing.source == .tap)
    }

    @Test func theSameChordAgainIsNoChange() {
        var routing = observed(trusted: true, hotkey: .optionSpace)
        #expect(routing.hotkeyChanged(to: .optionSpace) == nil)
    }

    @Test func aChordChangeWithoutAccessibilityChangesTheStandInButNotTheSource() {
        var routing = observed(trusted: false, hotkey: .optionSpace)
        #expect(routing.standInHotkey == nil)
        #expect(routing.hotkeyChanged(to: .rightCommand) == nil)
        #expect(routing.standInHotkey == .optionSpace)
        #expect(routing.source == .carbon)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct HotkeyRoutingCoordinatorTests {
    @Test func aGrantFlipAppliedInOneUpdateStartsTheNewMonitorOnceWithTheStandIn() async {
        let tap = FakeHotkey()
        let carbon = FakeHotkey()
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.hotkey = .rightCommand
        let (c, _, _) = makeCoordinator(settings: settings, hotkeyMonitor: tap)
        var routing = HotkeyRouting(accessibilityTrusted: true, hotkey: .rightCommand)
        let first = routing.observe(accessibilityTrusted: true, secureInputEnabled: false)
        c.update(c.settings, standInHotkey: first?.standInHotkey, monitor: nil)
        await c.startIdle()
        let change = routing.observe(accessibilityTrusted: false, secureInputEnabled: false)
        let monitor = change?.source.map { $0 == .tap ? tap : carbon }
        c.update(c.settings, standInHotkey: change?.standInHotkey, monitor: monitor)
        #expect(tap.startedHotkeys == [.rightCommand])
        #expect(carbon.startedHotkeys == [.optionSpace])
    }
}
