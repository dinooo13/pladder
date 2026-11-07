import Foundation
import Observation
import os

enum UpdaterEvent: Equatable {
    // A scheduled check found this version and left showing it to Pladder.
    case found(version: String)
    // The user opened Sparkle's window for it, or chose to install, skip or dismiss it.
    case attended
    case sessionFinished
    case canCheckChanged(Bool)
}

@MainActor
protocol UpdaterBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    var onEvent: (UpdaterEvent) -> Void { get set }
    func start() throws
    // Opens Sparkle's window: a new check, or the update a scheduled check already found.
    func checkForUpdates()
}

// See docs/ARCHITECTURE.md, "Updates".
@MainActor
@Observable
final class UpdateController {
    // False under `swift run`, in a build without a feed and a key, and after a failed start:
    // then the menu item and the toggle are not shown.
    private(set) var isAvailable: Bool
    private(set) var canCheck = false
    // Set only by a scheduled check; the menu shows it as one line until the user acts on it.
    private(set) var waitingVersion: String?

    @ObservationIgnored private let backend: (any UpdaterBackend)?
    @ObservationIgnored private var started = false
    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "updates")

    init(backend: (any UpdaterBackend)? = SparkleUpdaterBackend.make()) {
        self.backend = backend
        isAvailable = backend != nil
    }

    // Before the start, so a copy whose settings say off never starts a scheduled check.
    func start(automaticChecks: Bool) {
        guard let backend, !started else { return }
        backend.onEvent = { [weak self] in self?.handle($0) }
        if backend.automaticallyChecksForUpdates != automaticChecks {
            backend.automaticallyChecksForUpdates = automaticChecks
        }
        do {
            try backend.start()
            started = true
            canCheck = backend.canCheckForUpdates
        } catch {
            isAvailable = false
            Self.log.error("updater did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func apply(automaticChecks: Bool) {
        guard started, let backend, backend.automaticallyChecksForUpdates != automaticChecks else { return }
        backend.automaticallyChecksForUpdates = automaticChecks
    }

    func checkForUpdates() {
        guard started else { return }
        backend?.checkForUpdates()
    }

    private func handle(_ event: UpdaterEvent) {
        switch event {
        case .found(let version): waitingVersion = version
        case .attended, .sessionFinished: waitingVersion = nil
        case .canCheckChanged(let value): canCheck = value
        }
    }
}
