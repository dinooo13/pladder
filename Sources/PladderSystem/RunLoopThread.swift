import Foundation

/// A thread that does nothing but run a run loop. Work is handed to it as
/// blocks, which is how the hotkey tap and the AX observer get installed and
/// removed on the same thread whose run loop they live on.
final class RunLoopThread: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var loop: CFRunLoop?

    init(name: String, qualityOfService: QualityOfService) {
        super.init()
        self.name = name
        self.qualityOfService = qualityOfService
    }

    override func main() {
        condition.lock()
        loop = CFRunLoopGetCurrent()
        condition.broadcast()
        condition.unlock()
        // A run loop with nothing to watch returns straight away; what it
        // watches only arrives later, so keep a port on it until told to stop.
        RunLoop.current.add(NSMachPort(), forMode: .common)
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        condition.lock()
        while loop == nil { condition.wait() }
        let loop = loop!
        condition.unlock()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    /// Does not wait for the loop the way `perform` does: a thread cancelled
    /// before it got going never runs `main`, and would never publish one.
    func finish() {
        cancel()
        condition.lock()
        let loop = loop
        condition.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
        CFRunLoopWakeUp(loop)
    }
}
