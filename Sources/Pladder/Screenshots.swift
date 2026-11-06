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

        // `--settings`: each Settings tab, for reviewing the window without opening it.
        if CommandLine.arguments.contains("--settings") {
            let model = AppModel(location: .scratch)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                await capture(GeneralSettingsView(model: model), size: CGSize(width: 540, height: model.needsSetup ? 800 : 640), scheme: scheme,
                              to: directory.appending(path: "settings-general-\(suffix).png"), opaque: true)
                await capture(DictionaryView(model: model), size: CGSize(width: 540, height: 460), scheme: scheme,
                              to: directory.appending(path: "settings-dictionary-\(suffix).png"), opaque: true)
                await capture(TextSettingsView(model: model), size: CGSize(width: 540, height: 500), scheme: scheme,
                              to: directory.appending(path: "settings-text-\(suffix).png"), opaque: true)
            }
            NSApp.terminate(nil)
            return
        }

        // `--hero`: the site's hero picture, the real pill over a plain chat window, on the
        // site's own background so the glass samples what the visitor will see around it.
        if CommandLine.arguments.contains("--hero") {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                await capture(HeroFigure(), size: HeroFigure.size, scheme: scheme,
                              to: directory.appending(path: "hero-\(suffix).png"), opaque: true)
            }
            NSApp.terminate(nil)
            return
        }

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            // Four tiles of 290 pt, 24 pt between them and 16 pt of padding either side.
            await capture(StylesFigure(), size: CGSize(width: 1264, height: 250), scheme: scheme,
                          to: directory.appending(path: "styles-\(suffix).png"))
        }

        NSApp.terminate(nil)
    }

    private static func capture<Figure: View>(
        _ figure: Figure, size: CGSize, scheme: ColorScheme, to url: URL, opaque: Bool = false
    ) async {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = opaque ? .windowBackgroundColor : .clear
        window.isOpaque = opaque
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
    var body: some View { DesktopWash() }
}

private struct Pill: View {
    let state: DictationState
    var level: Float = 0
    var style: OverlayStyle = .compact
    var scale: CGFloat = 1
    var partial: String?

    var body: some View {
        OverlayPill(state: state, level: level, style: style, isPreview: true, partial: partial)
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
                .font(.system(size: 17, weight: .medium))
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

// The site's hero: a chat with an agent, the reply being dictated, and the Live pill.
private struct HeroFigure: View {
    static let size = CGSize(width: 580, height: 420)
    @Environment(\.colorScheme) private var scheme

    // The site's --hero colours, so the picture has no edge on the page.
    private var page: Color { scheme == .dark ? Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255) : .white }

    var body: some View {
        ZStack(alignment: .top) {
            page
            window
                .padding(.top, 16)
                .padding(.horizontal, 20)
            Pill(
                state: .recording,
                level: 0.6,
                style: .liveTranscript,
                partial: "yes, and add a test for it"
            )
            .padding(.top, 326)
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
                Spacer()
                Text(verbatim: "Persist dark mode")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "Why does dark mode reset?")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                (Text(verbatim: "It’s only kept in memory. Save it to ")
                    + Text(verbatim: "UserDefaults").font(.system(size: 12, design: .monospaced))
                    + Text(verbatim: "?"))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    HStack(spacing: 1) {
                        Text(verbatim: "Yes, and add a test for it.")
                        Rectangle().fill(Color.accentColor).frame(width: 2, height: 17)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            }
            .font(.system(size: 15))
            .padding(18)
        }
        .frame(height: 324)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        // Small enough to fade out inside the picture, which would otherwise cut it off.
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }
}
