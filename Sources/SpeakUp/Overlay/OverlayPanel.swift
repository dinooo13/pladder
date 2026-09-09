import AppKit
import SwiftUI

/// Borderless floating panel that shows dictation status without ever taking
/// focus away from the app the user is typing into.
///
/// The combination that makes this work: `.nonactivatingPanel` so ordering the
/// window front does not activate SpeakUp, `canBecomeKey == false` so it never
/// becomes the key window, and `ignoresMouseEvents` so clicks fall through to
/// whatever is underneath.
final class OverlayPanel: NSPanel {
    private static let size = NSSize(width: 220, height: 56)

    /// Bumped on every show/hide so a fade-out that is superseded by a new
    /// show does not order the window out afterwards.
    private var generation = 0

    init(model: OverlayModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        contentView = host

        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        generation &+= 1
        reposition()
        // `orderFrontRegardless` avoids requiring SpeakUp to be active, which
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
        let origin = NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.minY + 80
        )
        setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }
}
