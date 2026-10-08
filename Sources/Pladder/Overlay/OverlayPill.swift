import SwiftUI
import PladderCore

/// The pill itself, without the panel's shadow or forced scheme, so the
/// settings previews can render a live replica of each style.
struct OverlayPill: View {
    let state: DictationState
    let style: OverlayStyle
    let glass: Bool
    /// A static replica in settings: no dot timer, no pulse, seeded bars.
    var isPreview: Bool = false
    /// The words so far, for the Live Transcript style. Ignored by the others.
    var partial: String?
    /// The live row is a fixed box on screen so the capsule cannot jitter as
    /// the text grows. A settings card has no room for that box, so its
    /// replica hugs its sample text, wrapped onto two short lines.
    var hugsContent: Bool = false
    /// While the pill flies in or out (or waits off screen) it is always the
    /// Minimal disc: the bigger styles expand from it after arriving and
    /// collapse back into it before diving. Settings replicas never fly, so
    /// they are always settled.
    var presentation: OverlayPresentation = .settled
    /// The speed whose spring drives the disc↔row geometry on both sides of
    /// the flight, so contracting to the disc takes exactly as long as
    /// expanding out of it. Settings replicas never fly, so they keep the
    /// default.
    var animationSpeed: OverlayAnimationSpeed = .quick

    @Namespace private var glassNamespace
    /// Minimal shows a pulsing dot for the first 0.7 s, then the bars.
    @State private var showDot = true
    @State private var pulsing = false

    private var phase: OverlayPhase { OverlayPhase(state) }

