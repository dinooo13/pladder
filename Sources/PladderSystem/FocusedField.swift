import AppKit
import ApplicationServices

// Where the text field being dictated into is, so the pill can keep clear of it: agent
// chats and terminals put their prompt box exactly where the pill rests. Read at the
// press, off the main thread, never on the release path.
public enum FocusedField {
    // An app that does not answer must not hold the pill back past its present delay.
    private static let messagingTimeout: Float = 0.1
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    // In AppKit screen coordinates, origin bottom left; nil without Accessibility, for a
    // focus that is not a text field, or when any read fails.
    public static func frame() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        guard let element = element(system, "AXFocusedUIElement") else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let role = value(element, "AXRole") as? String, textRoles.contains(role),
              let origin = point(element, "AXPosition"),
              let size = size(element, "AXSize"),
              size.width > 0, size.height > 0
        else { return nil }
        // AX measures from the top left of the primary screen, AppKit from its bottom left.
        guard let primary = NSScreen.screens.first?.frame else { return nil }
        return CGRect(x: origin.x, y: primary.maxY - origin.y - size.height, width: size.width, height: size.height)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
