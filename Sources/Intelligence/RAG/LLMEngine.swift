import Foundation
import os.log
import Metal
import MLXLLM
import MLXLMCommon

/// Handles LLM inference for the RAG feature using Apple's MLX framework
/// Supports MLX local models and OpenAI-compatible APIs
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
        case openAI(apiKey: String, baseURL: URL?, model: String)
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

    private let logger = Logger(subsystem: "com.projectecho.app", category: "LLMEngine")

    /// The currently loaded MLX model container (set by AIService)
    private var modelContainer: ModelContainer?

    /// Chat session for MLX models
    private var chatSession: ChatSession?

    /// The current backend configuration
    private var _currentBackend: Backend?

    /// Whether a model is currently loaded and ready
    public private(set) var isModelLoaded: Bool = false

    /// The current backend, if any
    public var currentBackend: Backend? {
        _currentBackend
    }

    /// URLSession for OpenAI API requests
    private let urlSession: URLSession

    // MARK: - Initialization

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Backend Configuration (Called by AIService)

    /// Set MLX backend with a pre-loaded model container
    /// This is called by AIService after it has loaded the model
    public func setMLXBackend(_ container: ModelContainer) {
        unload()
        self.modelContainer = container
        self.chatSession = ChatSession(container)
        self._currentBackend = .mlx
        self.isModelLoaded = true
        logger.info("MLX backend configured with pre-loaded model")
    }

    /// Set OpenAI-compatible API backend
    public func setOpenAIBackend(apiKey: String, baseURL: URL?, model: String) {
        unload()
        guard !apiKey.isEmpty else {
            logger.error("Cannot configure OpenAI backend: API key is empty")
            return
        }
        self._currentBackend = .openAI(apiKey: apiKey, baseURL: baseURL, model: model)
        self.isModelLoaded = true
        logger.info("OpenAI backend configured with model: \(model)")
    }

    /// Unload the current backend
    public func unload() {
        chatSession = nil
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

                    case .openAI(let apiKey, let baseURL, let model):
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
                            parameters: parameters,
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

    // MARK: - Private: MLX Generation

    private func generateMLXStream(
        prompt: String,
        context: String,
        systemPrompt: String?,
        parameters: GenerationParameters,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let chatSession = chatSession else {
            throw LLMError.modelNotLoaded
        }

        // Build the full prompt with context
        let fullPrompt = buildMLXPrompt(
            userQuery: prompt,
            context: context,
            systemPrompt: systemPrompt
        )

        logger.debug("Starting MLX generation, prompt length: \(fullPrompt.count)")

        do {
            var generatedText = ""

            // Use ChatSession's streaming API
            for try await chunk in try chatSession.streamResponse(to: fullPrompt) {
                generatedText += chunk

                // Check for stop sequences
                if shouldStop(text: generatedText, stopSequences: parameters.stopSequences) {
                    break
                }

                // Check max tokens (approximate by characters / 4)
                if generatedText.count / 4 >= parameters.maxTokens {
                    logger.debug("Reached approximate max tokens limit")
                    break
                }

                continuation.yield(chunk)
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
            "top_p": parameters.topP,
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
        You are a helpful assistant for Project Echo, a meeting transcription application. \
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
        case .openAI(_, let baseURL, let model):
            let host = baseURL?.host ?? "api.openai.com"
            return "OpenAI(\(model)@\(host))"
        }
    }
}
