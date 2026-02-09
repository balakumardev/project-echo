import Foundation
import os.log
import Metal
import MLX
import MLXLLM
import MLXLMCommon

/// Handles LLM inference for the RAG feature using Apple's MLX framework
/// Supports MLX local models and OpenAI-compatible APIs
///
/// Architecture: Stateless generation (industry standard)
/// - Each request is independent with no shared KV cache
/// - Conversation history is managed externally by the database
/// - This matches how production LLM APIs (OpenAI, Anthropic) work
///
/// Model loading is managed by AIService - this class focuses on generation only
@available(macOS 14.0, *)
public actor LLMEngine {

    // MARK: - Types

    /// Supported LLM backends
    public enum Backend: Sendable {
        /// MLX backend for Apple Silicon optimized inference
        case mlx
        /// OpenAI-compatible API backend
        case openAI(apiKey: String, baseURL: URL?, model: String, temperature: Float)
        /// Google Gemini API backend
        case gemini(apiKey: String, model: String, temperature: Float)
    }

    /// Errors that can occur during LLM operations
    public enum LLMError: Error, LocalizedError {
        case modelNotLoaded
        case generationFailed(String)
        case invalidConfiguration(String)
        case networkError(String)
        case streamingError(String)

        public var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "No model is currently loaded."
            case .generationFailed(let reason):
                return "Generation failed: \(reason)"
            case .invalidConfiguration(let reason):
                return "Invalid configuration: \(reason)"
            case .networkError(let reason):
                return "Network error: \(reason)"
            case .streamingError(let reason):
                return "Streaming error: \(reason)"
            }
        }
    }

    /// A message in the conversation history
    public struct Message: Sendable {
        public let role: Role
        public let content: String

        public enum Role: String, Sendable {
            case system
            case user
            case assistant
        }

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Generation parameters for controlling output
    public struct GenerationParameters: Sendable {
        public let maxTokens: Int
        public let temperature: Float
        public let topP: Float
        public let stopSequences: [String]

        public init(
            maxTokens: Int = 2048,
            temperature: Float = 0.7,
            topP: Float = 0.9,
            stopSequences: [String] = []
        ) {
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.topP = topP
            self.stopSequences = stopSequences
        }

        public static let `default` = GenerationParameters()
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "LLMEngine")

    /// The currently loaded MLX model container (set by AIService)
    /// Used for stateless generation - no session state maintained
    private var modelContainer: ModelContainer?

    /// The current backend configuration
    private var _currentBackend: Backend?

    /// Whether a model is currently loaded and ready
    public private(set) var isModelLoaded: Bool = false

    /// The current backend, if any
    public var currentBackend: Backend? {
        _currentBackend
    }

    /// Check if using MLX local backend
    public var isMLXBackend: Bool {
        switch _currentBackend {
        case .mlx:
            return true
        case .openAI, .gemini, .none:
            return false
        }
    }

    /// URLSession for OpenAI API requests
    private let urlSession: URLSession

    /// URLSession for Gemini API requests (with SOCKS5 proxy)
    private let geminiSession: URLSession

    /// Low power mode - throttles inference to reduce CPU/GPU usage
    /// When enabled, adds small delays between token generations to prevent sustained high load
    private var lowPowerMode: Bool = true  // Default ON to prevent fan noise

    /// Delay between tokens in low power mode (in nanoseconds)
    /// 30ms = moderate throttling, good reduction in fan noise while still reasonable speed
    private let lowPowerDelayNanoseconds: UInt64 = 30_000_000

    // MARK: - Initialization

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)

        let geminiConfig = URLSessionConfiguration.default
        geminiConfig.timeoutIntervalForRequest = 60
        geminiConfig.timeoutIntervalForResource = 300
        geminiConfig.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable: true,
            kCFNetworkProxiesSOCKSProxy: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort: 11111
        ]
        self.geminiSession = URLSession(configuration: geminiConfig)
    }

    /// Enable or disable low power mode
    public func setLowPowerMode(_ enabled: Bool) {
        lowPowerMode = enabled
        logger.info("Low power mode: \(enabled ? "enabled" : "disabled")")
    }

    // MARK: - Backend Configuration (Called by AIService)

    /// Set MLX backend with a pre-loaded model container
    /// This is called by AIService after it has loaded the model
    public func setMLXBackend(_ container: ModelContainer) {
        unload()
        self.modelContainer = container
        self._currentBackend = .mlx
        self.isModelLoaded = true
        logger.info("MLX backend configured (stateless mode)")
    }

    /// Set OpenAI-compatible API backend
    public func setOpenAIBackend(apiKey: String, baseURL: URL?, model: String, temperature: Float = 1.0) {
        unload()
        guard !apiKey.isEmpty else {
            logger.error("Cannot configure OpenAI backend: API key is empty")
            return
        }
        self._currentBackend = .openAI(apiKey: apiKey, baseURL: baseURL, model: model, temperature: temperature)
        self.isModelLoaded = true
        logger.info("OpenAI backend configured with model: \(model), temperature: \(temperature)")
    }

    /// Set Google Gemini API backend
    public func setGeminiBackend(apiKey: String, model: String, temperature: Float = 0.3) {
        unload()
        guard !apiKey.isEmpty else {
            logger.error("Cannot configure Gemini backend: API key is empty")
            return
        }
        self._currentBackend = .gemini(apiKey: apiKey, model: model, temperature: temperature)
        self.isModelLoaded = true
        logger.info("Gemini backend configured with model: \(model), temperature: \(temperature)")
    }

    /// Unload the current backend
    public func unload() {
        modelContainer = nil
        _currentBackend = nil
        isModelLoaded = false
        logger.info("Backend unloaded")
    }

    // MARK: - Generation

    /// Generate a streaming response to a prompt with context
    /// - Parameters:
    ///   - prompt: The user's query
    ///   - context: Retrieved context from the vector database
    ///   - systemPrompt: Optional system prompt to guide the model
    ///   - conversationHistory: Previous messages in the conversation
    ///   - parameters: Generation parameters
    /// - Returns: An AsyncThrowingStream of generated tokens
    public func generateStream(
        prompt: String,
        context: String,
        systemPrompt: String? = nil,
        conversationHistory: [Message] = [],
        parameters: GenerationParameters = .default
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard isModelLoaded, let backend = _currentBackend else {
                        throw LLMError.modelNotLoaded
                    }

                    switch backend {
                    case .mlx:
                        try await generateMLXStream(
                            prompt: prompt,
                            context: context,
                            systemPrompt: systemPrompt,
                            parameters: parameters,
                            continuation: continuation
                        )

                    case .openAI(let apiKey, let baseURL, let model, let temperature):
                        // Use configured temperature, overriding default parameters
                        let openAIParameters = GenerationParameters(
                            maxTokens: parameters.maxTokens,
                            temperature: temperature,
                            topP: parameters.topP,
                            stopSequences: parameters.stopSequences
                        )
                        try await generateOpenAIStream(
                            messages: buildOpenAIMessages(
                                userQuery: prompt,
                                context: context,
                                systemPrompt: systemPrompt,
                                conversationHistory: conversationHistory
                            ),
                            apiKey: apiKey,
                            baseURL: baseURL,
                            model: model,
                            parameters: openAIParameters,
                            continuation: continuation
                        )

                    case .gemini(let apiKey, let model, let temperature):
                        let geminiParameters = GenerationParameters(
                            maxTokens: parameters.maxTokens,
                            temperature: temperature,
                            topP: parameters.topP,
                            stopSequences: parameters.stopSequences
                        )
                        try await generateGeminiStream(
                            prompt: prompt,
                            context: context,
                            systemPrompt: systemPrompt,
                            conversationHistory: conversationHistory,
                            apiKey: apiKey,
                            model: model,
                            parameters: geminiParameters,
                            continuation: continuation
                        )
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Generate a complete (non-streaming) response
    /// - Parameters:
    ///   - prompt: The user's query
    ///   - context: Retrieved context from the vector database
    ///   - systemPrompt: Optional system prompt to guide the model
    ///   - conversationHistory: Previous messages in the conversation
    ///   - parameters: Generation parameters
    /// - Returns: The complete generated response
    public func generate(
        prompt: String,
        context: String,
        systemPrompt: String? = nil,
        conversationHistory: [Message] = [],
        parameters: GenerationParameters = .default
    ) async throws -> String {
        var result = ""

        for try await token in generateStream(
            prompt: prompt,
            context: context,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            parameters: parameters
        ) {
            result += token
        }

        return result
    }

    // MARK: - Private: MLX Generation (Stateless)

    /// Stateless MLX generation using the lower-level generate() API
    ///
    /// Architecture rationale:
    /// - Each request gets a fresh KV cache (cache: nil)
    /// - No session state accumulated between requests
    /// - Matches industry-standard LLM API patterns
    /// - Prevents KVCache corruption from dimension mismatches
    private func generateMLXStream(
        prompt: String,
        context: String,
        systemPrompt: String?,
        parameters: GenerationParameters,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let container = modelContainer else {
            throw LLMError.modelNotLoaded
        }

        // Build the full prompt with context
        let fullPrompt = buildMLXPrompt(
            userQuery: prompt,
            context: context,
            systemPrompt: systemPrompt
        )

        logger.debug("Starting MLX generation (stateless), prompt length: \(fullPrompt.count)")

        do {
            var generatedText = ""

            // Use ModelContainer.perform for thread-safe access to ModelContext
            // This is the recommended pattern from mlx-swift-lm
            try await container.perform { [fullPrompt, parameters] context in
                // Prepare input using the model's processor
                let userInput = UserInput(prompt: fullPrompt)
                let input = try await context.processor.prepare(input: userInput)

                // Convert our parameters to MLX's GenerateParameters
                let mlxParams = MLXLMCommon.GenerateParameters(
                    maxTokens: parameters.maxTokens,
                    temperature: parameters.temperature,
                    topP: parameters.topP
                )

                // Use stateless generation with cache: nil
                // This creates a fresh KV cache for each request - industry standard pattern
                let stream = try MLXLMCommon.generate(
                    input: input,
                    cache: nil,  // Fresh cache each time - stateless!
                    parameters: mlxParams,
                    context: context
                )

                // Process the async stream
                // Note: We need to capture lowPowerMode before entering the perform block
                let isLowPower = self.lowPowerMode
                let delayNs = self.lowPowerDelayNanoseconds

                for await generation in stream {
                    switch generation {
                    case .chunk(let chunk):
                        generatedText += chunk

                        // Check for stop sequences
                        if self.shouldStop(text: generatedText, stopSequences: parameters.stopSequences) {
                            break
                        }

                        continuation.yield(chunk)

                        // Low power mode: add small delay between tokens to reduce sustained CPU/GPU load
                        // This prevents the fans from spinning up during long generations
                        if isLowPower {
                            try? await Task.sleep(nanoseconds: delayNs)
                        }

                    case .info:
                        // Generation complete info - we don't need to do anything special
                        break

                    case .toolCall:
                        // Tool calls not used in this app
                        break
                    }
                }

                // Ensure MLX operations are complete
                Stream().synchronize()
            }

            logger.debug("MLX generation complete, length: \(generatedText.count)")
        } catch {
            logger.error("MLX generation failed: \(error.localizedDescription)")
            throw LLMError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - Private: OpenAI Generation

    private func generateOpenAIStream(
        messages: [[String: String]],
        apiKey: String,
        baseURL: URL?,
        model: String,
        parameters: GenerationParameters,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let endpoint = (baseURL ?? URL(string: "https://api.openai.com")!)
            .appendingPathComponent("v1/chat/completions")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": parameters.maxTokens,
            "temperature": parameters.temperature,
            "stream": true
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.debug("Starting OpenAI stream request to: \(endpoint.absoluteString)")

        let (asyncBytes, response) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            throw LLMError.networkError("HTTP \(httpResponse.statusCode)")
        }

        var generatedText = ""

        for try await line in asyncBytes.lines {
            // Skip empty lines and SSE comments
            guard !line.isEmpty, line.hasPrefix("data: ") else {
                continue
            }

            let data = String(line.dropFirst(6)) // Remove "data: " prefix

            // Check for stream end
            if data == "[DONE]" {
                break
            }

            // Parse JSON chunk
            guard let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }

            generatedText += content

            // Check for stop sequences
            if shouldStop(text: generatedText, stopSequences: parameters.stopSequences) {
                break
            }

            continuation.yield(content)
        }

        logger.debug("OpenAI stream complete, length: \(generatedText.count)")
    }

    // MARK: - Private: Gemini Generation

    private func generateGeminiStream(
        prompt: String,
        context: String,
        systemPrompt: String?,
        conversationHistory: [Message],
        apiKey: String,
        model: String,
        parameters: GenerationParameters,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"

        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("Invalid Gemini endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = buildGeminiRequestBody(
            prompt: prompt,
            context: context,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            parameters: parameters
        )

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.debug("Starting Gemini stream request to model: \(model)")

        let (asyncBytes, response) = try await geminiSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            // Try to read error body
            var errorBody = ""
            for try await line in asyncBytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            throw LLMError.networkError("Gemini HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        var generatedText = ""

        for try await line in asyncBytes.lines {
            // Gemini SSE format: "data: {json}"
            guard !line.isEmpty, line.hasPrefix("data: ") else {
                continue
            }

            let data = String(line.dropFirst(6))

            guard let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? String else {
                continue
            }

            generatedText += text

            if shouldStop(text: generatedText, stopSequences: parameters.stopSequences) {
                break
            }

            continuation.yield(text)
        }

        logger.debug("Gemini stream complete, length: \(generatedText.count)")
    }

    private func buildGeminiRequestBody(
        prompt: String,
        context: String,
        systemPrompt: String?,
        conversationHistory: [Message],
        parameters: GenerationParameters
    ) -> [String: Any] {
        // System instruction
        var systemContent = systemPrompt ?? defaultSystemPrompt
        if !context.isEmpty {
            systemContent += "\n\nRelevant context from the meeting transcript:\n\(context)"
        }

        // Build contents array (conversation history + current prompt)
        var contents: [[String: Any]] = []

        for message in conversationHistory {
            let role: String = message.role == .assistant ? "model" : "user"
            contents.append([
                "role": role,
                "parts": [["text": message.content]]
            ])
        }

        // Current user query
        contents.append([
            "role": "user",
            "parts": [["text": prompt]]
        ])

        var body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemContent]]
            ],
            "contents": contents,
            "generationConfig": [
                "temperature": parameters.temperature,
                "maxOutputTokens": parameters.maxTokens,
                "topP": parameters.topP
            ]
        ]

        if !parameters.stopSequences.isEmpty {
            var genConfig = body["generationConfig"] as! [String: Any]
            genConfig["stopSequences"] = parameters.stopSequences
            body["generationConfig"] = genConfig
        }

        return body
    }

    // MARK: - Private: Prompt Building

    private func buildMLXPrompt(
        userQuery: String,
        context: String,
        systemPrompt: String?
    ) -> String {
        var prompt = ""

        // System prompt with context
        let system = systemPrompt ?? defaultSystemPrompt
        if !context.isEmpty {
            prompt = "\(system)\n\nRelevant context from the meeting transcript:\n\(context)\n\nUser question: \(userQuery)"
        } else {
            prompt = "\(system)\n\nUser question: \(userQuery)"
        }

        return prompt
    }

    private func buildOpenAIMessages(
        userQuery: String,
        context: String,
        systemPrompt: String?,
        conversationHistory: [Message]
    ) -> [[String: String]] {
        var messages: [[String: String]] = []

        // System message with context
        var systemContent = systemPrompt ?? defaultSystemPrompt
        if !context.isEmpty {
            systemContent += "\n\nRelevant context from the meeting transcript:\n\(context)"
        }
        messages.append(["role": "system", "content": systemContent])

        // Conversation history
        for message in conversationHistory {
            messages.append([
                "role": message.role.rawValue,
                "content": message.content
            ])
        }

        // Current user query
        messages.append(["role": "user", "content": userQuery])

        return messages
    }

    private var defaultSystemPrompt: String {
        """
        You are a helpful assistant for Engram, a meeting transcription application. \
        Your role is to answer questions about meeting content based on the provided context. \
        Be concise, accurate, and helpful. If the context doesn't contain enough information \
        to answer the question, say so honestly. Focus on extracting actionable insights, \
        key decisions, and important details from the meetings.
        """
    }

    // MARK: - Private: Utilities

    private func shouldStop(text: String, stopSequences: [String]) -> Bool {
        for sequence in stopSequences where text.contains(sequence) {
            return true
        }
        return false
    }
}

// MARK: - Backend Description

@available(macOS 14.0, *)
extension LLMEngine.Backend: CustomStringConvertible {
    public var description: String {
        switch self {
        case .mlx:
            return "MLX"
        case .openAI(_, let baseURL, let model, _):
            let host = baseURL?.host ?? "api.openai.com"
            return "OpenAI(\(model)@\(host))"
        case .gemini(_, let model, _):
            return "Gemini(\(model))"
        }
    }
}
