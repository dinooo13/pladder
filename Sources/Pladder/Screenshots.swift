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

    static var capturesMenu: Bool { CommandLine.arguments.contains("--menu") }

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // `--menu`: the real menu of this copy's own status item, opened in-process and closed
        // with an Escape posted to this app alone, in the system's appearance; menus do not
        // follow `NSApp.appearance`.
        if capturesMenu {
            await captureMenu(into: directory)
            NSApp.terminate(nil)
            return
        }

        // `--settings`: each Settings tab, for reviewing the window without opening it.
        if CommandLine.arguments.contains("--settings") {
            let model = AppModel(location: .scratch)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                for (tab, name) in [(SettingsTab.general, "general"), (.text, "text"), (.dictionary, "dictionary")] {
                    await captureWindow(SettingsView(model: model, tab: tab), scheme: scheme,
                                        to: directory.appending(path: "settings-\(name)-\(suffix).png"))
                }
            }
            NSApp.terminate(nil)
            return
        }

        // `--hero`: the site's hero picture, the real pill over a plain chat window, on the
        // site's own background so the glass samples what the visitor will see around it.
        // `--settings-scene`: the app's real Settings window, toolbar and key window included,
        // one capture per tab, light and dark.
        if CommandLine.arguments.contains("--settings-scene") {
            await captureSettingsScene(into: directory)
            NSApp.terminate(nil)
            return
        }

        // `--hero-video`: the site's hero film, the real window and pill through one dictation.
        if CommandLine.arguments.contains("--hero-video") {
            await HeroRecording.run(into: directory)
            NSApp.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--hero") {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                await capture(HeroFigure(), size: HeroFigure.size, scheme: scheme,
                              to: directory.appending(path: "hero-\(suffix).png"), opaque: true)
                // A phone shows the picture at about half size, so it gets a narrower one.
                await capture(HeroFigure(compact: true), size: HeroFigure.compactSize, scheme: scheme,
                              to: directory.appending(path: "hero-mobile-\(suffix).png"), opaque: true)
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

    // A titled window sized as SwiftUI sizes it, so the tab bar, the title and the height
    // are what the real Settings window shows.
    private static func captureWindow<Content: View>(_ content: Content, scheme: ColorScheme, to url: URL) async {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "General"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.toolbarStyle = .preference
        window.center()
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        window.setContentSize(host.fittingSize)
        try? await Task.sleep(for: .milliseconds(300))
        capture(window: window, to: url)
        window.orderOut(nil)
    }

    // Opens the Settings scene the way the menu does, from a SwiftUI view's `openSettings`,
    // then picks each tab through `SettingsView.requestedTab`.
    private static func captureSettingsScene(into directory: URL) async {
        let opener = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        opener.isReleasedWhenClosed = false
        opener.contentView = NSHostingView(rootView: SettingsOpener())
        opener.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
            print("screenshots: no Settings window")
            return
        }
        // What VoiceOver is given, tab by tab: role, label, value and help of every element,
        // in the order it walks them.
        if CommandLine.arguments.contains("--accessibility") {
            for (tab, name) in [(SettingsTab.general, "general"), (.text, "text"), (.dictionary, "dictionary")] {
                SettingsView.requestedTab = tab
                try? await Task.sleep(for: .seconds(1))
                var lines: [String] = []
                describe(window, depth: 0, into: &lines)
                try? lines.joined(separator: "\n").write(
                    to: directory.appending(path: "accessibility-\(name).txt"), atomically: true, encoding: .utf8)
                print("wrote accessibility-\(name).txt")
            }
            return
        }
        for (scheme, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: scheme)
            for (tab, name) in [(SettingsTab.general, "general"), (.text, "text"), (.dictionary, "dictionary")] {
                SettingsView.requestedTab = tab
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                capture(window: window, to: directory.appending(path: "scene-\(name)-\(suffix).png"))
            }
        }
        NSApp.appearance = nil
    }

    private static func captureMenu(into directory: URL) async {
        try? await Task.sleep(for: .seconds(1.5))
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, String(describing: type(of: view)).contains("StatusBarButton") { return button }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        guard let button = NSApp.windows.compactMap({ $0.contentView.flatMap(find) }).first else {
            print("screenshots: no status item")
            return
        }
        do {
            let url = directory.appending(path: "menu.png")
            let pid = ProcessInfo.processInfo.processIdentifier
            // The menu tracks in a nested run loop, so the capture runs beside it and then
            // closes it from the main queue, which that loop still serves.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
                let menu = windows.first {
                    ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowLayer as String] as? Int) ?? 0) > 24
                        && (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 40
                }
                if let number = menu?[kCGWindowNumber as String] as? Int {
                    let process = Process()
                    process.executableURL = URL(filePath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", String(number), url.path]
                    try? process.run()
                    process.waitUntilExit()
                    print("wrote \(url.lastPathComponent)")
                } else {
                    print("screenshots: no menu window")
                }
                DispatchQueue.main.async {
                    if let escape = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                        isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(escape, atStart: true)
                    }
                }
            }
            button.performClick(nil)
        }
    }

    // Through the Accessibility API, as VoiceOver reads it, from this process's own tree.
    private static func describe(_ window: NSWindow, depth: Int, into lines: inout [String]) {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        for element in (windows as? [AXUIElement]) ?? [] {
            walk(element, depth: 0, into: &lines)
        }
    }

    private static func walk(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        guard depth < 40 else { return }
        func string(_ attribute: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "" }
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
            return ""
        }
        let role = string(kAXRoleAttribute)
        var titled: CFTypeRef?
        var linkedTitle = ""
        if AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &titled) == .success,
           let titled, CFGetTypeID(titled) == AXUIElementGetTypeID() {
            var text: CFTypeRef?
            AXUIElementCopyAttributeValue(titled as! AXUIElement, kAXValueAttribute as CFString, &text)
            linkedTitle = (text as? String) ?? ""
        }
        let traits = [
            ("label", string(kAXDescriptionAttribute)), ("title", string(kAXTitleAttribute)),
            ("titled by", linkedTitle), ("value", string(kAXValueAttribute)), ("help", string(kAXHelpAttribute)),
        ].filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        if !(["AXGroup", "AXScrollArea", "AXUnknown"].contains(role) && traits.isEmpty) {
            lines.append(String(repeating: "  ", count: min(depth, 12)) + role + (traits.isEmpty ? "" : "  " + traits.joined(separator: "  ")))
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            walk(child, depth: depth + 1, into: &lines)
        }
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

