import SwiftUI
import PladderCore

// Without the panel's shadow or forced scheme, so settings can show a live replica.
struct OverlayPill: View {
    let state: DictationState
    var level: Float = 0
    let style: OverlayStyle
    var isPreview: Bool = false
    var partial: String?
    var hugsContent: Bool = false
    // In flight, or off screen, the pill is always the Minimal disc; replicas never fly.
    var presentation: OverlayPresentation = .settled

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace
    @State private var showDot = true
    @State private var pulsing = false
    @State private var widestText: CGFloat = 0

    private var phase: OverlayPhase { OverlayPhase(state) }

    private var flying: Bool { presentation != .settled }

    // The release: the row stays and fades while the capsule closes around it into the
    // disc. Swapping in the disc's own view here left the capsule no width to shrink from,
    // so the row vanished and a disc popped in.
    private var gathering: Bool { presentation == .flyingOut && needsRow && state.isRecording }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            content
                // In flight the pill is proposed the disc's width, at rest its own, animated with the
                // same spring both ways, so contracting and expanding run at one rate.
                .frame(width: flying ? Self.minimalDiameter : nil, height: gathering ? Self.minimalDiameter : nil)
                // What arrives inside fades in over the same span, so the row is faint while the
                // capsule is small; the clip keeps it inside the capsule.
                .clipShape(Capsule())
                .animation(OverlayMotion.morphAnimation, value: flying)
                .modifier(PillBackground(namespace: glassNamespace))
        }
        .task(id: phase) {
            guard !isPreview else { return }
            // Leaving `.recording` resets the pulse, or the next take's dot would start at full
            // scale with no animation left to run.
            guard phase == .recording else {
                pulsing = false
                return
            }
            widestText = 0
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

    // Which row is up; an error's text changes with its failure, its row does not.
    private var rowKey: Int {
        switch phase {
        case .empty: 0
        case .recording: 1
        case .transcribing: 2
        case .polishing: 3
        case .copied: 4
        case .error: 5
        }
    }

    // An error and the clipboard hint carry text, which needs the Compact row's width.
    private var needsRow: Bool { isError || isCopied || style != .minimal }

    // What arrives fades in over the morph; what leaves goes at once, so its dot is gone
    // before the arriving one shows and nothing slides into a shrinking capsule.
    private var contentHandover: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(OverlayMotion.contentFade),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        // Minimal shares the flying branch, so its bars and dot keep their identity, and
        // their state, across the arrival.
        if (flying && !gathering) || !needsRow {
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
                .opacity(gathering ? 0 : 1)
                .animation(.easeOut(duration: OverlayMotion.morphDuration * 0.3), value: gathering)
                .id(rowKey)
                .frame(minHeight: 32)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 140)
                .transition(contentHandover)
        } else {
            compactContent
                // The fade sits inside the identity: each row state is its own view, so a
                // gathered row leaves at the opacity it gathered to instead of coming back
                // under the clipboard hint while it is replaced.
                .opacity(gathering ? 0 : 1)
                .animation(.easeOut(duration: OverlayMotion.morphDuration * 0.3), value: gathering)
                .id(rowKey)
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
                LevelBars(level: level, count: 14, maxHeight: PillMetrics.barsHeight, opacity: 1, seeded: isPreview)
            }
        case .transcribing:
            HStack(spacing: PillMetrics.rowSpacing) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
                Text("Transcribing…")
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
            }
        case .polishing:
            HStack(spacing: PillMetrics.rowSpacing) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
                Text("Polishing…")
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
            }
        case .copied:
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                Text("Copied. Press ⌘V to paste.")
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
            }
        case .error(let failure):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                Text(failure.shortText)
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240, alignment: .leading)
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
                LevelBars(level: level, count: Self.liveBarCount, maxHeight: PillMetrics.barsHeight, opacity: 1, seeded: isPreview)
                if let partial, !partial.isEmpty {
                    LiveTranscriptText(
                        text: partial,
                        hugs: hugsContent,
                        width: hugsContent ? nil : liveTextWidth,
                        settled: isPreview
                    )
                } else {
                    // Until the first pass lands, so the capsule never reads as empty.
                    Text("Listening…")
                        .font(PillMetrics.font)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            // Grows with the words and never narrows within a take: a width that followed the
            // text both ways would jitter on every pass. The height follows the lines, one to three.
            // Not animated: an animated step laid the new words out at the old width, one word
            // short, and the step is rare enough that a snap reads as deliberate.
            .frame(width: hugsContent ? nil : Self.liveRowLead + liveTextWidth, alignment: .leading)
            .onChange(of: partial) { _, new in
                widestText = max(widestText, LiveTranscriptMetrics.lineWidth(of: new ?? ""))
            }
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

    // In steps, never narrowing within a take: a third, then the whole row. The capsule grows
    // from its centre, so a width that followed every word would slide the words sideways on
    // every pass.
    private var liveTextWidth: CGFloat {
        let needed = max(widestText, LiveTranscriptMetrics.lineWidth(of: partial ?? ""))
        let third = (Self.liveTextWidth / 3).rounded()
        // A reply that fits a third stays there; past it the row goes straight to its
        // full width, so the words move at most once and a short reply has no empty glass.
        return needed <= third ? third : Self.liveTextWidth
    }

    // Five 3 pt bars with 3 pt gaps are 27 × 20 pt, inside the disc with room to spare.
    static let minimalDiameter: CGFloat = 44

    @ViewBuilder
    private var minimalContent: some View {
        switch state {
        // Gathering after the release: the microphone is off and the paste is the news, so
        // the disc leaves empty rather than with frozen bars that read as an ellipsis.
        case .recording where presentation == .flyingOut && needsRow:
            Color.clear
        case .recording:
            ZStack {
                if showsDot {
                    // A row style flying in keeps the dot at the row's size, so the dot it hands over to
                    // on arrival is the same dot.
                    RecordingDot()
                        .scaleEffect(pulsing && !needsRow ? 1.3 : 1.0)
                        .onAppear {
                            guard !isPreview, !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                pulsing = true
                            }
                        }
                        .transition(.opacity)
                } else {
                    // Coral while the microphone is live, grey once the disc gathers at release, so
                    // the colour always means "listening".
                    LevelBars(level: level, count: 5, maxHeight: 20, opacity: 1, seeded: isPreview,
                              color: presentation == .flyingOut ? .primary : .brandCoral)
                        .transition(.opacity)
                }
            }
        case .transcribing, .polishing:
            ProgressView()
                .controlSize(.small)
                .tint(.primary)
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
