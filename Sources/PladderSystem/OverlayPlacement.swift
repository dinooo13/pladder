import CoreGraphics

// Where the overlay panel rests: above the Dock, and above the focused text field when
// it would otherwise cover it, since agent chats and terminals keep their prompt box at
// the bottom centre too. All rects in AppKit screen coordinates, origin bottom left.
public struct OverlayPlacement: Sendable, Equatable {
    public var screen: CGRect
    public var visible: CGRect
    public var panel: CGSize
    public var pillHeight: CGFloat

    // Never closer than this to the screen's edge, and this far above the Dock.
    static let edgeClearance: CGFloat = 64
    static let dockClearance: CGFloat = 12
    // Between the pill and the top of a field it steps over.
    static let fieldClearance: CGFloat = 10
    // A focused view taller than this share of the screen is a whole terminal or document,
    // and the pill could only leave it by leaving the screen.
    static let largestField: CGFloat = 0.4

    public init(screen: CGRect, visible: CGRect, panel: CGSize, pillHeight: CGFloat) {
        self.screen = screen
        self.visible = visible
        self.panel = panel
        self.pillHeight = pillHeight
    }

    public func frame(avoiding field: CGRect?) -> CGRect {
        let resting = CGRect(
            x: screen.midX - panel.width / 2,
            y: max(screen.minY + Self.edgeClearance, visible.minY + Self.dockClearance),
            width: panel.width,
            height: panel.height)
        guard let field,
              screen.contains(CGPoint(x: field.midX, y: field.midY)),
              field.height <= screen.height * Self.largestField
        else { return resting }
        // The pill is centred in the panel, which is taller to leave room for its shadow.
        let inset = (panel.height - pillHeight) / 2
        guard resting.insetBy(dx: 0, dy: inset).intersects(field) else { return resting }
        let lifted = resting.offsetBy(dx: 0, dy: field.maxY + Self.fieldClearance - inset - resting.minY)
        return lifted.maxY <= visible.maxY ? lifted : resting
    }
}