// A quiet desktop with soft shapes in it, so the glass has something to bend; a flat
// grey makes it look like plastic.
private struct Wallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack {
                DesktopWash()
                Circle()
                    .fill(scheme == .dark ? Color(white: 0.42) : .white)
                    .frame(width: w * 0.7)
                    .blur(radius: w * 0.12)
                    .position(x: w * 0.2, y: h * 0.1)
                Circle()
                    .fill(Color(white: scheme == .dark ? 0.05 : 0.6).opacity(0.35))
                    .frame(width: w * 0.55)
                    .blur(radius: w * 0.12)
                    .position(x: w * 0.9, y: h * 0.95)
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
    var hugs = false

    var body: some View {
        OverlayPill(state: state, level: level, style: style, isPreview: true, partial: partial, hugsContent: hugs)
            // The proposed size would squeeze the glass but not the row inside it, so the pill
            // takes its own size and is scaled to fit.
            .fixedSize()
            .compositingGroup()
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            .scaleEffect(scale)
    }
}

private struct StylesFigure: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            tile("Compact") {
                Pill(state: .recording, level: 0.6, scale: 1.4)
            }
            tile("Minimal") {
                Pill(state: .recording, level: 0.6, style: .minimal, scale: 1.6)
            }
            tile("Live") {
                // The live row hugging a few words, so they read at the tile's size.
                Pill(
                    state: .recording,
                    level: 0.6,
                    style: .liveTranscript,
                    scale: 1.05,
                    partial: "as you speak",
                    hugs: true
                )
            }
            tile("Menu bar only") {
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

    // The menu bar with the glyph following the voice, and its menu saying so.
    private var menuBar: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 14) {
                Spacer()
                Image(nsImage: MenuBarIcon.image(for: .recording, level: 0.6, tile: true))
                    .renderingMode(.template)
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "switch.2")
            }
            .foregroundStyle(scheme == .dark ? .white : .black)
            .padding(.horizontal, 14)
            .frame(width: 290, height: 28)
            .background(.ultraThinMaterial)
            VStack(alignment: .leading, spacing: 3) {
                Text("Listening…").foregroundStyle(.secondary)
                Divider()
                Text("Copy Last Dictation")
                Divider()
                Text("About Pladder")
                Text("Settings…")
                Divider()
                Text("Quit Pladder")
            }
            .font(.system(size: 12))
            .padding(9)
            .frame(width: 160, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
            .padding(.trailing, 70)
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
    }
}

