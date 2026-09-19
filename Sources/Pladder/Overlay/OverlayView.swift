import SwiftUI
import PladderCore

/// The state the overlay renders. Kept separate from the coordinator so the
/// panel can be driven independently (and shown while fading out after the
/// coordinator has already returned to `.idle`).
@MainActor
@Observable
final class OverlayModel {
    var state: DictationState = .idle
    /// Appearance forced by the Appearance setting; `.system` means follow.
    /// AppKit's window propagation reaches a borderless panel inconsistently,
    /// so the color scheme is set in SwiftUI directly.
    var appearance: Appearance = .system
    /// Which pill the user picked. `.menuBar` never presents except for
    /// errors; the controller decides that, not the view.
    var style: OverlayStyle = .compact
    /// Liquid Glass behind the pill, or a flat window-background fill.
    var glass: Bool = true
    /// What the engine has heard so far, for the Live Transcript style. Nil in
    /// every other style, and nil again the moment the key is released.
    var partialTranscript: String?
    init() {}
}

/// What the pill looks like, with the live audio level projected out.
///
/// `DictationState.recording` carries a level that changes many times a second.
/// Driving the capsule's morph animation off the state itself would restart
/// that animation on every meter update, so the morph animates on this
/// level-free phase instead while the bars animate on their own.
private enum OverlayPhase: Equatable {
    case empty
    case recording
    case transcribing
    case done
    case error(String)

    init(_ state: DictationState) {
        switch state {
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        // The hint is the end of a dictation like the tick is, so the pill
        // does not morph between them.
        case .inserting, .copied: self = .done
        case .error(let message): self = .error(message)
        case .idle, .unavailable: self = .empty
        }
    }
}

/// Liquid Glass pill: a capsule that samples the desktop behind the
/// transparent panel and morphs between the recording, transcribing, done and
/// error states.
struct OverlayView: View {
    let model: OverlayModel

    private var phase: OverlayPhase { OverlayPhase(model.state) }

