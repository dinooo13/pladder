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
            partial: model.partialTranscript,
            presentation: model.presentation
        )
            // Glass carries its own edge highlight; this only lifts the pill off a light desktop.
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .animation(.smooth(duration: 0.25), value: phase)
            .animation(OverlayMotion.morphAnimation, value: model.presentation)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
