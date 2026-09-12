import AppKit
import SwiftUI
import PladderCore

/// Borderless floating panel that shows dictation status without ever taking
/// focus away from the app the user is typing into.
///
/// The combination that makes this work: `.nonactivatingPanel` so ordering the
/// window front does not activate Pladder, `canBecomeKey == false` so it never
/// becomes the key window, and `ignoresMouseEvents` so clicks fall through to
/// whatever is underneath.
final class OverlayPanel: NSPanel {
    /// Includes room around the capsule for its soft shadow and for the
    /// widest error message; the window itself draws nothing, so nothing is
    /// clipped and the pill sizes itself to its content inside this box. A
    /// smaller pill (Minimal) just centres in the invisible box, and every
    /// style has to fit the error row, so only the live transcript — which
    /// needs room for its text — asks for more.
    private static func size(for style: OverlayStyle) -> NSSize {
        switch style {
        case .liveTranscript: NSSize(width: 480, height: 140)
        case .menuBar, .minimal, .compact: NSSize(width: 320, height: 96)
        }
    }

    private let model: OverlayModel

    /// Bumped on every show/hide so a fade-out that is superseded by a new
    /// show does not order the window out afterwards.
    private var generation = 0

    init(model: OverlayModel) {
        self.model = model
        let size = Self.size(for: model.style)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        // The capsule draws its own shadow. A window shadow on a transparent
        // panel is computed from the window's rectangle and shows up as a faint
        // box around the pill.
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        contentView = host

        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        generation &+= 1
        // A borderless panel that is never key or main does not reliably
        // inherit an appearance changed through `NSApp.appearance` after it
        // was created, so re-sync on every show. The settings window restyles
        // itself; the panel only exists between its appearances.
        appearance = NSApp.appearance
        reposition()
        // `orderFrontRegardless` avoids requiring Pladder to be active, which
        // an accessory app never is.
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func hide() {
        generation &+= 1
        let token = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit runs this on the main thread, but types it as @Sendable.
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.orderOut(nil)
            }
        }
    }

    /// Bottom-centre of whichever screen the pointer is on, so the pill shows up
    /// where the user is looking on a multi-display setup.
    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        // The style can change between showings; the hosting view's
        // autoresizing mask follows `setFrame`.
        let size = Self.size(for: model.style)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 64
        )
        setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
