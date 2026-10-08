import SwiftUI
import PladderCore

/// Liquid Glass pill: a capsule that samples the desktop behind the
/// transparent panel and morphs between the recording, transcribing, copied
/// and error states.
struct OverlayView: View {
    let model: OverlayModel

    private var phase: OverlayPhase { OverlayPhase(model.state) }

    var body: some View {
        OverlayPill(
            state: model.state,
            style: model.style,
            glass: model.glass,
            partial: model.partialTranscript,
            presentation: model.presentation,
            animationSpeed: model.speed
        )
            // Glass carries its own edge highlight; this is only enough shadow
            // to lift the pill off a light desktop. The flat background gets
            // the same treatment.
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .animation(.smooth(duration: 0.25), value: phase)
            .animation(model.speed.morphAnimation, value: model.presentation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ForcedScheme(appearance: model.appearance))
    }
}

/// Overrides the SwiftUI color scheme under a forced appearance. AppKit's
/// window-appearance propagation reaches a borderless panel inconsistently,
/// so this sets the scheme in the environment directly, which is what
/// `glassEffect` and the text colours follow.
private struct ForcedScheme: ViewModifier {
    let appearance: Appearance

    func body(content: Content) -> some View {
        switch appearance {
        case .system: content
        case .light: content.environment(\.colorScheme, .light)
        case .dark: content.environment(\.colorScheme, .dark)
        }
    }
}
