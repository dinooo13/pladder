import Foundation

// What the app redoes after a settings edit, each only when its own keys changed.
public struct SettingsChange: Sendable, Equatable {
    public var hotkey = false
    public var overlayStyle = false
    public var polish = false

    public init(hotkey: Bool = false, overlayStyle: Bool = false, polish: Bool = false) {
        self.hotkey = hotkey
        self.overlayStyle = overlayStyle
        self.polish = polish
    }

    public init(from old: Settings, to new: Settings) {
        hotkey = new.hotkey != old.hotkey
        overlayStyle = new.overlayStyle != old.overlayStyle
        polish = new.polishModel != old.polishModel || new.polishDictations != old.polishDictations
    }
}