    private var flying: Bool { presentation != .settled }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            content
                // The size driver: in flight the pill is proposed the disc's
                // width, at rest its own — animated with the speed's morph
                // spring on *both* sides of the flight, so contracting to the
                // disc and expanding out of it are the same rate. The glass
                // bubble outside this point follows the proposal.
                .frame(width: flying ? Self.minimalDiameter : nil)
                // What arrives inside fades in over the same span (the branch
                // transitions below), so the row is still faint while the
                // capsule is small; this clip keeps it inside the capsule
                // rather than poking out of the disc.
                .clipShape(Capsule())
                .animation(animationSpeed.morphAnimation, value: flying)
                .modifier(PillBackground(glass: glass, namespace: glassNamespace))
        }
        .task(id: phase) {
            guard !isPreview else { return }
            // Runs on every phase change, so leaving `.recording` is where
            // the pulse is reset; otherwise the next take's dot would appear
            // already at full scale with no animation left to run.
            guard phase == .recording else {
                pulsing = false
                return
            }
            showDot = true
            try? await Task.sleep(for: .milliseconds(700))
            // A phase change cancels this task, which is exactly what should
            // stop the swap; nothing else to unwind.
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { showDot = false }
        }
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    private var isCopied: Bool { state == .copied }

    /// Both an error and the clipboard hint carry text, which needs the
    /// Compact row's width, so they render as the row in every style.
    private var needsRow: Bool { isError || isCopied || style != .minimal }

    /// The transition on every content branch: what is arriving fades in
    /// over the morph, so it comes up with the capsule around it; what is
    /// leaving goes at once, so its dot is gone before the arriving dot is
    /// visible and nothing is seen sliding towards the centre of a shrinking
    /// capsule.
    private var contentHandover: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(animationSpeed.contentFade),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        // In flight the pill is the Minimal disc whatever the style: the disc
        // rises with the dot inside it, and the style's own shape comes out
        // of it on arrival. Minimal shares that branch whether flying or
        // not, so its bars and dot keep their identity — and their state —
        // across the arrival.
        if flying || !needsRow {
            // A fixed square so the disc never changes size between the
            // dot, the wave and the spinner. On release a row style's
            // content goes at once and the Minimal wave comes up in the
            // shrinking capsule, so every style leaves the way Minimal does.
            minimalContent
                .frame(width: Self.minimalDiameter, height: Self.minimalDiameter)
                .transition(contentHandover)
        }
        // An error presents in every style (the controller makes sure of it),
        // and the message needs the Compact row's width, so errors always
        // render as the Compact row; the "press ⌘V" hint is text too and
        // follows the same rule. `.menuBar` only ever reaches the view for
        // those two. Live has its own recording row and falls back to the
        // Compact rows for everything else.
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
        case .recording(let level):
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
            // Only a dictation on its way to the refiner gets here, and it
            // waits seconds rather than milliseconds, so the pill says why.
            HStack(spacing: PillMetrics.rowSpacing) {
                ProgressView()
                    .controlSize(.small)
                Text("Polishing…")
                    .font(PillMetrics.font)
                    .foregroundStyle(.primary)
            }
        case .copied:
            // Nothing pasted the text, so the user has to. The one thing the
            // pill still says after a release: the paste that is normally the
            // confirmation never happened.
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
                    // Keeps a long message inside the panel instead of letting
                    // the capsule grow past its edges.
                    .frame(maxWidth: 232)
            }
        // `.inserting` is never mirrored onto the model, so it draws nothing.
        case .inserting, .idle, .unavailable:
            Color.clear.frame(width: 100)
        }
    }

    /// The words as they are recognised, beside a narrower meter. Only the
    /// recording row differs from Compact: the spinner, the clipboard hint and
    /// the error say the same thing in every style, and letting them keep the
    /// live row's width would leave a mostly empty capsule on screen.
    @ViewBuilder
    private var liveContent: some View {
        switch state {
        case .recording(let level):
            HStack(spacing: PillMetrics.rowSpacing) {
                RecordingDot()
                LevelBars(level: level, count: Self.liveBarCount, maxHeight: 24, opacity: 1, seeded: isPreview)
                LiveTranscriptText(
                    text: partial ?? "",
                    hugs: hugsContent,
                    width: hugsContent ? Self.previewTextWidth : Self.liveTextWidth
                )
            }
            // A capsule whose width changed with the text would jitter on
            // every pass, so the row is a fixed width; its height follows the
            // number of lines, one to three.
            .frame(width: hugsContent ? nil : Self.liveRowWidth, alignment: .leading)
        default:
            compactContent
        }
    }

    /// Width of the live row's contents. With the 18 pt padding either side
    /// the capsule comes to 440 pt, inside the 480 pt panel with room for its
    /// shadow.
    static let liveRowWidth: CGFloat = 404

    /// The live row's meter is narrower than Compact's, to leave the words
    /// room.
    private static let liveBarCount = 8

    /// What the dot, the meter and the two gaps take of that row.
    private static let liveRowLead: CGFloat = PillMetrics.dotSize + PillMetrics.rowSpacing
        + PillMetrics.barsWidth(count: liveBarCount) + PillMetrics.rowSpacing

    /// What is left of the row for the words. The text measures itself against
    /// this to decide how much of the tail fits in three lines.
    static var liveTextWidth: CGFloat { liveRowWidth - liveRowLead }

    /// The words in a settings card: wide enough for two short lines, so the
    /// card reads as text beside the meter rather than a long thin pill.
    static let previewTextWidth: CGFloat = 62

    /// Diameter of the Minimal disc. Five bars at 3 pt with 3 pt gaps are
    /// 27 pt wide and 20 pt tall, which sits inside the disc with room to
    /// spare at the chord where the bars reach.
    static let minimalDiameter: CGFloat = 44

    /// Just enough to say "recording", and "still working" when a
    /// transcription runs long: no text, and a disc rather than a pill. The
    /// dot marks the start of a take, then a narrow wave takes over so the
    /// disc still shows the microphone is live.
    @ViewBuilder
    private var minimalContent: some View {
        switch state {
        case .recording(let level):
            ZStack {
                if showsDot {
                    // The pulse is Minimal's own start-of-take cue. A row
                    // style flying in keeps the dot at the row's size, so
                    // the dot it hands over to on arrival is the same dot.
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
            // The hint leaves by the dive like a pasted dictation, and the
            // disc it collapses into keeps the row's clipboard glyph rather
            // than going empty, so what slides away still says what happened.
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.secondary)
                .transition(.opacity)
        // An error is rendered as the row above, so it never reaches this;
        // `.inserting` is never mirrored onto the model.
        case .inserting, .error, .idle, .unavailable:
            Color.clear
        }
    }

    /// A replica has no timer, so it goes straight to the bars. A row style
    /// collapsing after a short take would otherwise put the dot back in the
    /// middle of the capsule its own dot just left; the wave is what the
    /// disc shows on the way out.
    private var showsDot: Bool {
        if isPreview { return false }
        if presentation == .flyingOut && needsRow { return false }
        return showDot
    }
}
