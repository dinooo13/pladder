import CryptoKit
import Foundation
import PladderCore

/// A model file the polish can download: where it comes from, pinned to a
/// commit so it can never change under us, and the checksum it must match
/// before it is used.
public struct ModelFile: Sendable, Equatable {
    public let fileName: String
    public let url: URL
    public let sha256: String
    public let byteCount: Int64

    /// S1-mini by Superwhisper at 16-bit, from Superwhisper's own repository.
    public static let s1MiniFullPrecision = ModelFile(
        fileName: "s1-mini-f16.gguf",
        url: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-f16.gguf")!,
        sha256: "0370da4f1bae19e3150bcafa33c5d396c15f97bf25519540a3e013db5cc00af4",
        byteCount: 1_509_347_232)

    /// The same weights at Q8_0. Superwhisper publishes only 16-bit and
    /// 4-bit files, and 4-bit lost German and Spanish on the polish set, so
    /// this is mradermacher's quantisation of the same release.
    public static let s1Mini8Bit = ModelFile(
        fileName: "s1-mini.Q8_0.gguf",
        url: URL(string: "https://huggingface.co/mradermacher/s1-mini-GGUF/resolve/f46488282bc2417789271ea5dab6b85c423f9439/s1-mini.Q8_0.gguf")!,
        sha256: "19ddecf5dd46cb37ea13ce78d013c197b39c0bc69b880ea0b3f7c16528ddb52e",
        byteCount: 804_754_240)

    /// The file a polish model needs; nil for Apple's, which ships with macOS.
    public init?(for model: PolishModel) {
        switch model {
        case .appleIntelligence: return nil
        case .s1Mini: self = .s1MiniFullPrecision
        case .s1Mini8Bit: self = .s1Mini8Bit
        }
    }

