import Foundation
import os.log
import Metal
import MLXLLM
import MLXLMCommon
import Database

/// Unified AI service managing all AI state and operations
/// Single source of truth for model status, loading, and inference
@available(macOS 14.0, *)
public actor AIService {

    // MARK: - Singleton

    public static let shared = AIService()

    // MARK: - Types

    /// Current status of the AI service
    public enum Status: Sendable, Equatable {
        case notConfigured
        case downloading(progress: Double, modelName: String)
        case loading(modelName: String)
        case ready(modelName: String)
        case error(message: String)

        public static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.notConfigured, .notConfigured):
                return true
            case (.downloading(let p1, let m1), .downloading(let p2, let m2)):
                return p1 == p2 && m1 == m2
            case (.loading(let m1), .loading(let m2)):
                return m1 == m2
            case (.ready(let m1), .ready(let m2)):
                return m1 == m2
            case (.error(let e1), .error(let e2)):
                return e1 == e2
            default:
                return false
            }
        }
    }

    /// AI provider type
    public enum Provider: String, Sendable, CaseIterable, Codable {
        case localMLX = "local-mlx"
        case openAICompatible = "openai"
    }

    /// Memory check result
    public enum MemoryCheckResult: Sendable {
        case sufficient
        case insufficient(available: Double, required: Double)
        case unknown
    }

    /// Errors specific to AIService
    public enum AIError: Error, LocalizedError {
        case notInitialized
        case modelNotFound(String)
        case insufficientMemory(available: Double, required: Double)
        case metalNotAvailable
        case loadFailed(String)
        case openAINotConfigured

        public var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "AI service not initialized"
            case .modelNotFound(let id):
                return "Model not found: \(id)"
            case .insufficientMemory(let available, let required):
                return "Insufficient memory: \(String(format: "%.1f", available))GB available, \(String(format: "%.1f", required))GB required"
            case .metalNotAvailable:
                return "Metal is not available. This Mac doesn't support local AI models."
            case .loadFailed(let reason):
                return "Failed to load model: \(reason)"
            case .openAINotConfigured:
                return "OpenAI API not configured. Please add your API key in settings."
            }
        }
    }

    // MARK: - Published State

    /// Current service status
    public private(set) var status: Status = .notConfigured

    /// Current provider
    public private(set) var provider: Provider = .localMLX

    /// Number of indexed recordings
    public private(set) var indexedRecordingsCount: Int = 0

    // MARK: - Configuration

    /// Persistent configuration
    public struct Config: Codable, Sendable {
        public var provider: Provider = .localMLX
        public var selectedModelId: String = "mlx-community/gemma-2-2b-it-4bit"
        public var openAIKey: String = ""
        public var openAIBaseURL: String = ""
        public var openAIModel: String = "gpt-4o-mini"
        public var autoIndexTranscripts: Bool = true

        public init() {}
    }

    private var config: Config = Config()

    // MARK: - Components

    private let logger = Logger(subsystem: "com.projectecho.app", category: "AIService")
    private let fileManager = FileManager.default

    /// MLX model container (when using local MLX)
    private var modelContainer: ModelContainer?

    /// Chat session for MLX
    private var chatSession: ChatSession?

    /// LLM engine for generation
    private var llmEngine: LLMEngine?

    /// Embedding engine for RAG
    private var embeddingEngine: EmbeddingEngine?

    /// RAG pipeline
    private var ragPipeline: RAGPipeline?

    /// Database manager
    private var databaseManager: DatabaseManager?

    /// URLSession for OpenAI
    private let urlSession: URLSession

    /// Whether the service has been initialized
    private var isInitialized = false

    /// Whether initialization is in progress
    private var isInitializing = false

    /// Whether a model setup is currently in progress
    private var isSettingUp = false

    // MARK: - Initialization

    private init() {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 60
        sessionConfig.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: sessionConfig)

        // Load config synchronously in init (accessing UserDefaults is thread-safe)
        if let data = UserDefaults.standard.data(forKey: "AIService.config"),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            self.config = decoded
            self.provider = decoded.provider
        }
    }

    // MARK: - Public API: Initialization

    /// Initialize the AI service - call on app launch
    /// This sets up components but doesn't load models
    public func initialize() async throws {
        guard !isInitialized else {
            logger.info("AI service already initialized")
            return
        }

        // Already initializing - wait for it (up to 2 minutes)
        if isInitializing {
            logToFile("[AIService] Initialization already in progress, waiting...")
            for _ in 0..<240 {  // 240 * 0.5s = 120 seconds
                try await Task.sleep(nanoseconds: 500_000_000)
                if isInitialized {
                    logToFile("[AIService] Init completed while waiting")
                    return
                }
                if !isInitializing { break }
            }
            return
        }

        isInitializing = true
        defer { isInitializing = false }

        logger.info("Initializing AI service...")

        // Initialize database manager
        databaseManager = try await DatabaseManager()

        // Initialize embedding engine (uses Apple's NLContextualEmbedder - no download needed)
        embeddingEngine = EmbeddingEngine()
        try await embeddingEngine?.loadModel()

        // Initialize LLM engine
        llmEngine = LLMEngine()

        // Initialize RAG pipeline
        if let db = databaseManager, let embedding = embeddingEngine, let llm = llmEngine {
            ragPipeline = RAGPipeline(
                databaseManager: db,
                embeddingEngine: embedding,
                llmEngine: llm
            )
            try await ragPipeline?.initialize()
        }

        isInitialized = true
        print("[AIService] Initialize complete - ragPipeline: \(ragPipeline != nil)")

        // Check if we have a previously selected model that's cached
        if provider == .localMLX && isModelCached(config.selectedModelId) {
            // Don't auto-load - let user trigger it
            logger.info("Found cached model: \(self.config.selectedModelId)")
        }

        // Update indexing count
        await refreshIndexingStatus()
        print("[AIService] Indexed recordings count: \(indexedRecordingsCount)")

        logger.info("AI service initialized")
    }

    // MARK: - Public API: Model Setup

    /// Setup a local MLX model (downloads if needed, then loads)
    /// This is the MAIN method for getting a model ready
    public func setupModel(_ modelId: String) async throws {
        // Prevent multiple simultaneous setup calls
        guard !isSettingUp else {
            print("[AIService] setupModel already in progress, ignoring call for: \(modelId)")
            return
        }
        isSettingUp = true
        defer { isSettingUp = false }

        print("[AIService] setupModel called for: \(modelId)")
        logger.info("Setting up model: \(modelId)")

        // Ensure initialized
        if !isInitialized {
            print("[AIService] Not initialized, calling initialize()...")
            try await initialize()
            print("[AIService] Initialization complete")
        }

        // Validate model exists in registry
        guard let modelInfo = ModelRegistry.model(for: modelId) else {
            print("[AIService] ERROR: Model not found in registry: \(modelId)")
            throw AIError.modelNotFound(modelId)
        }
        print("[AIService] Model found in registry: \(modelInfo.displayName)")

        // Check Metal availability
        guard MTLCreateSystemDefaultDevice() != nil else {
            print("[AIService] ERROR: Metal not available")
            status = .error(message: "Metal not available")
            throw AIError.metalNotAvailable
        }
        print("[AIService] Metal is available")

        // Check memory availability (note: this checks disk space, not RAM)
        let memoryCheck = checkMemoryAvailability(for: modelId)
        if case .insufficient(let available, let required) = memoryCheck {
            // Suggest a smaller model
            let suggestion = ModelRegistry.suggestSmallerModel(availableGB: available)
            let message = suggestion != nil
                ? "Not enough memory. Try \(suggestion!.displayName) instead."
                : "Not enough memory (\(String(format: "%.1f", available))GB available, \(String(format: "%.1f", required))GB needed)"
            print("[AIService] ERROR: Insufficient memory - \(message)")
            status = .error(message: message)
            throw AIError.insufficientMemory(available: available, required: required)
        }
        print("[AIService] Memory check passed")

        // Update status based on cache state
        let cached = isModelCached(modelId)
        print("[AIService] Model cached: \(cached)")
        if cached {
            status = .loading(modelName: modelInfo.displayName)
        } else {
            status = .downloading(progress: 0.0, modelName: modelInfo.displayName)
        }

        do {
            // MLX's loadModelContainer handles BOTH download and load
            // If model is not cached, it downloads from HuggingFace first
            print("[AIService] Calling loadModelContainer for: \(modelId)")
            logger.info("Calling loadModelContainer for: \(modelId)")

            // Update status to show we're working
            if !cached {
                // Show indeterminate progress since MLX doesn't give us granular progress
                status = .downloading(progress: 0.5, modelName: modelInfo.displayName)
            }

            let container = try await MLXLMCommon.loadModelContainer(id: modelId)
            print("[AIService] loadModelContainer completed successfully")

            status = .loading(modelName: modelInfo.displayName)

            // Store the container
            self.modelContainer = container
            print("[AIService] Stored model container")

            // Create chat session
            self.chatSession = ChatSession(container)
            print("[AIService] Created chat session")

            // Configure LLM engine with MLX backend
            if let engine = llmEngine {
                await engine.setMLXBackend(container)
                print("[AIService] Configured LLM engine")
            } else {
                print("[AIService] WARNING: llmEngine is nil")
            }

            // Save config
            config.selectedModelId = modelId
            config.provider = .localMLX
            provider = .localMLX
            saveConfig()

            status = .ready(modelName: modelInfo.displayName)
            print("[AIService] Model ready: \(modelId)")
            logger.info("Model ready: \(modelId)")

        } catch {
            print("[AIService] ERROR in setupModel: \(error)")
            print("[AIService] Error type: \(type(of: error))")
            print("[AIService] Error localizedDescription: \(error.localizedDescription)")
            let errorMessage = parseMLXError(error, modelId: modelId)
            status = .error(message: errorMessage)
            logger.error("Failed to setup model: \(errorMessage)")
            throw AIError.loadFailed(errorMessage)
        }
    }

    /// Configure OpenAI-compatible API backend
    public func configureOpenAI(apiKey: String, baseURL: String?, model: String) async throws {
        logger.info("Configuring OpenAI backend")

        // Ensure initialized
        if !isInitialized {
            try await initialize()
        }

        guard !apiKey.isEmpty else {
            throw AIError.openAINotConfigured
        }

        // Unload any MLX model
        unloadMLXModel()

        // Configure OpenAI backend on LLM engine
        let baseURLParsed = baseURL.flatMap { URL(string: $0) }
        await llmEngine?.setOpenAIBackend(apiKey: apiKey, baseURL: baseURLParsed, model: model)

        // Save config
        config.provider = .openAICompatible
        config.openAIKey = apiKey
        config.openAIBaseURL = baseURL ?? ""
        config.openAIModel = model
        saveConfig()

        provider = .openAICompatible
        status = .ready(modelName: model)

        logger.info("OpenAI backend configured: \(model)")
    }

    /// Switch between providers
    public func setProvider(_ newProvider: Provider) async throws {
        guard newProvider != provider else { return }

        logger.info("Switching provider to: \(newProvider.rawValue)")

        if newProvider == .localMLX {
            // Switch to local - need to load a model
            if isModelCached(config.selectedModelId) {
                try await setupModel(config.selectedModelId)
            } else {
                status = .notConfigured
            }
        } else {
            // Switch to OpenAI
            if !config.openAIKey.isEmpty {
                try await configureOpenAI(
                    apiKey: config.openAIKey,
                    baseURL: config.openAIBaseURL.isEmpty ? nil : config.openAIBaseURL,
                    model: config.openAIModel
                )
            } else {
                status = .notConfigured
            }
        }

        provider = newProvider
        config.provider = newProvider
        saveConfig()
    }

    /// Unload the current model to free memory
    public func unloadModel() {
        unloadMLXModel()
        status = .notConfigured
        logger.info("Model unloaded")
    }

    // MARK: - Public API: Chat

    /// Query the AI with RAG context
    public func chat(
        query: String,
        recordingId: Int64?,
        sessionId: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard case .ready = self.status else {
                        throw AIError.notInitialized
                    }

                    guard let pipeline = self.ragPipeline else {
                        throw AIError.notInitialized
                    }

                    // Use RAG pipeline for chat
                    let stream = await pipeline.chat(
                        query: query,
                        sessionId: sessionId,
                        recordingFilter: recordingId
                    )

                    for try await token in stream {
                        continuation.yield(token)
                    }

                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Public API: Indexing

    /// Index a recording's transcript
    public func indexRecording(
        _ recording: DatabaseManager.Recording,
        transcript: DatabaseManager.Transcript,
        segments: [DatabaseManager.TranscriptSegment]
    ) async throws {
        guard let pipeline = ragPipeline else {
            throw AIError.notInitialized
        }

        try await pipeline.indexRecording(recording, transcript: transcript, segments: segments)
        await refreshIndexingStatus()
    }

    /// Rebuild entire index
    public func rebuildIndex() async throws {
        logToFile("[AIService] rebuildIndex called, isInitialized: \(isInitialized), ragPipeline: \(ragPipeline != nil)")

        // Wait for initialization if not complete
        if !isInitialized {
            logToFile("[AIService] Not initialized, calling initialize() first...")
            try await initialize()
        }

        guard let pipeline = ragPipeline else {
            logToFile("[AIService] ERROR: ragPipeline is nil")
            throw AIError.notInitialized
        }

        logToFile("[AIService] Calling pipeline.rebuildIndex()...")
        try await pipeline.rebuildIndex()
        logToFile("[AIService] rebuildIndex completed")
        await refreshIndexingStatus()
    }

    /// Write to debug log file
    private func logToFile(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projectecho_rag.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Refresh the indexing status
    public func refreshIndexingStatus() async {
        if let pipeline = ragPipeline {
            indexedRecordingsCount = await pipeline.indexedRecordingsCount
        }
    }

    // MARK: - Public API: Model Info

    /// Get all available models
    public func availableModels() -> [ModelRegistry.ModelInfo] {
        ModelRegistry.availableModels
    }

    /// Check if a model is cached locally
    public func isModelCached(_ modelId: String) -> Bool {
        // MLX caches to ~/.cache/huggingface/hub/models--{org}--{model}
        let cacheKey = "models--\(modelId.replacingOccurrences(of: "/", with: "--"))"
        let cacheDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(cacheKey)
            .appendingPathComponent("snapshots")

        // Check for actual model files
        guard let snapshots = try? fileManager.contentsOfDirectory(atPath: cacheDir.path),
              let latestSnapshot = snapshots.first else {
            return false
        }

        let modelPath = cacheDir.appendingPathComponent(latestSnapshot)

        // Must have config.json at minimum
        let configPath = modelPath.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configPath.path) else {
            return false
        }

        // Check for model weights (.safetensors files)
        let contents = (try? fileManager.contentsOfDirectory(atPath: modelPath.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Synchronous version for UI (non-async context)
    public nonisolated func isModelCachedSync(_ modelId: String) -> Bool {
        let cacheKey = "models--\(modelId.replacingOccurrences(of: "/", with: "--"))"
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(cacheKey)
            .appendingPathComponent("snapshots")

        guard let snapshots = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path),
              let latestSnapshot = snapshots.first else {
            return false
        }

        let modelPath = cacheDir.appendingPathComponent(latestSnapshot)
        let configPath = modelPath.appendingPathComponent("config.json")

        return FileManager.default.fileExists(atPath: configPath.path)
    }

    /// Check if service is ready for chat
    public var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    /// Get current config (read-only)
    public var currentConfig: Config {
        config
    }

    // MARK: - Private: Memory Check

    /// Check memory availability using the CORRECT macOS API
    private func checkMemoryAvailability(for modelId: String) -> MemoryCheckResult {
        // Use volumeAvailableCapacityForImportantUsage - the RIGHT way on macOS
        // This returns memory that CAN be made available (includes inactive/purgeable)
        // NOT free_count which is always low because macOS uses RAM for caching
        let homeURL = fileManager.homeDirectoryForCurrentUser

        guard let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            logger.warning("Could not check memory availability")
            return .unknown
        }

        let availableGB = Double(available) / 1_073_741_824

        // Estimate required memory based on model name
        let requiredGB = ModelRegistry.estimatedMemoryGB(for: modelId)

        logger.info("Memory check: \(String(format: "%.1f", availableGB))GB available, \(String(format: "%.1f", requiredGB))GB required")

        if availableGB < requiredGB {
            return .insufficient(available: availableGB, required: requiredGB)
        }
        return .sufficient
    }

    // MARK: - Private: MLX Helpers

    private func unloadMLXModel() {
        chatSession = nil
        modelContainer = nil
        Task {
            await llmEngine?.unload()
        }
    }

    private func parseMLXError(_ error: Error, modelId: String) -> String {
        let message = error.localizedDescription.lowercased()
        let fullError = String(describing: error).lowercased()

        // Check for Metal shader/metallib errors (common when built with SwiftPM)
        if fullError.contains("metallib") || fullError.contains("metal") && fullError.contains("library not found") {
            return "Metal shaders not available. This app must be built with Xcode, not SwiftPM. Try using OpenAI API instead."
        }

        if message.contains("network") || message.contains("connection") ||
           message.contains("internet") || message.contains("offline") {
            return "Network error. Check your internet connection and try again."
        }

        if message.contains("403") || message.contains("forbidden") ||
           message.contains("access denied") || message.contains("restricted") {
            return "Model access restricted. Try a different model like Gemma or Llama."
        }

        if message.contains("memory") || message.contains("allocation") ||
           message.contains("out of memory") {
            return "Not enough memory. Try closing other apps or select a smaller model."
        }

        if message.contains("404") || message.contains("not found") {
            return "Model not found on Hugging Face. The model ID may be incorrect."
        }

        return error.localizedDescription
    }

    // MARK: - Private: Config Persistence

    private func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: "AIService.config"),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            config = decoded
            provider = decoded.provider
        }
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "AIService.config")
        }
    }
}
