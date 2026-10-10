import AppKit
import SwiftUI
import PladderCore

import PladderSystem

@main
struct PladderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    // The overlay demo and the screenshots are not the app: a throwaway settings file,
    // and no menu bar item, which would be a second, slashed Pladder in the bar.
    private let isDeveloperMode: Bool

    init() {
        let isDeveloperMode = OverlayDemo.isRequested || Screenshots.directory != nil
        self.isDeveloperMode = isDeveloperMode
        let model = AppModel(location: isDeveloperMode ? .scratch : .live)
        _model = State(initialValue: model)
        // Deferred, so the app has finished launching before the Accessibility prompt.
        if OverlayDemo.isRequested {
            Task { @MainActor in await OverlayDemo.run() }
        } else if let directory = Screenshots.directory {
            Task { @MainActor in await Screenshots.run(into: directory) }
        } else {
            AppDelegate.shutdown = { await model.shutdown() }
            Task { @MainActor in model.start() }
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!isDeveloperMode)) {
            MenuContent(model: model)
        } label: {
            Image(nsImage: model.menuBarImage)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
        // Without this the window opens at a default size and lets the user squash the forms.
        .windowResizability(.contentSize)
    }
}

// `LSUIElement` hides the Dock icon; setting the policy too keeps `swift run`, which
// has no Info.plist, the same. See docs/ARCHITECTURE.md, "Dictation flow", for quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shutdown: (@MainActor () async -> Void)?
    // A dictation in flight with polish can take seconds; past this it is lost rather
    // than the quit hanging.
    private static let shutdownDeadline: Duration = .seconds(3)

    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        signal(SIGTERM, SIG_IGN)
        // Off the main queue, so a stuck main thread still hears the signal; past its own
        // deadline the process ends anyway, as an uncaught SIGTERM would have.
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            Task { @MainActor in NSApp.terminate(nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.signalExitDeadline) { exit(0) }
        }
        source.resume()
        terminationSignal = source
    }

    // Longer than `shutdownDeadline`, so a quit that can proceed always finishes first.
    private nonisolated static let signalExitDeadline: DispatchTimeInterval = .seconds(5)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown = Self.shutdown else { return .terminateNow }
        // A second Quit while this one waits quits at once.
        Self.shutdown = nil
        Task { @MainActor in
            _ = await firstOf(until: .now + Self.shutdownDeadline) { await shutdown() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusLine)

        if model.canRetryEngine {
            Button("Retry Model Download") { model.retryEngine() }
        }

        if let last = model.lastTranscriptSummary {
            Divider()
            Button("Last: \(last)") { model.copyLastTranscript() }
        }

        // A menu line, not a toast: the pill is click-through, and a proposal arriving a
        // minute later should wait, not interrupt.
        if !model.corrections.proposals.isEmpty {
            Divider()
            ForEach(model.corrections.proposals) { proposal in
                Menu("Learned “\(proposal.pair.heard)” → “\(proposal.pair.corrected)”?") {
                    Button("Add") { model.corrections.accept(proposal) }
                    Button("Dismiss") { model.corrections.dismiss(proposal) }
                }
            }
        }

        Divider()

        Button("Settings…") {
            // An accessory app is never active, so a plain `openSettings()` puts the window
            // behind whatever the user was using.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
            }
        }
            .keyboardShortcut(",", modifiers: .command)

        if model.permissions.needsAnyPermission {
            Divider()
            if model.permissions.needsAccessibility {
                Button("Grant Accessibility…") { model.permissions.grantAccessibility() }
            }
            if model.permissions.needsMicrophone {
                Button("Grant Microphone…") { model.permissions.grantMicrophone() }
            }
        }

        Divider()

        Button("Quit Pladder") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
