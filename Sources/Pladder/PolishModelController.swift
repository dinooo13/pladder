import Foundation
import Observation
import PladderCore
import PladderRefine

/// Points the coordinator's refiner at the polish model the settings name,
/// and owns that model's file and memory.
///
/// An S1-mini file is downloaded only while polish is on and that model is
/// chosen, the one network use besides the speech model's; it is loaded at
/// the first key-down, not here, and freed when polish goes off or another
/// model is picked. Only one S1-mini polisher is ever held, so switching
/// frees the other's memory.
@MainActor
@Observable
final class PolishModelController {
    /// Whether Apple Intelligence can polish right now, for the polish
    /// toggle's row. Refreshed with the permissions: it can be switched on
    /// or off in System Settings while the app runs, and the read is cheap.
    /// The coordinator never asks; an unavailable model makes the toggle a
    /// no-op that pastes as dictated.
    private(set) var availability: OnDeviceModelAvailability = TranscriptPolisher.availability
    /// Where the chosen model's file stands; nil for Apple's, which has none.
    /// Shown under the model picker.
    private(set) var status: ModelFileStatus?

    /// The coordinator's one refiner; forwards to the chosen model.
    let refiner: PolishRouter

    @ObservationIgnored private let applePolisher = TranscriptPolisher()
    @ObservationIgnored private var s1MiniPolisher: S1MiniPolisher?
    @ObservationIgnored private let files: ModelFiles
    @ObservationIgnored private let statusRelay = MainActorRelay<(ModelFile, ModelFileStatus)>()
    /// The file the settings name, nil for Apple's model.
    @ObservationIgnored private var chosenFile: ModelFile?

    init() {
        refiner = PolishRouter(applePolisher)
        let relay = statusRelay
        files = ModelFiles(directory: ModelFiles.defaultDirectory) { file, status in
            relay.send((file, status))
        }
        statusRelay.handler = { [weak self] update in
            guard let self, update.0 == self.chosenFile else { return }
            self.status = update.1
        }
    }

    func refreshAvailability() {
        let current = TranscriptPolisher.availability
        if current != availability { availability = current }
    }

    func apply(model: PolishModel, polishing: Bool) {
        // A download nobody will use any more stops: the user picked another
        // model, or turned polish off before it finished.
        if let previous = chosenFile, previous != ModelFile(for: model) || !polishing {
            let files = self.files
            Task { await files.cancel(previous) }
        }
        guard let file = ModelFile(for: model) else {
            chosenFile = nil
            releaseS1Mini()
            refiner.use(applePolisher)
            status = nil
            return
        }
        chosenFile = file
        if s1MiniPolisher?.file != file {
            releaseS1Mini()
            let polisher = S1MiniPolisher(file: file, location: files.location(of: file))
            s1MiniPolisher = polisher
            refiner.use(polisher)
        }
        if polishing {
            Task.detached(priority: .utility) { await S1MiniPolisher.warmUpRuntime() }
        } else if let polisher = s1MiniPolisher {
            Task { await polisher.unload() }
        }
        let files = self.files
        Task { [weak self] in
            if polishing { await files.ensure(file) }
            let status = await files.status(of: file)
            guard let self, file == self.chosenFile else { return }
            self.status = status
        }
    }

    /// Tries a failed download again; the picker's "Try Again".
    func retryDownload() {
        guard let file = chosenFile else { return }
        let files = self.files
        Task { await files.ensure(file) }
    }

    private func releaseS1Mini() {
        guard let polisher = s1MiniPolisher else { return }
        s1MiniPolisher = nil
        Task { await polisher.unload() }
    }
}
