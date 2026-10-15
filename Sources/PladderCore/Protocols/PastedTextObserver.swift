import Foundation

// One watch at a time: a new `observe` ends the one in progress, which then returns
// what it saw. Cancelling the caller does not end a watch; it returns at the latest
// when the observation window passes.
public protocol PastedTextObserver: Sendable {
    func observe(pasted: String) async -> PasteObservation?
}
