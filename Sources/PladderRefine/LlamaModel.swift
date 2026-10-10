import Foundation
import llama

// Every llama.cpp call runs on one serial queue: a decode blocks its thread for
// hundreds of milliseconds, too long for the cooperative pool, and the context is not
// thread-safe. The fixed prefix is decoded once at load and its cache kept.
final class LlamaModel: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case load
        case tokenize
        case decode(Int32)
        case contextFull
        case timedOut
        case truncated
    }

    // The key-value cache is allocated for all of it up front, about 114 KB a token for
    // Qwen3-0.6B, so it is sized for one chunk, not the model's limit.
    static let contextLength: UInt32 = 2048

    private let queue = DispatchQueue(label: "de.dinooo13.pladder.llama", qos: .userInitiated)
    // Touched on `queue` only.
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let prefix: [llama_token]

    // `deinit` runs only once every stored property is set, so whatever can throw
    // before then frees what is already allocated: the prefix is tokenized before the
    // context and its GPU cache exist.
    private init(path: String, prefix: String) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(path, modelParams) else { throw Failure.load }
        let vocab: OpaquePointer = llama_model_get_vocab(model)
        let prefixTokens: [llama_token]
        do {
            prefixTokens = try Self.tokenize(prefix, vocab: vocab)
        } catch {
            llama_model_free(model)
            throw error
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Self.contextLength
        contextParams.n_batch = Self.contextLength
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw Failure.load
        }
        let sampler: UnsafeMutablePointer<llama_sampler> = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        self.model = model
        self.context = context
        self.vocab = vocab
        self.sampler = sampler
        self.prefix = prefixTokens
        try decode(prefixTokens)
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    static func load(path: String, prefix: String) async throws -> LlamaModel {
        try await withCheckedThrowingContinuation { continuation in
            loadQueue.async {
                continuation.resume(with: Result { try LlamaModel(path: path, prefix: prefix) })
            }
        }
    }

    // The deadline is checked between tokens, so an answer can overrun it by one.
    func complete(suffix: String, maxTokens: Int, deadline: ContinuousClock.Instant) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.completeNow(suffix: suffix, maxTokens: maxTokens, deadline: deadline)
                })
            }
        }
    }

    // MARK: On the queue

    private func completeNow(suffix: String, maxTokens: Int, deadline: ContinuousClock.Instant) throws -> String {
        // Back to the prefix: the previous dictation's tokens go, the prefix's cache stays.
        let memory = llama_get_memory(context)
        if !llama_memory_seq_rm(memory, 0, llama_pos(prefix.count), -1) {
            llama_memory_clear(memory, true)
            try decode(prefix)
        }
        llama_sampler_reset(sampler)

        let input = try Self.tokenize(suffix, vocab: vocab)
        let room = Int(Self.contextLength) - prefix.count - input.count
        guard room > 0 else { throw Failure.contextFull }
        guard ContinuousClock.now < deadline else { throw Failure.timedOut }
        try decode(input)

        var piece = [CChar](repeating: 0, count: 256)
        return try Self.generate(limit: min(maxTokens, room), deadline: deadline) {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { return .end }
            let count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            let bytes = count > 0 ? piece[0..<Int(count)].map { UInt8(bitPattern: $0) } : []
            try withUnsafeMutablePointer(to: &token) { pointer in
                let status = llama_decode(context, llama_batch_get_one(pointer, 1))
                if status != 0 { throw Failure.decode(status) }
            }
            return .piece(bytes)
        }
    }

    enum Step: Equatable {
        case end
        case piece([UInt8])
    }

    // Running out of `limit` is a failure, not a short answer: the cut would fall
    // mid-dictation, and the text as dictated is the better paste.
    static func generate(
        limit: Int, deadline: ContinuousClock.Instant, next: () throws -> Step
    ) throws -> String {
        var bytes: [UInt8] = []
        for _ in 0..<max(limit, 0) {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            switch try next() {
            case .end:
                // A multi-byte character may span two pieces, so decode only the whole answer.
                return String(decoding: bytes, as: UTF8.self)
            case .piece(let piece):
                bytes.append(contentsOf: piece)
            }
        }
        throw Failure.truncated
    }

    private func decode(_ tokens: [llama_token]) throws {
        guard !tokens.isEmpty else { return }
        var tokens = tokens
        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        if status != 0 { throw Failure.decode(status) }
    }

    // Special tokens are parsed, since the chat format is written out by hand; no
    // beginning-of-text token, which the Qwen family does not use.
    static func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString.dropLast())
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), false, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), false, true)
        }
        guard count >= 0 else { throw Failure.tokenize }
        return Array(tokens.prefix(Int(count)))
    }

    // MARK: Process-wide

    // The first run of a llama.cpp build compiles Metal shaders, about seven seconds on
    // an M1; macOS caches them, so only the first launch after an install pays.
    static func warmUp() async {
        await withCheckedContinuation { continuation in
            loadQueue.async {
                _ = backend
                continuation.resume()
            }
        }
    }

    // A queue of their own, so a load never waits behind another model's generation.
    private static let loadQueue = DispatchQueue(label: "de.dinooo13.pladder.llama.load", qos: .userInitiated)

    // llama.cpp's own logging would otherwise print every tensor to stderr.
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()
}
