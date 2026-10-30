import Foundation
import PladderCore
import PladderTestSupport
import Testing
@testable import Pladder
@testable import PladderRefine

private final class HeldTransport: ModelFileTransport, @unchecked Sendable {
    private let fetches = Recorder<URL>()
    private let cancels = Recorder<URL>()
    var fetched: [URL] { fetches.all }
    var cancelled: [URL] { cancels.all }

    static func received(for url: URL) -> Int64 {
        url == ModelFile.s1Mini8Bit.url ? ModelFile.s1Mini8Bit.byteCount / 4 : ModelFile.s1MiniFullPrecision.byteCount / 4
    }

    func fetch(
        _ url: URL, resumingFrom resumeData: Data?, to staging: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        fetches.append(url)
        progress(Self.received(for: url))
        do {
            // A cancellable sleep stands in for a download that ends only when cancelled.
            try await Task.sleep(for: .seconds(3600))
        } catch {
            cancels.append(url)
            throw error
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PolishModelControllerTests {
    private func controller() throws -> (PolishModelController, HeldTransport) {
        let directory = try scratchDirectory("pladder-polish-controller")
        let transport = HeldTransport()
        let controller = PolishModelController(
            makeFiles: { ModelFiles(directory: directory, transport: transport, onChange: $0) },
            warmUpRuntime: {})
        return (controller, transport)
    }

    private static func quarter(of file: ModelFile) -> ModelFileStatus {
        .downloading(fraction: Double(HeldTransport.received(for: file.url)) / Double(file.byteCount))
    }

    @Test func withPolishOffTheFileIsShownButNotDownloaded() async throws {
        let (c, transport) = try controller()
        c.apply(model: .s1Mini8Bit, polishing: false)
        #expect(await waitUntil { c.status == .missing })
        #expect(transport.fetched.isEmpty)
    }

    @Test func withPolishOnTheChosenFileDownloadsAndReportsProgress() async throws {
        let (c, transport) = try controller()
        c.apply(model: .s1Mini8Bit, polishing: true)
        #expect(await waitUntil { c.status == Self.quarter(of: .s1Mini8Bit) })
        #expect(transport.fetched == [ModelFile.s1Mini8Bit.url])
    }

    @Test func switchingModelsCancelsTheFirstDownload() async throws {
        let (c, transport) = try controller()
        c.apply(model: .s1Mini8Bit, polishing: true)
        #expect(await waitUntil { transport.fetched.count == 1 })
        c.apply(model: .s1Mini, polishing: true)
        #expect(await waitUntil { transport.fetched.count == 2 })
        #expect(await waitUntil { transport.cancelled == [ModelFile.s1Mini8Bit.url] })
        #expect(transport.fetched == [ModelFile.s1Mini8Bit.url, ModelFile.s1MiniFullPrecision.url])
        #expect(await waitUntil { c.status == Self.quarter(of: .s1MiniFullPrecision) })
    }

    @Test func turningPolishOffCancelsTheDownload() async throws {
        let (c, transport) = try controller()
        c.apply(model: .s1Mini8Bit, polishing: true)
        #expect(await waitUntil { transport.fetched.count == 1 })
        c.apply(model: .s1Mini8Bit, polishing: false)
        #expect(await waitUntil { transport.cancelled == [ModelFile.s1Mini8Bit.url] })
        #expect(await waitUntil { c.status == .missing })
    }

    @Test func pickingAppleIntelligenceCancelsTheDownloadAndShowsNoFile() async throws {
        let (c, transport) = try controller()
        c.apply(model: .s1Mini8Bit, polishing: true)
        #expect(await waitUntil { transport.fetched.count == 1 })
        c.apply(model: .appleIntelligence, polishing: true)
        #expect(c.status == nil)
        #expect(await waitUntil { transport.cancelled == [ModelFile.s1Mini8Bit.url] })
        #expect(c.status == nil)
    }
}