    var body: some View {
        OverlayPill(
            state: model.state,
            style: model.style,
            glass: model.glass,
            partial: model.partialTranscript
        )
            // Glass carries its own edge highlight; this is only enough shadow
            // to lift the pill off a light desktop. The flat background gets
            // the same treatment.
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .animation(.smooth(duration: 0.25), value: phase)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ForcedScheme(appearance: model.appearance))
    }
}

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

    @Namespace private var glassNamespace
    /// Minimal shows a pulsing dot for the first 0.7 s, then the bars.
    @State private var showDot = true
    @State private var pulsing = false

    private var phase: OverlayPhase { OverlayPhase(state) }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            content
                .modifier(PillBackground(glass: glass, shape: shape, namespace: glassNamespace))
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

    /// Minimal is a disc; everything else, including an error or the "press
    /// ⌘V" hint shown under Minimal, is the capsule. Glass morphs between the
    /// two.
    private var shape: AnyShape {
        needsRow ? AnyShape(Capsule()) : AnyShape(Circle())
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    private var isCopied: Bool { state == .copied }

    /// Both an error and the clipboard hint carry text, which needs the
    /// Compact row's width, so they render as the row in every style.
    private var needsRow: Bool { isError || isCopied || style != .minimal }

    @ViewBuilder
    private var content: some View {
        // An error presents in every style (the controller makes sure of it),
        // and the message needs the Compact row's width, so errors always
        // render as the Compact row; the "press ⌘V" hint is text too and
        // follows the same rule. `.menuBar` only ever reaches the view for
        // those two. Live has its own recording row and falls back to the
        // Compact rows for everything else.
        if style == .liveTranscript && !isError {
            liveContent
                .frame(minHeight: 32)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 140)
        } else if needsRow {
            compactContent
                .frame(minHeight: 32)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minWidth: 140)
        } else {
            // A fixed square so the disc never changes size between the
            // dot, the wave, the spinner and the tick.
            minimalContent
                .frame(width: Self.minimalDiameter, height: Self.minimalDiameter)
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        switch state {
        case .recording(let level):
            HStack(spacing: 10) {
                RecordingDot()
                LevelBars(level: level, count: 14, maxHeight: 32, opacity: 1, seeded: isPreview)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
        case .inserting:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
        case .copied:
            // Nothing pasted the text, so the user has to. Same row as Done,
            // with the instruction in place of the tick's word.
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                Text("Copied — press ⌘V")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Keeps a long message inside the panel instead of letting
                    // the capsule grow past its edges.
                    .frame(maxWidth: 232)
            }
        case .idle, .unavailable:
            Color.clear.frame(width: 100)
        }
    }

    /// The words as they are recognised, beside a narrower meter. Only the
    /// recording row differs from Compact: transcribing, done and the error
    /// say the same thing in every style, and letting them keep the live row's
    /// width would leave a mostly empty capsule on screen.
    @ViewBuilder
    private var liveContent: some View {
        switch state {
        case .recording(let level):
            HStack(spacing: 10) {
                RecordingDot()
                LevelBars(level: level, count: 8, maxHeight: 24, opacity: 1, seeded: isPreview)
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

    /// What the dot, the eight bars and the two 10 pt gaps take of that row.
    /// The bars are 3 pt wide with 3 pt between them.
    private static let liveRowLead: CGFloat = 8 + 10 + (8 * 3 + 7 * 3) + 10

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

    /// Just enough to say "recording", "working", "done": no text, and a
    /// disc rather than a pill. The dot marks the start of a take, then a
    /// narrow wave takes over so the disc still shows the microphone is live.
    @ViewBuilder
    private var minimalContent: some View {
        switch state {
        case .recording(let level):
            ZStack {
                if showsDot {
                    RecordingDot()
                        .scaleEffect(pulsing ? 1.3 : 1.0)
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
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .inserting:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
        // An error and the clipboard hint are rendered as the row above, so
        // they never reach this.
        case .copied, .error, .idle, .unavailable:
            Color.clear
        }
    }

    /// A replica has no timer, so it goes straight to the bars.
    private var showsDot: Bool { isPreview ? false : showDot }
}

/// The words so far, with the part that has not settled yet in secondary.
///
/// Every live pass re-decodes the audio and returns a whole new string, so the
/// layout can change anywhere in it. Nothing here animates: a cross-fade
/// between two layouts draws both at once, which is unreadable at two passes a
/// second. Each pass simply replaces the text. The only thing carried between
/// passes is the common prefix with the previous string, which is the part the
/// engine has stopped changing; what came after it is drawn in secondary, so
/// the eye can see where the settled words end.
struct LiveTranscriptText: View {
    let text: String
    /// A replica in a settings card has no row to fill, so it hugs its sample
    /// text, wrapped at `width` onto at most two lines and never trimmed.
    var hugs: Bool = false
    /// How wide the words may run before they wrap, so the view can work out
    /// how much of the tail fits.
    var width: CGFloat?

    /// Three lines of 13 pt is as much as the pill can show without turning
    /// into a window.
    static let maximumLines = 3

    /// The font the words are drawn in, and the one they are measured in.
    static let font = Font.system(size: 13, weight: .medium, design: .rounded)

    /// The text of the previous pass, for the settled/unsettled split. It is
    /// only a colour, so lagging one pass behind costs nothing.
    @State private var previous = ""

    /// The part of the text that is shown: the whole of it while it fits in
    /// three lines, and its tail once it does not. SwiftUI's own head
    /// truncation is no use here — with a line limit it keeps the first lines
    /// and ellipsises the last one, which shows the oldest words and the
    /// newest ones with the middle missing — so the cut is made here, at a
    /// word boundary, against the font's real metrics.
    private var shown: String {
        guard let width, !hugs else { return text }
        return LiveTranscriptMetrics.tail(of: text, fittingLines: Self.maximumLines, width: width)
    }

    /// One `AttributedString` rather than two concatenated `Text`s, which
    /// macOS 26 deprecates.
    private var attributed: AttributedString {
        let shown = shown
        // The previous pass may have been trimmed to a different tail, so
        // compare like with like from the end.
        var stable = shown.commonPrefix(with: previous.suffix(shown.count))
        // A prefix that stops inside a word would paint half of it grey, so
        // back up to the end of the last whole word.
        if stable.count < shown.count, let lastSpace = stable.lastIndex(where: \.isWhitespace) {
            stable = String(stable[..<lastSpace])
        }
        var settled = AttributedString(stable)
        settled.foregroundColor = .primary
        var unsettled = AttributedString(shown.dropFirst(stable.count))
        unsettled.foregroundColor = .secondary
        return settled + unsettled
    }

    var body: some View {
        Text(attributed)
            .font(Self.font)
            .multilineTextAlignment(.leading)
            // A backstop only: `shown` has already been cut to fit.
            .lineLimit(hugs ? 2 : Self.maximumLines)
            // The row is a fixed width and the text takes what the dot and the
            // meter leave of it, wrapping there. Its height is whatever that
            // wrapping needs, one line to three, and the capsule grows with
            // it; a fixed box would leave a single line stranded at an edge.
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: hugs ? width : nil, alignment: .leading)
            .frame(maxWidth: hugs ? nil : .infinity, alignment: .leading)
            .onChange(of: text) { old, _ in previous = old }
    }
}

/// The red "live" dot, shared by Compact, Minimal and the settings replicas.
struct RecordingDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: size, height: size)
            .shadow(color: .red.opacity(0.6), radius: 4)
    }
}

