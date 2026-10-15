import Carbon.HIToolbox

// While it is on, a session event tap gets no `keyDown` or `keyUp`, but `flagsChanged`
// keeps flowing.
public enum SecureInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }
}
