import AppKit
import Sparkle

// Sparkle's own window shows only from a click: a scheduled check's find is handed to
// Pladder (gentle reminders), because a window taking focus mid-dictation would get the paste.
@MainActor
final class SparkleUpdaterBackend: NSObject, UpdaterBackend {
    var onEvent: (UpdaterEvent) -> Void = { _ in }
    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private var canCheckObservation: NSKeyValueObservation?

    // Sparkle refuses to start without a public EdDSA key, and `swift run` has no Info.plist.
    static func make(bundle: Bundle = .main) -> SparkleUpdaterBackend? {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty
        else { return nil }
        return SparkleUpdaterBackend(bundle: bundle)
    }

    private init(bundle: Bundle) {
        super.init()
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        self.userDriver = userDriver
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }

    func start() throws {
        guard let updater else { return }
        try updater.start()
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.onEvent(.canCheckChanged(value)) }
        }
    }

    func checkForUpdates() {
        // An accessory app is never active, so the window would open behind the current app.
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
    }
}

extension SparkleUpdaterBackend: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        onEvent(.found(version: update.displayVersionString))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onEvent(.attended)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onEvent(.sessionFinished)
    }
}
