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
    private var statuses: [String: ModelFileStatus] = [:]
    private var downloads: [String: Task<Void, Never>] = [:]

    /// `onChange` is called on every status change, off the main actor.
    public init(directory: URL, onChange: @escaping @Sendable (ModelFile, ModelFileStatus) -> Void = { _, _ in }) {
        self.directory = directory
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

    /// A file on disk is ready: it is only ever moved into place after its
    /// checksum matched.
    public func status(of file: ModelFile) -> ModelFileStatus {
        if let status = statuses[file.fileName] { return status }
        return FileManager.default.fileExists(atPath: location(of: file).path) ? .ready : .missing
    }

    /// Starts the download unless the file is there or on its way. A failed
    /// download is tried again.
    public func ensure(_ file: ModelFile) {
        switch status(of: file) {
        case .ready, .downloading, .verifying: return
        case .missing, .failed: break
        }
        set(file, .downloading(fraction: 0))
        downloads[file.fileName] = Task { await self.download(file) }
    }

    /// Waits for a download `ensure` started; returns the final status.
    public func finished(_ file: ModelFile) async -> ModelFileStatus {
        await downloads[file.fileName]?.value
        return status(of: file)
    }

    private func set(_ file: ModelFile, _ status: ModelFileStatus) {
        statuses[file.fileName] = status
        onChange(file, status)
    }

    private func download(_ file: ModelFile) async {
        defer { downloads[file.fileName] = nil }
        let staging = directory.appending(path: file.fileName + ".download")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return set(file, .failed(.disk))
        }
        do {
            try await fetch(file, to: staging)
        } catch let failure as ModelFileFailure {
            return set(file, .failed(failure))
        } catch {
            return set(file, .failed(.download))
        }
        set(file, .verifying)
        let digest = await Task.detached(priority: .utility) { Self.sha256(of: staging) }.value
        guard digest == file.sha256 else {
            try? FileManager.default.removeItem(at: staging)
            return set(file, .failed(.checksum))
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

    /// A plain download task, polled for progress. The file lands in
    /// `staging` before the completion handler returns, since URLSession
    /// deletes its temporary file right after.
    private func fetch(_ file: ModelFile, to staging: URL) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let task: URLSessionDownloadTask
        let result = AsyncStream<Result<Void, ModelFileFailure>>.makeStream()
        task = session.downloadTask(with: file.url) { temporary, response, error in
            // A file URL (the tests) has no status code.
            let succeeded = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            guard error == nil, let temporary, succeeded else {
                result.continuation.yield(.failure(.download))
                return
            }
            do {
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.moveItem(at: temporary, to: staging)
                result.continuation.yield(.success(()))
            } catch {
                result.continuation.yield(.failure(.disk))
            }
        }
        task.resume()
        let progress = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                // Woken by the cancel: the download is over, and a late
                // report would overwrite what came after it.
                guard !Task.isCancelled else { return }
                let received = task.countOfBytesReceived
                if received > 0 {
                    set(file, .downloading(fraction: min(1, Double(received) / Double(file.byteCount))))
                }
            }
        }
        defer { progress.cancel() }
        for await outcome in result.stream {
            try outcome.get()
            return
        }
        throw ModelFileFailure.download
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
