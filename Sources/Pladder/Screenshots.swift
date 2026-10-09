import AppKit
import SwiftUI
import PladderCore

// `--screenshots <dir>`: the README's pictures. Never starts the hotkey, the microphone
// or the engine, so it can run beside a copy in use; `scripts/make-screenshots.sh` wraps it.
@MainActor
enum Screenshots {
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--screenshots"), index + 1 < args.count else { return nil }
        return URL(filePath: args[index + 1])
    }

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            // Four tiles of 290 pt, 24 pt between them and 16 pt of padding either side.
            await capture(StylesFigure(), size: CGSize(width: 1264, height: 250), scheme: scheme,
                          to: directory.appending(path: "styles-\(suffix).png"))
        }
        await capture(SocialFigure(), size: CGSize(width: 1280, height: 640), scheme: .dark,
                      to: directory.appending(path: "social-preview.png"))

        NSApp.terminate(nil)
    }

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

    // The child inherits the Screen Recording grant of the terminal that launched
    // Pladder, which is why the script runs the binary directly, not through `open`.
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

private struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            DesktopWash(scheme: scheme)
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

private struct Pill: View {
    let state: DictationState
    var level: Float = 0
    var style: OverlayStyle = .compact
    var scale: CGFloat = 1
    var partial: String?

    var body: some View {
        OverlayPill(state: state, level: level, style: style, glass: true, isPreview: true, partial: partial)
            // The proposed size would squeeze the glass but not the row inside it, so the pill
            // takes its own size and is scaled to fit.
            .fixedSize()
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .scaleEffect(scale)
    }
}

private struct StylesFigure: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            tile("Compact") {
                Pill(state: .recording, level: 0.6, scale: 1.15)
            }
            tile("Minimal") {
                Pill(state: .recording, level: 0.6, style: .minimal, scale: 1.15)
            }
            tile("Live") {
                // The real live row at its real width, scaled to fit the tile.
                Pill(
                    state: .recording,
                    level: 0.6,
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

    private var menuBar: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(nsImage: MenuBarIcon.image(for: .recording, level: 0.6))
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
                    Pill(state: .recording, level: 0.6, scale: 1.5)
                        .padding(.top, 24)
                }
            }
    }
}
