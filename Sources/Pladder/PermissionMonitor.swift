import AVFoundation
import Foundation
import Observation
import PladderSystem

// Polled because none of these notifies a change, and for the app's life, so a
// later revoke is picked up too. Secure Event Input is no grant but deafens the tap.
@MainActor
@Observable
final class PermissionMonitor {
    private(set) var accessibilityTrusted = Permissions.isAccessibilityTrusted
    private(set) var microphoneStatus = Permissions.microphoneStatus
    private(set) var secureInputEnabled = SecureInput.isEnabled

    @ObservationIgnored var onRefresh: () -> Void = {}

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var needsAccessibility: Bool { !accessibilityTrusted }
    var needsMicrophone: Bool { microphoneStatus != .authorized }
    var needsAnyPermission: Bool { needsAccessibility || needsMicrophone }

    func start() {
        startPolling()
        if !accessibilityTrusted { Permissions.requestAccessibility() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // Assigns only what changed, so views reading one grant are not redrawn every poll.
    func refresh() {
        let trusted = Permissions.isAccessibilityTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let microphone = Permissions.microphoneStatus
        if microphone != microphoneStatus { microphoneStatus = microphone }
        let secure = SecureInput.isEnabled
        if secure != secureInputEnabled { secureInputEnabled = secure }
        onRefresh()
    }

    func grantAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
        startPolling()
    }

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
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refresh()
            }
        }
    }
}
