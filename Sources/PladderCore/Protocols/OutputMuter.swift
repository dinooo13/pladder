import Foundation

// Start and end run on tasks nothing orders, so an end can arrive first; the
// session number lets the muter tell a late start from a live one.
public protocol OutputMuter: Sendable {
    func recordingStarted(session: Int) async
    func recordingEnded(session: Int) async

}

// Element 0 is the device's master mute, 1 and up its channels. Per element, since
// a user can mute one channel of a pair and a restore must put back exactly that.
public struct MuteState: Sendable, Equatable {
    public var elements: [UInt32: Bool]

    public init(_ elements: [UInt32: Bool]) {
        self.elements = elements
    }
}

public protocol OutputMuteControl: Sendable {
    func defaultOutputDevice() -> UInt32?
    func muteState(of device: UInt32) -> MuteState?
    // Tries every element before throwing the first failure, so a restore puts back
    // as much as it can.
    func apply(_ state: MuteState, to device: UInt32) throws
}