    /// For the tests, which download a local file, and the CLI, which runs
    /// a model file that is not in the picker.
    public init(fileName: String, url: URL, sha256: String, byteCount: Int64) {
        self.fileName = fileName
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Where a model file stands. The app words it.
public enum ModelFileStatus: Sendable, Equatable {
    case missing
    case downloading(fraction: Double)
    /// Downloaded, the checksum is being computed.
    case verifying
    case ready
    case failed(ModelFileFailure)
}

public enum ModelFileFailure: Error, Sendable, Equatable {
    /// No connection, a server error, or the download stopped.
    case download
    /// The file arrived but is not the one pinned: never used, deleted.
    case checksum
    /// It could not be written, usually a full disk.
    case disk
}

/// The downloaded model files, one directory, one download at a time per
/// file. This is the polish's one network use: the one-time download from
/// Hugging Face, started only when the user picks a model that needs it.
public actor ModelFiles {
    public let directory: URL
    private let onChange: @Sendable (ModelFile, ModelFileStatus) -> Void
    private let transport: any ModelFileTransport
    private var statuses: [String: ModelFileStatus] = [:]
    private var downloads: [String: Download] = [:]
    /// Cancelled downloads still winding down. They clean up the staging
    /// path the next download of the same file writes to, so that one waits.
    private var stopping: [String: Task<Void, Never>] = [:]
    /// What an interrupted download left to pick up from, per file. Memory
    /// only: URLSession's partial file lives in the temporary directory and
    /// is not worth tracking across launches.
    private var resumeData: [String: Data] = [:]

    /// One download under way. The id tells a cancelled download, still
    /// winding down, from the one `ensure` started after it.
    private struct Download {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// `onChange` is called on every status change, off the main actor.
    public init(directory: URL, onChange: @escaping @Sendable (ModelFile, ModelFileStatus) -> Void = { _, _ in }) {
        self.init(directory: directory, transport: URLSessionModelFileTransport(), onChange: onChange)
    }

    /// `transport` stands in for URLSession in the tests.
    init(
        directory: URL, transport: any ModelFileTransport,
        onChange: @escaping @Sendable (ModelFile, ModelFileStatus) -> Void = { _, _ in }
    ) {
        self.directory = directory
        self.transport = transport
        self.onChange = onChange
    }

    /// `~/Library/Application Support/Pladder/Models`, beside the settings.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Pladder/Models")
    }

    public nonisolated func location(of file: ModelFile) -> URL {
        directory.appending(path: file.fileName)
    }

    private nonisolated func staging(of file: ModelFile) -> URL {
        directory.appending(path: file.fileName + ".download")
    }

    /// A file on disk is ready if it has the pinned size: it is only ever
    /// moved into place after its checksum matched, so the size is enough
    /// to catch one cut short or replaced since, without reading 1.5 GB on
    /// every look. Anything else counts as missing and is downloaded again.
    public func status(of file: ModelFile) -> ModelFileStatus {
        if let status = statuses[file.fileName] { return status }
        let attributes = try? FileManager.default.attributesOfItem(atPath: location(of: file).path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        return size == file.byteCount ? .ready : .missing
    }

    /// Starts the download unless the file is there or on its way, so any
    /// number of callers share one download. A failed download is tried
    /// again, from where it stopped when URLSession left resume data.
    public func ensure(_ file: ModelFile) {
        switch status(of: file) {
        case .ready, .downloading, .verifying: return
        case .missing, .failed: break
        }
        let id = UUID()
        set(file, .downloading(fraction: 0))
        downloads[file.fileName] = Download(id: id, task: Task { await self.download(file, id: id) })
    }

    /// Waits for a download `ensure` started; returns the final status.
    public func finished(_ file: ModelFile) async -> ModelFileStatus {
        await downloads[file.fileName]?.task.value
        return status(of: file)
    }

    /// Stops `file`'s download, if one is under way, and forgets it: nothing
    /// is left at the file's location or beside it, and the next `ensure`
    /// starts from the beginning. For the user picking another model or
    /// turning polish off; returns once the download has wound down.
    public func cancel(_ file: ModelFile) async {
        resumeData[file.fileName] = nil
        guard let download = downloads.removeValue(forKey: file.fileName) else { return }
        stopping[file.fileName] = download.task
        statuses[file.fileName] = nil
        onChange(file, status(of: file))
        download.task.cancel()
        await download.task.value
        if stopping[file.fileName] == download.task { stopping[file.fileName] = nil }
    }

    private func set(_ file: ModelFile, _ status: ModelFileStatus) {
        statuses[file.fileName] = status
        onChange(file, status)
    }

    /// Whether the download `id` is still the one for `file`, and not one
    /// `cancel` took back; a stale one changes nothing.
    private func isCurrent(_ file: ModelFile, _ id: UUID) -> Bool {
        downloads[file.fileName]?.id == id
    }

    private func download(_ file: ModelFile, id: UUID) async {
        let staging = staging(of: file)
        defer { if isCurrent(file, id) { downloads[file.fileName] = nil } }
        await stopping[file.fileName]?.value
        guard isCurrent(file, id) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return set(file, .failed(.disk))
        }
        do {
            try await fetch(file, id: id, to: staging)
        } catch {
            // Whatever a stopped fetch wrote is no use; resume data refers to
            // URLSession's own partial file, not this one.
            try? FileManager.default.removeItem(at: staging)
            guard isCurrent(file, id) else { return }
            let failure = error as? ModelFileFetchFailure
            if let data = failure?.resumeData { resumeData[file.fileName] = data }
            return set(file, .failed(failure?.failure ?? .download))
        }
        guard isCurrent(file, id) else {
            try? FileManager.default.removeItem(at: staging)
            return
        }
        // A resumed download is checked like a fresh one: the checksum covers
        // the whole file, whichever way its bytes arrived.
        set(file, .verifying)
        let digest = await Task.detached(priority: .utility) { Self.sha256(of: staging) }.value
        guard isCurrent(file, id), digest == file.sha256 else {
            try? FileManager.default.removeItem(at: staging)
            if isCurrent(file, id) { set(file, .failed(.checksum)) }
            return
        }
        do {
            try? FileManager.default.removeItem(at: location(of: file))
            try FileManager.default.moveItem(at: staging, to: location(of: file))
        } catch {
            return set(file, .failed(.disk))
        }
        statuses[file.fileName] = nil
        onChange(file, .ready)
    }

    /// One fetch into `staging`, from the resume data an earlier interrupted
    /// one left if there is some. A server that refuses the resumed request
    /// (the signed CDN link in the resume data expires) gets one fresh start
    /// before it counts as a failure; a dropped connection does not, since
    /// it would only throw away the new resume data it leaves.
    private func fetch(_ file: ModelFile, id: UUID, to staging: URL) async throws {
        let progress: @Sendable (Int64) -> Void = { [weak self] received in
            Task { await self?.progress(file, id: id, received: received) }
        }
        guard let resume = resumeData.removeValue(forKey: file.fileName) else {
            return try await transport.fetch(file.url, resumingFrom: nil, to: staging, progress: progress)
        }
        do {
            try await transport.fetch(file.url, resumingFrom: resume, to: staging, progress: progress)
        } catch let failure as ModelFileFetchFailure where failure.refused && !Task.isCancelled {
            try await transport.fetch(file.url, resumingFrom: nil, to: staging, progress: progress)
        }
    }

    /// A late report changes nothing: it can arrive after the download moved
    /// on to verifying, or was cancelled.
    private func progress(_ file: ModelFile, id: UUID, received: Int64) {
        guard isCurrent(file, id), case .downloading = statuses[file.fileName], received > 0 else { return }
        set(file, .downloading(fraction: min(1, Double(received) / Double(max(file.byteCount, 1)))))
    }

    /// Streamed, so a 1.5 GB file never sits in memory.
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 16 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Transport

/// Why a fetch stopped.
struct ModelFileFetchFailure: Error, Sendable {
    let failure: ModelFileFailure
    /// URLSession's, when it can pick the download up where it stopped.
    var resumeData: Data? = nil
    /// The server answered with an error status rather than the connection
    /// failing: resume data it was sent is no good, a fresh start may be.
    var refused = false
}

/// How a model file comes over the network. A protocol so the tests can
/// stand in for URLSession; `URLSessionModelFileTransport` is the real one.
protocol ModelFileTransport: Sendable {
    /// Downloads `url` into `staging`, continuing from `resumeData` when
    /// given, and calls `progress` with the bytes received now and then.
    /// Throws `ModelFileFetchFailure`; stops when the calling task is
    /// cancelled.
    func fetch(
        _ url: URL, resumingFrom resumeData: Data?, to staging: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

/// A plain download task, polled for progress.
struct URLSessionModelFileTransport: ModelFileTransport {
    /// The file lands in `staging` before the completion handler returns,
    /// since URLSession deletes its temporary file right after. A cancel of
    /// the calling task cancels the download, and URLSession removes its
    /// partial file with it.
    func fetch(
        _ url: URL, resumingFrom resumeData: Data?, to staging: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let result = AsyncStream<Result<Void, ModelFileFetchFailure>>.makeStream()
        let completion: @Sendable (URL?, URLResponse?, (any Error)?) -> Void = { temporary, response, error in
            // A file URL (the tests) has no status code; a resumed download
            // answers 206, which the range covers.
            let succeeded = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            guard error == nil, let temporary, succeeded else {
                let resume = (error as? URLError)?.downloadTaskResumeData
                result.continuation.yield(.failure(ModelFileFetchFailure(
                    failure: .download, resumeData: resume, refused: error == nil && !succeeded)))
                return
            }
            do {
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.moveItem(at: temporary, to: staging)
                result.continuation.yield(.success(()))
            } catch {
                result.continuation.yield(.failure(ModelFileFetchFailure(failure: .disk)))
            }
        }
        let task = resumeData.map { session.downloadTask(withResumeData: $0, completionHandler: completion) }
            ?? session.downloadTask(with: url, completionHandler: completion)
        let poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                // Woken by the cancel: the download is over.
                guard !Task.isCancelled else { return }
                let received = task.countOfBytesReceived
                if received > 0 { progress(received) }
            }
        }
        defer { poll.cancel() }
        try await withTaskCancellationHandler {
            task.resume()
            for await outcome in result.stream {
                return try outcome.get()
            }
            throw ModelFileFetchFailure(failure: .download)
        } onCancel: {
            task.cancel()
            // Not left to the completion handler, which a task cancelled
            // before it ever started may not get.
            result.continuation.yield(.failure(ModelFileFetchFailure(failure: .download)))
        }
    }
}
