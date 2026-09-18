import AppKit
import SwiftUI
import PladderCore

/// `Pladder --screenshots <dir>` renders the pictures the README shows into
/// `<dir>` and quits: the real overlay pill on a stand-in desktop, in light
/// and dark, plus the social preview card. It never starts the hotkey, the
/// microphone or the engine, so it can run beside a copy of Pladder that is
/// in use. `scripts/make-screenshots.sh` wraps it.
@MainActor
enum Screenshots {
    /// The output directory when the flag is present, nil for a normal launch.
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--screenshots"), index + 1 < args.count else { return nil }
        return URL(filePath: args[index + 1])
    }

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            await capture(FlowFigure(), size: CGSize(width: 960, height: 260), scheme: scheme,
                          to: directory.appending(path: "flow-\(suffix).png"))
            // Four tiles of 290 pt with 24 pt between them and 16 pt of
            // padding either side.
            await capture(StylesFigure(), size: CGSize(width: 1264, height: 250), scheme: scheme,
                          to: directory.appending(path: "styles-\(suffix).png"))
        }
        await capture(SocialFigure(), size: CGSize(width: 1280, height: 640), scheme: .dark,
                      to: directory.appending(path: "social-preview.png"))

        NSApp.terminate(nil)
    }

    /// Shows `figure` in a transparent borderless window and captures it.
    private static func capture<Figure: View>(_ figure: Figure, size: CGSize, scheme: ColorScheme, to url: URL) async {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(
            rootView: figure
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
        )
        window.center()
        window.orderFrontRegardless()
        // Layout, and the glass sampling its backdrop.
        try? await Task.sleep(for: .milliseconds(700))
        capture(window: window, to: url)
        window.orderOut(nil)
    }

    /// `screencapture -l` grabs one window at its backing scale. The child
    /// inherits the Screen Recording grant of the terminal that launched
    /// Pladder, which is why the script runs the binary directly rather
    /// than through `open`.
    private static func capture(window: NSWindow, to url: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        do {
            try process.run()
            process.waitUntilExit()
            print("wrote \(url.path)")
        } catch {
            print("screenshots: \(error)")
        }
    }
}

// MARK: - Views

/// A stand-in desktop: the diagonal wash the option cards use, with a few
/// soft blobs so the glass has something to refract.
private struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.30, green: 0.36, blue: 0.70), Color(red: 0.10, green: 0.12, blue: 0.32)]
                    : [Color(red: 0.62, green: 0.78, blue: 0.97), Color(red: 0.24, green: 0.46, blue: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                Circle()
                    .fill(scheme == .dark ? Color(red: 0.55, green: 0.40, blue: 0.95) : Color.white)
                    .opacity(scheme == .dark ? 0.35 : 0.45)
                    .frame(width: w * 0.5)
                    .blur(radius: w * 0.09)
                    .position(x: w * 0.22, y: h * 0.15)
                Circle()
                    .fill(scheme == .dark ? Color(red: 0.20, green: 0.70, blue: 0.90) : Color(red: 0.95, green: 0.80, blue: 1.0))
                    .opacity(0.35)
                    .frame(width: w * 0.45)
                    .blur(radius: w * 0.08)
                    .position(x: w * 0.82, y: h * 0.95)
            }
        }
    }
}

/// A pill exactly as the overlay shows it, shadow included.
private struct Pill: View {
    let state: DictationState
    var style: OverlayStyle = .compact
    var scale: CGFloat = 1
    /// The words so far, for the Live Transcript pill.
    var partial: String?

    var body: some View {
        OverlayPill(state: state, style: style, glass: true, isPreview: true, partial: partial)
            // A tile is narrower than the live row, and the proposed size
            // would squeeze the glass but not the row inside it; the pill
            // takes its own size and is scaled to fit instead.
            .fixedSize()
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .scaleEffect(scale)
    }
}

/// Hold, release, pasted: the three states of one dictation, left to right.
private struct FlowFigure: View {
    var body: some View {
        Wallpaper()
            .overlay {
                HStack(spacing: 72) {
                    Pill(state: .recording(level: 0.6), scale: 1.3)
                    Pill(state: .transcribing, scale: 1.3)
                    Pill(state: .inserting, scale: 1.3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

/// The four overlay styles side by side, each on its own desktop.
private struct StylesFigure: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            tile("Compact") {
                Pill(state: .recording(level: 0.6), scale: 1.15)
            }
            tile("Minimal") {
                Pill(state: .recording(level: 0.6), style: .minimal, scale: 1.15)
            }
            tile("Live") {
                // The real live row, at its real width: 440 pt of capsule
                // scaled to fit the tile.
                Pill(
                    state: .recording(level: 0.6),
                    style: .liveTranscript,
                    scale: 0.6,
                    partial: "the words show up as you say them, right here"
                )
            }
            tile("Menu Bar") {
                Color.clear
            }
            .overlay(alignment: .top) { menuBar }
        }
        .padding(.horizontal, 16)
    }

    private func tile<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            Wallpaper()
                .overlay { content() }
                .frame(width: 290, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(title)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    /// A slice of menu bar with the live wave glyph where Pladder sits.
    private var menuBar: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(nsImage: MenuBarIcon.image(for: .recording(level: 0.6)))
                .renderingMode(.template)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("9:41")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(scheme == .dark ? .white : .black)
        .padding(.horizontal, 14)
        .frame(width: 290, height: 28)
        .background(.ultraThinMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
    }
}

/// The 1280×640 card GitHub shows when the repository is shared.
private struct SocialFigure: View {
    var body: some View {
        Wallpaper()
            .overlay {
                VStack(spacing: 28) {
                    HStack(spacing: 28) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 128, height: 128)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pladder")
                                .font(.system(size: 72, weight: .bold, design: .rounded))
                            Text("Push-to-talk dictation for macOS. On-device. Free.")
                                .font(.system(size: 26, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .foregroundStyle(.white)
                    Pill(state: .recording(level: 0.6), scale: 1.5)
                        .padding(.top, 24)
                }
            }
    }
}
