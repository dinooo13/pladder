import PladderCore
import Synchronization

/// The coordinator's one refiner. The coordinator is built once and keeps
/// its refiner for life, while the polish model can be switched at any time,
/// so this hands each call to the model the settings name. The switch is a
/// lock around one reference; the call itself runs outside it.
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
