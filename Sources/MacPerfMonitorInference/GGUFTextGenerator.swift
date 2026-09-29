import Darwin
import Foundation
import MacPerfMonitorCore
import llama

struct LocalTextGeneration: Sendable {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
}

protocol LocalTextGenerating: Sendable {
    var peakMemoryBytes: Int { get async }
    func generate(
        instructions: String, prompt: String, maximumTokens: Int, temperature: Float
    ) async throws -> LocalTextGeneration
}

actor GGUFTextGenerator: LocalTextGenerating {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private let watchdog: DispatchSourceTimer
    private static let maximumMemoryBytes = 8 * 1024 * 1024 * 1024
    private static let maximumOutputBytes = 16384
    private static let batchSize = 128

    init(file: URL) throws {
        try Self.checkResources()
        llama_backend_init()
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now(), repeating: 1)
        watchdog.setEventHandler {
            do { try Self.checkResources() } catch { _exit(75) }
        }
        watchdog.resume()
        var params = llama_model_default_params()
        params.n_gpu_layers = -1
        params.load_mode = LLAMA_LOAD_MODE_MMAP
        params.progress_callback = { _, _ in (try? GGUFTextGenerator.checkResources()) != nil }
        guard let model = llama_model_load_from_file(file.path, params) else {
            watchdog.cancel()
            llama_backend_free()
            try Self.checkResources()
            throw AskExplanationError.workerFailed
        }
        var options = llama_context_default_params()
        options.n_ctx = UInt32(AskLocalModelPolicy.maximumContextTokens)
        options.n_batch = UInt32(Self.batchSize)
        options.n_ubatch = UInt32(Self.batchSize)
        options.n_threads = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        options.n_threads_batch = options.n_threads
        options.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        options.abort_callback = { _ in (try? GGUFTextGenerator.checkResources()) == nil }
        guard let vocabulary = llama_model_get_vocab(model),
            let context = llama_init_from_model(model, options)
        else {
            llama_model_free(model)
            watchdog.cancel()
            llama_backend_free()
            throw AskExplanationError.workerFailed
        }
        self.model = model
        self.context = context
        self.vocabulary = vocabulary
        self.watchdog = watchdog
    }

    deinit {
        watchdog.cancel()
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    var peakMemoryBytes: Int { Self.residentPeak() }

    func generate(
        instructions: String, prompt: String, maximumTokens: Int, temperature: Float
    ) async throws -> LocalTextGeneration {
        try Self.checkResources()
        try Task.checkCancellation()
        let formatted = try Self.format(instructions: instructions, prompt: prompt)
        var tokens = try tokenize(formatted)
        let budget = AskContextBudget(
            reportedSize: Int(llama_n_ctx(context)),
            maximumContext: AskLocalModelPolicy.maximumContextTokens)
        guard budget.admits(inputTokens: tokens.count), maximumTokens > 0,
            maximumTokens <= AskContextBudget.answerReserve
        else { throw AskExplanationError.contextLimit }
        llama_memory_clear(llama_get_memory(context), true)
        defer { llama_memory_clear(llama_get_memory(context), true) }
        let sampler = try makeSampler(temperature: temperature)
        defer { llama_sampler_free(sampler) }
        try tokens.withUnsafeMutableBufferPointer { buffer in
            for offset in stride(from: 0, to: buffer.count, by: Self.batchSize) {
                try Self.checkResources()
                try Task.checkCancellation()
                let count = min(Self.batchSize, buffer.count - offset)
                let batch = llama_batch_get_one(
                    buffer.baseAddress!.advanced(by: offset), Int32(count))
                guard llama_decode(context, batch) == 0 else {
                    throw AskExplanationError.workerFailed
                }
            }
        }
        var output = Data()
        var generated = 0
        for _ in 0..<maximumTokens {
            try Self.checkResources()
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            output.append(try piece(for: token))
            generated += 1
            guard output.count <= Self.maximumOutputBytes else {
                throw AskExplanationError.invalidAnswer
            }
            let decoded = withUnsafeMutablePointer(to: &token) {
                llama_decode(context, llama_batch_get_one($0, 1))
            }
            guard decoded == 0 else { throw AskExplanationError.workerFailed }
        }
        guard let text = String(data: output, encoding: .utf8) else {
            throw AskExplanationError.invalidAnswer
        }
        return LocalTextGeneration(text: text, inputTokens: tokens.count, outputTokens: generated)
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        try text.withCString { pointer in
            let required = llama_tokenize(
                vocabulary, pointer, Int32(text.utf8.count), nil, 0, true, true)
            guard required < 0, required >= -Int32(AskLocalModelPolicy.maximumContextTokens) else {
                throw AskExplanationError.contextLimit
            }
            var tokens = [llama_token](repeating: 0, count: Int(-required))
            let count = llama_tokenize(
                vocabulary, pointer, Int32(text.utf8.count), &tokens, Int32(tokens.count), true,
                true)
            guard count == tokens.count else { throw AskExplanationError.workerFailed }
            return tokens
        }
    }

    private func piece(for token: llama_token) throws -> Data {
        var bytes = [CChar](repeating: 0, count: 256)
        var count = llama_token_to_piece(vocabulary, token, &bytes, Int32(bytes.count), 0, false)
        if count < 0 {
            guard count >= -Int32(Self.maximumOutputBytes) else {
                throw AskExplanationError.invalidAnswer
            }
            bytes = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocabulary, token, &bytes, Int32(bytes.count), 0, false)
        }
        guard count >= 0, count <= bytes.count else { throw AskExplanationError.invalidAnswer }
        return bytes.withUnsafeBytes { Data($0.prefix(Int(count))) }
    }

    private func makeSampler(temperature: Float) throws -> UnsafeMutablePointer<llama_sampler> {
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw AskExplanationError.workerFailed
        }
        guard let grammar = llama_sampler_init_grammar(vocabulary, Self.jsonGrammar, "root") else {
            llama_sampler_free(chain)
            throw AskExplanationError.workerFailed
        }
        llama_sampler_chain_add(chain, grammar)
        if temperature > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(20))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.8, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(42))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        }
        return chain
    }

    private static func format(instructions: String, prompt: String) throws -> String {
        let instructions =
            instructions
            + "\nRespond directly with the requested JSON object inside Answer. Do not generate stage tags, analysis, code, or execution requests. There is no code interpreter."
        let capacity = instructions.utf8.count + prompt.utf8.count + 1024
        guard capacity <= 131072 else { throw AskExplanationError.contextLimit }
        var buffer = [CChar](repeating: 0, count: capacity)
        let written = "system".withCString { systemRole in
            "user".withCString { userRole in
                instructions.withCString { systemText in
                    prompt.withCString { userText in
                        let messages = [
                            llama_chat_message(role: systemRole, content: systemText),
                            llama_chat_message(role: userRole, content: userText),
                        ]
                        return llama_chat_apply_template(
                            "deepseek3", messages, messages.count, true, &buffer,
                            Int32(buffer.count))
                    }
                }
            }
        }
        guard written > 0, written < buffer.count,
            let text = buffer.withUnsafeBytes({
                String(data: Data($0.prefix(Int(written))), encoding: .utf8)
            })
        else { throw AskExplanationError.workerFailed }
        return text + "<Analyze>\n</Analyze>\n<Answer>\n"
    }

    private static let jsonGrammar = #"""
        root ::= object
        value ::= object | array | string | number | ("true" | "false" | "null") ws
        object ::= "{" ws (string ":" ws value ("," ws string ":" ws value)*)? "}" ws
        array ::= "[" ws (value ("," ws value)*)? "]" ws
        string ::= "\"" ([^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\"" ws
        number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)? ws
        ws ::= [ \t\n\r]{0,4}
        """#

    private static func residentPeak() -> Int {
        var usage = rusage()
        return getrusage(RUSAGE_SELF, &usage) == 0 ? Int(usage.ru_maxrss) : Int.max
    }

    private static func checkResources() throws {
        try InferenceMain.checkResources()
        guard residentPeak() < maximumMemoryBytes else {
            throw AskExplanationError.resourcePressure
        }
    }

    static func checkRuntime() throws {
        llama_backend_init()
        defer { llama_backend_free() }
        guard llama_supports_gpu_offload() else { throw AskExplanationError.workerFailed }
        let prompt = try format(instructions: "Return JSON.", prompt: "Synthetic runtime check.")
        guard prompt.contains("Synthetic runtime check."), prompt.hasSuffix("<Answer>\n") else {
            throw AskExplanationError.workerFailed
        }
    }
}
