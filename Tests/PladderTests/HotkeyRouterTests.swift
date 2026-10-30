import Foundation
import PladderCore
import PladderSystem
import PladderTestSupport
import Testing
@testable import Pladder

@MainActor
@Suite(.timeLimit(.minutes(1))) struct HotkeyRouterTests {
    private struct Rig {
        let router: HotkeyRouter
        let coordinator: DictationCoordinator
        let tap: FakeHotkey
        let carbon: FakeHotkey
    }

    private func started(trusted: Bool, hotkey: Hotkey) -> Rig {
        let tap = FakeHotkey()
        let carbon = FakeHotkey()
        let router = HotkeyRouter(accessibilityTrusted: trusted, hotkey: hotkey, tap: tap, carbon: carbon)
        var settings = DictationSettings(engineID: EchoEngine.engineID)
        settings.hotkey = hotkey
        let coordinator = DictationCoordinator(
            settings: settings,
            registry: EngineRegistry([.init(id: EchoEngine.engineID, displayName: "Echo", detail: "") {
                EchoEngine(delay: .zero)
            }]),
            capture: FakeCapture(),
            output: FakeOutput(),
            hotkeyMonitor: router.initialMonitor,
            makePipeline: { _ in ProcessorPipeline([]) })
        router.attach(coordinator)
        coordinator.start()
        return Rig(router: router, coordinator: coordinator, tap: tap, carbon: carbon)
    }

    @Test func withAccessibilityTheCoordinatorListensOnTheTap() {
        let rig = started(trusted: true, hotkey: .optionSpace)
        #expect(rig.tap.startCount == 1)
        #expect(rig.carbon.startCount == 0)
    }

    @Test func withoutAccessibilityTheCoordinatorListensOnCarbon() {
        let rig = started(trusted: false, hotkey: .optionSpace)
        #expect(rig.carbon.startCount == 1)
        #expect(rig.tap.startCount == 0)
    }

    @Test func theFirstPollWithoutAccessibilityRestartsCarbonWithTheStandIn() {
        let rig = started(trusted: false, hotkey: .rightCommand)
        #expect(rig.carbon.lastHotkey == .rightCommand)
        rig.router.update(accessibilityTrusted: false, secureInputEnabled: false)
        #expect(rig.carbon.lastHotkey == .optionSpace)
        #expect(rig.tap.startCount == 0)
    }

    @Test func aRevokedGrantMovesTheCoordinatorToCarbonOnceWithTheStandIn() {
        let rig = started(trusted: true, hotkey: .rightCommand)
        rig.router.update(accessibilityTrusted: true, secureInputEnabled: false)
        let tapStops = rig.tap.stopCount
        rig.router.update(accessibilityTrusted: false, secureInputEnabled: false)
        #expect(rig.tap.stopCount > tapStops)
        #expect(rig.carbon.startedHotkeys == [.optionSpace])
        #expect(rig.router.standInHotkey == .optionSpace)
        #expect(rig.router.hotkeyNeedsRegularKey)
    }

    @Test func aGrantGivenBackMovesTheCoordinatorToTheTapWithTheStoredChord() {
        let rig = started(trusted: false, hotkey: .rightCommand)
        rig.router.update(accessibilityTrusted: false, secureInputEnabled: false)
        let carbonStops = rig.carbon.stopCount
        rig.router.update(accessibilityTrusted: true, secureInputEnabled: false)
        #expect(rig.carbon.stopCount > carbonStops)
        #expect(rig.tap.startedHotkeys == [.rightCommand])
        #expect(rig.router.standInHotkey == nil)
    }

    @Test func aPollWithNothingNewLeavesTheMonitorRunning() {
        let rig = started(trusted: true, hotkey: .optionSpace)
        rig.router.update(accessibilityTrusted: true, secureInputEnabled: false)
        rig.router.update(accessibilityTrusted: true, secureInputEnabled: false)
        #expect(rig.tap.startCount == 1)
        #expect(rig.carbon.startCount == 0)
    }

    @Test func aChordIsNamedAsItsMonitorSeesIt() {
        let tap = started(trusted: true, hotkey: .rightCommand).router
        let carbon = started(trusted: false, hotkey: .optionSpace).router
        #expect(Hotkey.rightCommand.displayName != Hotkey.rightCommand.sideAgnosticDisplayName)
        #expect(tap.displayName(of: .rightCommand) == Hotkey.rightCommand.displayName)
        #expect(carbon.displayName(of: .rightCommand) == Hotkey.rightCommand.sideAgnosticDisplayName)
    }
}
