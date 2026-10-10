import Carbon.HIToolbox

// Password fields and Terminal's Secure Keyboard Entry turn it on. While it is on, a
// session event tap gets no `keyDown` or `keyUp`, but `flagsChanged` keeps flowing.
public enum SecureInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }
}