/// What sits behind the pill: Liquid Glass, or a flat window-background
/// capsule with a hairline border for people who want the desktop to stay
/// still. The shadow is added by whoever hosts the pill.
struct PillBackground: ViewModifier {
    let glass: Bool
    /// Capsule for the rows, circle for the Minimal disc.
    var shape: AnyShape = AnyShape(Capsule())
    /// Only the live overlay morphs between states, so the glass identity is
    /// optional; the settings replicas pass nothing.
    var namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            if let namespace {
                content
                    .glassEffect(.regular, in: shape)
                    .glassEffectID("pill", in: namespace)
            } else {
                content
                    .glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        }
    }
}

/// Bars whose heights follow the input level. The shaping (amplitude curve,
/// bell envelope, wobble, rise/fall blend) lives in the shared
/// `WaveformMeter`, so this wave matches the menu bar glyph exactly.
struct LevelBars: View {
    let level: Float
    let count: Int
    let maxHeight: CGFloat
    let opacity: Double

    private static let minScale: CGFloat = 0.1

    @State private var meter: WaveformMeter
    @State private var heights: [CGFloat]

    /// `seeded` pre-rolls the meter so a static replica (the settings cards,
    /// which never see a level change) shows a wave rather than a row of
    /// stubs.
    init(level: Float, count: Int, maxHeight: CGFloat, opacity: Double, seeded: Bool = false) {
        self.level = level
        self.count = count
        self.maxHeight = maxHeight
        self.opacity = opacity

        var meter = WaveformMeter(count: count)
        var initial = Array(repeating: Self.minScale, count: count)
        if seeded {
            var shaped: [Float] = []
            for _ in 0..<8 { shaped = meter.update(level: level) }
            initial = shaped.map { max(Self.minScale, CGFloat($0)) }
        }
        _meter = State(initialValue: meter)
        _heights = State(initialValue: initial)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(opacity))
                    .frame(width: 3, height: max(3, heights[index] * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .onChange(of: level) { _, new in
            let next = meter.update(level: new)
            withAnimation(.easeOut(duration: 0.1)) {
                heights = next.map { max(Self.minScale, CGFloat($0)) }
            }
        }
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
