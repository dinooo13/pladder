import AVFoundation
import Foundation
import Observation
import PladderSystem

/// Mirrors the grants Pladder depends on, polled because neither API offers
/// a change notification: Accessibility, the microphone, and Secure Event
/// Input, which is not a grant but turns the event tap deaf in the same way.
///
/// The poll runs every two seconds for the app's life. It used to stop once
/// both permissions were granted; a later revoke has to be picked up too,
/// and a few cheap status reads every two seconds cost nothing. Everything
/// that reacts to a change — the hotkey source, the stand-in chord, the
/// polish availability — hangs off `onRefresh`, which runs after every poll.
@MainActor
@Observable
final class PermissionMonitor {
    private(set) var accessibilityTrusted = Permissions.isAccessibilityTrusted
    private(set) var microphoneStatus = Permissions.microphoneStatus
    /// Read with the grants: the hotkey router decides from a sustained
    /// reading, not from this one.
    private(set) var secureInputEnabled = SecureInput.isEnabled

    @ObservationIgnored var onRefresh: () -> Void = {}

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var didRequestAccessibility = false

    var needsAccessibility: Bool { !accessibilityTrusted }
    var needsMicrophone: Bool { microphoneStatus != .authorized }
    var needsAnyPermission: Bool { needsAccessibility || needsMicrophone }

    /// Prompts for Accessibility once per launch when it is missing, and
    /// starts polling.
    func start() {
        refresh()
        if !accessibilityTrusted && !didRequestAccessibility {
            didRequestAccessibility = true
            Permissions.requestAccessibility()
        }
        startPolling()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Assigns only what changed, so views reading one grant are not redrawn
    /// for every poll.
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

    /// Refreshes now and restarts the two-second cadence from here, so a
    /// grant the user just gave shows without waiting out the old timer.
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
