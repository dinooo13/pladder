import Foundation

// What the app redoes after a settings edit, each only when its own keys changed:
// re-assigning a forced Light or Dark appearance re-themes every window, and on every
// click of a settings card it made the rows lag behind the click.
public struct SettingsChange: Sendable, Equatable {
    public var hotkey = false
    public var appearance = false
    public var overlayStyle = false
    public var overlaySpeed = false
    public var polish = false

    public init(hotkey: Bool = false, appearance: Bool = false, overlayStyle: Bool = false,
                overlaySpeed: Bool = false, polish: Bool = false) {
        self.hotkey = hotkey
        self.appearance = appearance
        self.overlayStyle = overlayStyle
        self.overlaySpeed = overlaySpeed
        self.polish = polish
    }

    public init(from old: Settings, to new: Settings) {
        hotkey = new.hotkey != old.hotkey
        appearance = new.appearance != old.appearance
        overlayStyle = new.overlayStyle != old.overlayStyle || new.overlayGlass != old.overlayGlass
        overlaySpeed = new.overlayAnimationSpeed != old.overlayAnimationSpeed
        polish = new.polishModel != old.polishModel || new.polishDictations != old.polishDictations
    }
}
