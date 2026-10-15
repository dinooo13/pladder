import PladderCore
import Synchronization

// The coordinator keeps its refiner for life, while the model can be switched at any
// time. The call itself runs outside the lock.
final class PolishRouter: TranscriptRefiner {
    private let current: Mutex<any TranscriptRefiner>

    init(_ initial: any TranscriptRefiner) {
        current = Mutex(initial)
    }

    func use(_ refiner: any TranscriptRefiner) {
        current.withLock { $0 = refiner }
    }

    func prepare() async {
        await current.withLock { $0 }.prepare()
    }

    func refine(_ text: String) async -> String? {
        await current.withLock { $0 }.refine(text)
    }
}
