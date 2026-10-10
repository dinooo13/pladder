import SwiftUI
import PladderCore

struct OverlayView: View {
    let model: OverlayModel

    private var phase: OverlayPhase { OverlayPhase(model.state) }

    var body: some View {
        OverlayPill(
            state: model.state,
            level: model.level,
            style: model.style,
            glass: model.glass,
            partial: model.partialTranscript,
            presentation: model.presentation,
            animationSpeed: model.speed
        )
            // Glass carries its own edge highlight; this only lifts the pill off a light desktop.
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .animation(.smooth(duration: 0.25), value: phase)
            .animation(model.speed.morphAnimation, value: model.presentation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ForcedScheme(appearance: model.appearance))
    }
}

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
