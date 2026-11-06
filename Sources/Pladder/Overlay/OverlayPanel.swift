import AppKit
import SwiftUI
import PladderCore
import PladderSystem

// Never takes focus from the app being typed into: non-activating, never key, and
// click-through.
final class OverlayPanel: NSPanel {
    // Room for the shadow and the widest error message, which every style must fit;
    // only the live transcript needs more.
    private static func size(for style: OverlayStyle) -> NSSize {
        switch style {
        case .liveTranscript: NSSize(width: 480, height: 140)
        case .menuBar, .minimal, .compact: NSSize(width: 320, height: 96)
        }
    }

    // The controller waits this out before it resets the model, so the content stays
    // for the whole fade.
    static let fadeOutDuration: TimeInterval = 0.25

    // The pill's own height in the row styles; the Live row grows above it.
    private static let pillHeight: CGFloat = 56

    // The focused text field, read at the press; the pill rests above it if it would cover it.
    var avoiding: CGRect?

    // The bottom of the screen the pill rests on: flights start and end behind it.
    private var screenBottom: CGFloat = 0

    private let model: OverlayModel

    // So a fade-out superseded by a new show does not order the window out afterwards.
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
        // A window shadow on a transparent panel shows as a faint box around the pill.
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

    func show(flight: Bool, onArrival: (@MainActor @Sendable () -> Void)? = nil) {
        generation &+= 1
        let token = generation
        let final = targetFrame()
        alphaValue = 1
        // `orderFrontRegardless`: an accessory app is never active.
        if flight {
            // Below the bottom edge the window is clipped, so nothing flashes on the way up.
            setFrame(final.offsetBy(dx: 0, dy: -flightDistance(from: final)), display: false)
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = OverlayMotion.flightDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(final, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    onArrival?()
                }
            })
        } else {
            // A running dive keeps driving the frame after a plain `setFrame`, and the panel
            // would end below the edge with the hint on it; only an animated frame supersedes it.
            let diving = isVisible && frame != final
            if !diving { setFrame(final, display: false) }
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                if diving { animator().setFrame(final, display: true) }
                animator().alphaValue = 1
            }
        }
    }

    func hide(flight: Bool) {
        generation &+= 1
        let token = generation
        if flight {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = OverlayMotion.flightDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().setFrame(
                    frame.offsetBy(dx: 0, dy: -flightDistance(from: frame)),
                    display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.orderOut(nil)
                }
            })
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeOutDuration
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
    }

    // The screen the pointer is on, where the user is looking.
    private func targetFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return self.frame }
        screenBottom = screen.frame.minY
        // `visibleFrame` leaves out the Dock, so the pill never sits on top of it.
        return OverlayPlacement(
            screen: screen.frame, visible: screen.visibleFrame,
            panel: Self.size(for: model.style), pillHeight: Self.pillHeight
        ).frame(avoiding: avoiding)
    }

    // Down until the whole panel is behind the screen's bottom edge, which clips it.
    private func flightDistance(from frame: NSRect) -> CGFloat {
        frame.minY - screenBottom + frame.height
    }
}
