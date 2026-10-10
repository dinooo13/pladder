import Foundation
import Observation
import PladderCore
import PladderRefine

@MainActor
@Observable
final class PolishModelController {
    // Apple Intelligence can be switched in System Settings while the app runs.
    private(set) var availability: OnDeviceModelAvailability = TranscriptPolisher.availability
    private(set) var status: ModelFileStatus?
    let refiner: PolishRouter

    @ObservationIgnored private let applePolisher = TranscriptPolisher()
    @ObservationIgnored private var s1MiniPolisher: S1MiniPolisher?
    @ObservationIgnored private let files: ModelFiles
    @ObservationIgnored private let statusRelay = MainActorRelay<(ModelFile, ModelFileStatus)>()
    @ObservationIgnored private var chosenFile: ModelFile?
    // A quick polish off and on must not let its cancel reach `files` after its ensure.
    @ObservationIgnored private let fileWork = OrderedTasks()

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
        if let previous = chosenFile, previous != ModelFile(for: model) || !polishing {
            let files = self.files
            fileWork.enqueue { await files.cancel(previous) }
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
        fileWork.enqueue { [weak self] in
            if polishing { await files.ensure(file) }
            let status = await files.status(of: file)
            guard let self, file == self.chosenFile else { return }
            self.status = status
        }
    }

    func retryDownload() {
        guard let file = chosenFile else { return }
        let files = self.files
        fileWork.enqueue { await files.ensure(file) }
    }

    private func releaseS1Mini() {
        guard let polisher = s1MiniPolisher else { return }
        s1MiniPolisher = nil
        Task { await polisher.unload() }
    }
}
