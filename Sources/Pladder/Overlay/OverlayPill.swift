import SwiftUI
import PladderCore

// Without the panel's shadow or forced scheme, so settings can show a live replica.
struct OverlayPill: View {
    let state: DictationState
    var level: Float = 0
    let style: OverlayStyle
    let glass: Bool
    var isPreview: Bool = false
    var partial: String?
    var hugsContent: Bool = false
    // In flight, or off screen, the pill is always the Minimal disc; replicas never fly.
    var presentation: OverlayPresentation = .settled
    var animationSpeed: OverlayAnimationSpeed = .quick

    @Namespace private var glassNamespace
    @State private var showDot = true
    @State private var pulsing = false

    private var phase: OverlayPhase { OverlayPhase(state) }

    private var flying: Bool { presentation != .settled }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            content
                // In flight the pill is proposed the disc's width, at rest its own, animated with the
                // same spring both ways, so contracting and expanding run at one rate.
                .frame(width: flying ? Self.minimalDiameter : nil)
                // What arrives inside fades in over the same span, so the row is faint while the
                // capsule is small; the clip keeps it inside the capsule.
                .clipShape(Capsule())
                .animation(animationSpeed.morphAnimation, value: flying)
                .modifier(PillBackground(glass: glass, namespace: glassNamespace))
        }
        .task(id: phase) {
            guard !isPreview else { return }
            // Leaving `.recording` resets the pulse, or the next take's dot would start at full
            // scale with no animation left to run.
            guard phase == .recording else {
                pulsing = false
                return
            }
            showDot = true
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { showDot = false }
        }
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    private var isCopied: Bool { state == .copied }

    // An error and the clipboard hint carry text, which needs the Compact row's width.
    private var needsRow: Bool { isError || isCopied || style != .minimal }

    // What arrives fades in over the morph; what leaves goes at once, so its dot is gone
    // before the arriving one shows and nothing slides into a shrinking capsule.
    private var contentHandover: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(animationSpeed.contentFade),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        // Minimal shares the flying branch, so its bars and dot keep their identity, and
        // their state, across the arrival.
        if flying || !needsRow {
            // A fixed square, so the disc never changes size between the dot, the wave and the
            // spinner.
            minimalContent
                .frame(width: Self.minimalDiameter, height: Self.minimalDiameter)
                .transition(contentHandover)
        }
        // `.menuBar` reaches the view only for an error or the clipboard hint, which take the
        // Compact row in every style. Live has its own recording row and Compact's for the rest.
        else if style == .liveTranscript && !isError {
            liveContent
                .frame(minHeight: 32)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 140)
                .transition(contentHandover)
        } else {
            compactContent
                .frame(minHeight: 32)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 140)
                .transition(contentHandover)
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        switch state {
        case .recording:
            HStack(spacing: PillMetrics.rowSpacing) {
                RecordingDot()
                LevelBars(level: level, count: 14, maxHeight: 32, opacity: 1, seeded: isPreview)
            }
        case .transcribing:
            HStack(spacing: PillMetrics.rowSpacing) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
            }
        case .polishing:
            HStack(spacing: PillMetrics.rowSpacing) {
                ProgressView()
                    .controlSize(.small)
                Text("Polishing…")
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
            }
        case .copied:
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                Text("Copied — press ⌘V")
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
            }
        case .error(let failure):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(failure.text)
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 232)
            }
        case .inserting, .idle, .unavailable:
            Color.clear.frame(width: 100)
        }
    }

    // Only the recording row differs from Compact: the others, at the live row's width,
    // would leave a mostly empty capsule.
    @ViewBuilder
    private var liveContent: some View {
        switch state {
        case .recording:
            HStack(spacing: PillMetrics.rowSpacing) {
                RecordingDot()
                LevelBars(level: level, count: Self.liveBarCount, maxHeight: 24, opacity: 1, seeded: isPreview)
                LiveTranscriptText(
                    text: partial ?? "",
                    hugs: hugsContent,
                    width: hugsContent ? Self.previewTextWidth : Self.liveTextWidth
                )
            }
            // A width that followed the text would jitter on every pass; the height follows
            // the lines, one to three.
            .frame(width: hugsContent ? nil : Self.liveRowWidth, alignment: .leading)
        default:
            compactContent
        }
    }

    // With 18 pt padding either side the capsule is 440 pt, inside the 480 pt panel with
    // room for its shadow.
    static let liveRowWidth: CGFloat = 404
    private static let liveBarCount = 8
    private static let liveRowLead: CGFloat = PillMetrics.dotSize + PillMetrics.rowSpacing
        + PillMetrics.barsWidth(count: liveBarCount) + PillMetrics.rowSpacing

    static var liveTextWidth: CGFloat { liveRowWidth - liveRowLead }
    static let previewTextWidth: CGFloat = 62

    // Five 3 pt bars with 3 pt gaps are 27 × 20 pt, inside the disc with room to spare.
    static let minimalDiameter: CGFloat = 44

    @ViewBuilder
    private var minimalContent: some View {
        switch state {
        case .recording:
            ZStack {
                if showsDot {
                    // A row style flying in keeps the dot at the row's size, so the dot it hands over to
                    // on arrival is the same dot.
                    RecordingDot()
                        .scaleEffect(pulsing && !needsRow ? 1.3 : 1.0)
                        .onAppear {
                            guard !isPreview else { return }
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                pulsing = true
                            }
                        }
                        .transition(.opacity)
                } else {
                    LevelBars(level: level, count: 5, maxHeight: 20, opacity: 0.8, seeded: isPreview)
                        .transition(.opacity)
                }
            }
        case .transcribing, .polishing:
            ProgressView()
                .controlSize(.small)
        case .copied:
            // The disc the hint collapses into keeps its glyph, so what slides away still says
            // what happened.
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
                .transition(.opacity)
        case .inserting, .error, .idle, .unavailable:
            Color.clear
        }
    }

    // A replica has no timer. A row style collapsing after a short take would otherwise
    // put the dot back in the capsule its own dot just left.
    private var showsDot: Bool {
        if isPreview { return false }
        if presentation == .flyingOut && needsRow { return false }
        return showDot
    }
}
