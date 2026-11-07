import AVFoundation
import Foundation
import Observation
import PladderSystem

// Polled because none of these notifies a change, and for the app's life, so a
// later revoke is picked up too. Secure Event Input is no grant but deafens the tap.
@MainActor
@Observable
final class PermissionMonitor {
    // The grant in effect: never in Clipboard mode, where the app does without it on purpose.
    private(set) var accessibilityTrusted: Bool
    private(set) var microphoneStatus = Permissions.microphoneStatus
    private(set) var secureInputEnabled = SecureInput.isEnabled
    // Set by a managed policy. The grant is then never asked for, nor even checked.
    var clipboardMode: Bool {
        didSet {
            guard clipboardMode != oldValue else { return }
            refreshAccessibility()
        }
    }

    @ObservationIgnored var onRefresh: () -> Void = {}

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private static let pollInterval: Duration = .seconds(2)

    init(clipboardMode: Bool = false) {
        self.clipboardMode = clipboardMode
        accessibilityTrusted = !clipboardMode && Permissions.isAccessibilityTrusted
    }

    var needsAccessibility: Bool { !clipboardMode && !accessibilityTrusted }
    var needsMicrophone: Bool { microphoneStatus != .authorized }
    var needsAnyPermission: Bool { needsAccessibility || needsMicrophone }

    // No system prompt here: the first launch opens Settings, where the grant is asked for
    // from its own button, with a sentence on what it is for.
    func start() {
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // Assigns only what changed, so views reading one grant are not redrawn every poll.
    func refresh() {
        refreshAccessibility()
        let microphone = Permissions.microphoneStatus
        if microphone != microphoneStatus { microphoneStatus = microphone }
        let secure = SecureInput.isEnabled
        if secure != secureInputEnabled { secureInputEnabled = secure }
        onRefresh()
    }

    private func refreshAccessibility() {
        let trusted = !clipboardMode && Permissions.isAccessibilityTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }

    // The system alert first, which has its own button to System Settings; opening the pane
    // as well put two system windows up at once. Once the alert has been seen this launch,
    // the pane directly, since macOS shows the alert only for an app not yet in the list.
    func grantAccessibility() {
        guard !clipboardMode else { return }
        if promptedForAccessibility {
            Permissions.openAccessibilitySettings()
        } else {
            promptedForAccessibility = true
            Permissions.requestAccessibility()
        }
        startPolling()
    }

    private(set) var promptedForAccessibility = false

    func grantMicrophone() {
        Task { [weak self] in
            if Permissions.microphoneStatus == .notDetermined {
                _ = await Permissions.requestMicrophone()
            } else {
                Permissions.openMicrophoneSettings()
            }
            self?.startPolling()
        }
    }

    // Restarts the cadence, so a grant just given shows without waiting out the timer.
    private func startPolling() {
        refresh()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                self.refresh()
            }
        }
    }
}
