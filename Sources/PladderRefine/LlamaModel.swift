import Foundation
import llama

/// One GGUF model and one context on llama.cpp, generating greedily.
///
/// Every llama.cpp call runs on the model's own serial queue: a decode blocks
/// its thread for hundreds of milliseconds, which must not happen on Swift's
/// cooperative pool, and the context is not thread-safe. Callers await.
///
/// The prompt is split into a fixed prefix (the system prompt and whatever
/// never changes) and the part that does. The prefix is decoded once, at
/// load, and its key-value cache kept, so a dictation only pays for its own
/// tokens.
final class LlamaModel: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case load
        case tokenize
        case decode(Int32)
        case contextFull
        case timedOut
    }

    /// Context length in tokens. The key-value cache is allocated for all of
    /// it up front (about 114 KB a token for Qwen3-0.6B), so it is sized for
    /// one chunk of a long dictation, in and out, not for the model's limit.
    static let contextLength: UInt32 = 2048

    private let queue = DispatchQueue(label: "de.dinooo13.pladder.llama", qos: .userInitiated)
    // Touched on `queue` only.
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let prefix: [llama_token]

    /// Loads the model onto the GPU and decodes `prefix`. Blocking; call from
    /// `load(path:prefix:)`.
    private init(path: String, prefix: String) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(path, modelParams) else { throw Failure.load }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Self.contextLength
        contextParams.n_batch = Self.contextLength
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw Failure.load
        }
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        self.prefix = try Self.tokenize(prefix, vocab: vocab)
        try decode(self.prefix)
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    /// Loads `path` and decodes `prefix` off the caller's thread.
    static func load(path: String, prefix: String) async throws -> LlamaModel {
        try await withCheckedThrowingContinuation { continuation in
            loadQueue.async {
                continuation.resume(with: Result { try LlamaModel(path: path, prefix: prefix) })
            }
        }
    }

    /// Greedy continuation of the prefix with `suffix`, up to an end-of-turn
    /// token, `maxTokens` or `deadline`, whichever comes first. The deadline
    /// is checked between tokens, so an answer can overrun it by one token.
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
        // Back to the prefix: the previous dictation's tokens go, the
        // prefix's cache stays.
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

        var bytes: [CChar] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<min(maxTokens, room) {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if count > 0 { bytes.append(contentsOf: piece[0..<Int(count)]) }
            try withUnsafeMutablePointer(to: &token) { pointer in
                let status = llama_decode(context, llama_batch_get_one(pointer, 1))
                if status != 0 { throw Failure.decode(status) }
            }
        }
        // Pieces are bytes; a multi-byte character may span two of them, so
        // the text is only decoded once it is whole.
        return String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func decode(_ tokens: [llama_token]) throws {
        guard !tokens.isEmpty else { return }
        var tokens = tokens
        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        if status != 0 { throw Failure.decode(status) }
    }

    /// Special tokens such as `<|im_start|>` are parsed, since the chat
    /// format is written out by hand; no beginning-of-text token is added,
    /// which the Qwen family does not use.
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

    /// Sets up the backends ahead of the first load. The first time a build
    /// of llama.cpp runs, Metal compiles its shaders, about seven seconds on
    /// an M1; macOS caches them after that, so only the first launch after
    /// an install or update pays, and with this it pays in the background.
    static func warmUp() async {
        await withCheckedContinuation { continuation in
            loadQueue.async {
                _ = backend
                continuation.resume()
            }
        }
    }

    /// Loads are rare and slow; they get a queue of their own so a load never
    /// waits behind another model's generation.
    private static let loadQueue = DispatchQueue(label: "de.dinooo13.pladder.llama.load", qos: .userInitiated)

    /// Once per process, before the first model: the backends, and llama.cpp's
    /// own logging, which would otherwise print every tensor to stderr.
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()
}