struct HeroPill {
    var partial: String?
    var presentation: OverlayPresentation = .settled
}

// The site's hero: a chat with an agent while the reply is still being said, so the
// prompt box waits with its cursor and the Live pill shows the words, as it is.
struct HeroFigure: View {
    static let size = CGSize(width: 580, height: 420)
    static let compactSize = CGSize(width: 350, height: 284)
    var compact = false
    // What the prompt box holds: nil is its placeholder with the cursor.
    var composer: String?
    // The pill, or none: the default is the still picture's.
    var pill: HeroPill? = HeroPill(partial: "yes, and add a test that relaunches the app")
    // Driven over time for the film; the stills leave it nil.
    var scene: HeroScene?
    @Environment(\.colorScheme) private var scheme

    // The site's --hero colours, so the picture has no edge on the page.
    private var page: Color { scheme == .dark ? Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255) : .white }

    var body: some View {
        ZStack(alignment: .top) {
            page
            window
                .padding(.top, 16)
                .padding(.horizontal, 20)
            if let scene {
                // The overlay panel's content as the app shows it, at the panel's size.
                OverlayView(model: scene.overlay)
                    .frame(width: 480, height: 140)
                    .offset(y: scene.pillOffset)
                    .opacity(scene.pillOpacity)
                    .padding(.top, 306)
            } else if let pill {
                OverlayPill(
                    state: .recording, level: 0.6, style: .liveTranscript, isPreview: true,
                    partial: compact ? "yes, and add a test" : pill.partial, hugsContent: compact,
                    presentation: pill.presentation)
                    .fixedSize()
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    // Laid out at its own size and scaled after, so a long reply can never widen
                    // the figure; on a phone it hugs a shorter one.
                    .scaleEffect(compact ? 0.8 : 1, anchor: .top)
                    .frame(width: compact ? Self.compactSize.width : nil)
                    .padding(.top, compact ? 224 : 348)
            }
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
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "Why does dark mode reset?")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if !compact {
                    Text("It’s only kept in memory. Save it to \(Text(verbatim: "UserDefaults").font(.system(size: 12, design: .monospaced)))?")
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    HStack(spacing: 1) {
                        if let composer = scene?.composer ?? composer {
                            Text(verbatim: composer)
                            Rectangle().fill(Color.accentColor).frame(width: 2, height: 17)
                        } else {
                            Rectangle().fill(Color.accentColor).frame(width: 2, height: 17)
                            Text(verbatim: "Reply…")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle((scene?.composer ?? composer) == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            }
            .font(.system(size: 15))
            .padding(18)
        }
        .frame(width: (compact ? Self.compactSize.width : Self.size.width) - 40, height: compact ? 196 : 324)
        // macOS 26 window corners.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
        // Small enough to fade out inside the picture, which would otherwise cut it off.
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }
}

private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.task {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}
