import Foundation
import PladderTestSupport
import Testing
@testable import PladderRefine

// No network: the first three download a local file through the real
// URLSession transport, the rest use a stand-in for it.

/// Stands in for URLSession: every fetch runs `behaviour` with its number
/// (from 1) and the resume data it was given, which are kept.
private actor StandInTransport: ModelFileTransport {
    typealias Behaviour = @Sendable (_ call: Int, _ resume: Data?, _ staging: URL) async throws -> Void

    private(set) var resumes: [Data?] = []
    private let behaviour: Behaviour

    init(_ behaviour: @escaping Behaviour) {
        self.behaviour = behaviour
    }

    func fetch(
        _ url: URL, resumingFrom resumeData: Data?, to staging: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        resumes.append(resumeData)
        try await behaviour(resumes.count, resumeData, staging)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ModelFilesTests {
    private func source(in dir: URL, contents: String) throws -> URL {
        let url = dir.appending(path: "source.bin")
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// "weights", pinned: its SHA-256 and its seven bytes.
    private func weights(in dir: URL) -> ModelFile {
        ModelFile(
            fileName: "model.gguf", url: dir.appending(path: "source.bin"),
            sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c",
            byteCount: 7)
    }

    private func contents(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
    }

    @Test func aDownloadThatMatchesItsChecksumBecomesReady() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try source(in: dir, contents: "weights")
        let file = weights(in: dir)
        let files = ModelFiles(directory: dir.appending(path: "models"))
        #expect(await files.status(of: file) == .missing)
        await files.ensure(file)
        #expect(await files.finished(file) == .ready)
        #expect(try String(contentsOf: files.location(of: file), encoding: .utf8) == "weights")
    }

    @Test func aDownloadThatDoesNotMatchIsDeletedAndNeverUsed() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ModelFile(
            fileName: "model.gguf", url: try source(in: dir, contents: "tampered"),
            sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c",
            byteCount: 8)
        let models = dir.appending(path: "models")
        let files = ModelFiles(directory: models)
        await files.ensure(file)
        #expect(await files.finished(file) == .failed(.checksum))
        #expect(!FileManager.default.fileExists(atPath: files.location(of: file).path))
        #expect(try contents(of: models).isEmpty)
    }

    @Test func aMissingSourceFailsAsADownload() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ModelFile(
            fileName: "model.gguf", url: dir.appending(path: "nowhere.bin"),
            sha256: String(repeating: "0", count: 64), byteCount: 1)
        let files = ModelFiles(directory: dir.appending(path: "models"))
        await files.ensure(file)
        #expect(await files.finished(file) == .failed(.download))
    }

    // Before: any file at the path was ready, a truncated one included,
    // and was handed to llama.cpp.
    @Test func aFileOfTheWrongSizeIsNotReady() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = weights(in: dir)
        let files = ModelFiles(directory: dir)
        try Data("weigh".utf8).write(to: files.location(of: file))
        #expect(await files.status(of: file) == .missing)
        try Data("weights".utf8).write(to: files.location(of: file))
        #expect(await files.status(of: file) == .ready)
    }

    @Test func concurrentEnsuresShareOneDownload() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = weights(in: dir)
        let gate = Gate()
        let transport = StandInTransport { _, _, staging in
            await gate.wait()
            try Data("weights".utf8).write(to: staging)
        }
        let files = ModelFiles(directory: dir.appending(path: "models"), transport: transport)
        async let first: Void = files.ensure(file)
        async let second: Void = files.ensure(file)
        async let third: Void = files.ensure(file)
        _ = await (first, second, third)
        await gate.open()
        #expect(await files.finished(file) == .ready)
        await files.ensure(file)
        #expect(await transport.resumes.count == 1)
    }

    @Test func cancelStopsTheDownloadAndLeavesNothingBehind() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = weights(in: dir)
        let models = dir.appending(path: "models")
        let started = Gate()
        let transport = StandInTransport { call, _, staging in
            if call == 1 {
                // Part of the file, then a wait a cancel ends at once; a
                // cancel that stops nothing sits it out.
                try Data("wei".utf8).write(to: staging)
                await started.open()
                try await Task.sleep(for: .seconds(3))
            }
            try Data("weights".utf8).write(to: staging)
        }
        let statuses = Recorder<ModelFileStatus>()
        let files = ModelFiles(directory: models, transport: transport) { _, status in statuses.append(status) }
        await files.ensure(file)
        await started.wait()
        let cancelled = ContinuousClock.now
        await files.cancel(file)
        #expect(ContinuousClock.now - cancelled < .seconds(1))

        #expect(await files.status(of: file) == .missing)
        #expect(statuses.all.last == .missing)
        #expect(!FileManager.default.fileExists(atPath: files.location(of: file).path))
        #expect(try contents(of: models).isEmpty)

        // The next ensure starts over.
        await files.ensure(file)
        #expect(await files.finished(file) == .ready)
        #expect(await transport.resumes == [nil, nil])
    }

    // Before: the checksum ran to its end on a task of its own, so a cancel
    // while verifying waited for up to 1.5 GB of hashing, and the download
    // of the model picked next queued behind it.
    @Test func cancelReachesTheChecksum() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = weights(in: dir)
        let models = dir.appending(path: "models")
        let transport = StandInTransport { _, _, staging in try Data("weights".utf8).write(to: staging) }
        let started = Recorder<Bool>()
        let cancelled = Recorder<Bool>()
        // A checksum that ends only when cancelled, or after two seconds.
        let files = ModelFiles(directory: models, transport: transport, hash: { _ in
            started.append(true)
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if Task.isCancelled {
                    cancelled.append(true)
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            return nil
        })
        await files.ensure(file)
        #expect(await eventually { !started.all.isEmpty })
        #expect(await files.status(of: file) == .verifying)
        let cancelledAt = ContinuousClock.now
        await files.cancel(file)
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        #expect(cancelled.all == [true])
        #expect(await files.status(of: file) == .missing)
        #expect(try contents(of: models).isEmpty)
    }

    @Test func theChecksumStopsBetweenChunksWhenCancelled() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "abc")
        try Data("abc".utf8).write(to: url)
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(ModelFiles.sha256(of: url, chunkSize: 1) == abc)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ModelFiles.sha256(of: url, chunkSize: 1)
        }
        #expect(await cancelled.value == nil)
    }

    @Test func anInterruptedDownloadResumesWhereItStopped() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = weights(in: dir)
        let halfway = Data("halfway".utf8)
        let transport = StandInTransport { call, _, staging in
            if call == 1 { throw ModelFileFetchFailure(failure: .download, resumeData: halfway) }
            try Data("weights".utf8).write(to: staging)
        }
        let files = ModelFiles(directory: dir.appending(path: "models"), transport: transport)
        await files.ensure(file)
        #expect(await files.finished(file) == .failed(.download))
        await files.ensure(file)
        #expect(await files.finished(file) == .ready)
        #expect(await transport.resumes == [nil, halfway])
    }

    @Test func aResumedDownloadIsStillCheckedBeforeItIsUsed() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = weights(in: dir)
        let models = dir.appending(path: "models")
        let transport = StandInTransport { call, _, staging in
            if call == 1 { throw ModelFileFetchFailure(failure: .download, resumeData: Data("halfway".utf8)) }
            try Data("weightz".utf8).write(to: staging)
        }
        let files = ModelFiles(directory: models, transport: transport)
        await files.ensure(file)
        _ = await files.finished(file)
        await files.ensure(file)
        #expect(await files.finished(file) == .failed(.checksum))
        #expect(try contents(of: models).isEmpty)
    }

    // The resume data points at a signed CDN link that has expired.
    @Test func aResumeTheServerRefusesStartsOverOnce() async throws {
        let dir = try scratchDirectory("ModelFilesTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = weights(in: dir)
        let halfway = Data("halfway".utf8)
        let transport = StandInTransport { call, _, staging in
            switch call {
            case 1: throw ModelFileFetchFailure(failure: .download, resumeData: halfway)
            case 2: throw ModelFileFetchFailure(failure: .download, refused: true)
            default: try Data("weights".utf8).write(to: staging)
            }
        }
        let files = ModelFiles(directory: dir.appending(path: "models"), transport: transport)
        await files.ensure(file)
        _ = await files.finished(file)
        await files.ensure(file)
        #expect(await files.finished(file) == .ready)
        #expect(await transport.resumes == [nil, halfway, nil])
    }
}
