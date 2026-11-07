import Foundation
import Testing
@testable import Pladder

// Starts with automatic checks on, as Sparkle's defaults might from an earlier launch.
@MainActor
private final class FakeUpdaterBackend: UpdaterBackend {
    private(set) var log: [String] = []
    private var automatic = true
    var automaticallyChecksForUpdates: Bool {
        get { automatic }
        set { automatic = newValue; log.append("automatic \(newValue)") }
    }
    var canCheckForUpdates = true
    var onEvent: (UpdaterEvent) -> Void = { _ in }
    var startError: (any Error)?

    func start() throws {
        log.append("start")
        if let startError { throw startError }
    }

    func checkForUpdates() { log.append("check") }
}

private struct StartFailed: Error {}

@MainActor
@Suite struct UpdateControllerTests {
    @Test func settingsHandTheirChoiceToTheUpdaterBeforeItStarts() {
        let backend = FakeUpdaterBackend()
        let updates = UpdateController(backend: backend)
        updates.start(automaticChecks: false)
        #expect(backend.log == ["automatic false", "start"])
        #expect(updates.isAvailable)
        #expect(updates.canCheck)
    }

    @Test func aChoiceTheUpdaterAlreadyHoldsIsNotWrittenAgain() {
        let backend = FakeUpdaterBackend()
        let updates = UpdateController(backend: backend)
        updates.start(automaticChecks: true)
        updates.apply(automaticChecks: true)
        #expect(backend.log == ["start"])
        updates.apply(automaticChecks: false)
        #expect(backend.log == ["start", "automatic false"])
    }

    @Test func nothingIsAppliedOrCheckedBeforeTheStart() {
        let backend = FakeUpdaterBackend()
        let updates = UpdateController(backend: backend)
        updates.apply(automaticChecks: false)
        updates.checkForUpdates()
        #expect(backend.log.isEmpty)
    }

    @Test func aFailedStartHidesTheUpdater() {
        let backend = FakeUpdaterBackend()
        backend.startError = StartFailed()
        let updates = UpdateController(backend: backend)
        #expect(updates.isAvailable)
        updates.start(automaticChecks: false)
        #expect(!updates.isAvailable)
        updates.checkForUpdates()
        #expect(backend.log == ["automatic false", "start"])
    }

    @Test func withoutAnUpdaterNothingIsOffered() {
        let updates = UpdateController(backend: nil)
        updates.start(automaticChecks: true)
        updates.checkForUpdates()
        #expect(!updates.isAvailable)
        #expect(!updates.canCheck)
    }

    @Test func aScheduledFindWaitsInTheMenuUntilTheUserAttendsToIt() {
        let backend = FakeUpdaterBackend()
        let updates = UpdateController(backend: backend)
        updates.start(automaticChecks: true)
        backend.onEvent(.found(version: "0.3.0"))
        #expect(updates.waitingVersion == "0.3.0")
        updates.checkForUpdates()
        #expect(backend.log == ["start", "check"])
        backend.onEvent(.attended)
        #expect(updates.waitingVersion == nil)
    }

    @Test func aFinishedSessionTakesTheLineAway() {
        let backend = FakeUpdaterBackend()
        let updates = UpdateController(backend: backend)
        updates.start(automaticChecks: true)
        backend.onEvent(.found(version: "0.3.0"))
        backend.onEvent(.sessionFinished)
        #expect(updates.waitingVersion == nil)
    }

    @Test func theMenuItemFollowsWhetherTheUpdaterCanCheck() {
        let backend = FakeUpdaterBackend()
        let updates = UpdateController(backend: backend)
        updates.start(automaticChecks: false)
        backend.onEvent(.canCheckChanged(false))
        #expect(!updates.canCheck)
        backend.onEvent(.canCheckChanged(true))
        #expect(updates.canCheck)
    }
}
