import AppKit
import SwiftUI
import SpeakUpCore

import SpeakUpSystem

@main
struct SpeakUpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Deferred to the first run-loop turn so the app has finished launching
        // before we prompt for Accessibility. The screenshot mode never
        // starts the hotkey, microphone or engine; it only opens windows.
        if let directory = Screenshots.directory {
            Task { @MainActor in await Screenshots.run(into: directory) }
        } else {
            Task { @MainActor in model.start() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: model.menuBarImage)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
        // The settings view sizes itself; without this the window opens at a
        // default size and lets the user squash the forms.
        .windowResizability(.contentSize)
    }
}

/// `LSUIElement` in Info.plist already hides the Dock icon; setting the policy
/// here too keeps `swift run` (no bundle, no Info.plist) behaving the same.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusLine)

        if model.canRetryEngine {
            Button("Retry Model Download") { model.coordinator.reloadEngine() }
        }

        if let last = model.lastTranscriptSummary {
            Divider()
            Button("Last: \(last)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.coordinator.lastTranscript?.text ?? "", forType: .string)
            }
        }

        Divider()

        Button("Settings…") {
            // An accessory app is never active, so a plain openSettings() puts
            // the window behind whatever the user was using.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
            }
        }
            .keyboardShortcut(",", modifiers: .command)

        if model.needsAnyPermission {
            Divider()
            if model.needsAccessibility {
                Button("Grant Accessibility…") { model.grantAccessibility() }
            }
            if model.needsMicrophone {
                Button("Grant Microphone…") { model.grantMicrophone() }
            }
        }

        Divider()

        Button("Quit SpeakUp") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
