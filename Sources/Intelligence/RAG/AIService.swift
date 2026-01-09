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
        case unloadedToSaveMemory(modelName: String)  // NEW: Model was auto-unloaded to free memory
        case downloading(progress: Double, modelName: String)
        case loading(modelName: String)
        case ready(modelName: String)
        case error(message: String)

        public static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.notConfigured, .notConfigured):
                return true
            case (.unloadedToSaveMemory(let m1), .unloadedToSaveMemory(let m2)):
                return m1 == m2
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
        public var openAITemperature: Float = 1.0
        public var autoIndexTranscripts: Bool = true
        public var autoUnloadEnabled: Bool = true   // NEW: Enable auto-unload to save memory
        public var autoUnloadMinutes: Int = 5       // NEW: Minutes of inactivity before unloading (0 = disabled)
        /// Low power mode - reduces CPU/GPU usage by throttling inference speed
        /// Useful to prevent fan noise during long summarizations
        public var lowPowerMode: Bool = true        // Default ON to prevent fan noise

        public init() {}
    }

    private var config: Config = Config()

    // MARK: - Components

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "AIService")
    private let fileManager = FileManager.default

    /// MLX model container (when using local MLX)
    private var modelContainer: ModelContainer?

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
    public private(set) var isInitialized = false

    /// Whether initialization is in progress
    public private(set) var isInitializing = false

    /// Whether a model setup is currently in progress
    private var isSettingUp = false

    // MARK: - Auto-Unload Properties

    /// Last time AI was used (for inactivity tracking)
    private var lastActivityTime: Date = Date()

    /// Task that handles auto-unload after inactivity
    private var autoUnloadTask: Task<Void, Never>?

    /// Whether an AI operation is currently active (prevents unload during use)
    private var isActivelyProcessing = false

    /// Check if AI is enabled via user preferences
    public var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true
    }

    /// Whether auto-unload is enabled
    public var isAutoUnloadEnabled: Bool {
        config.autoUnloadEnabled && config.autoUnloadMinutes > 0
    }

    /// Auto-unload timeout in minutes
    public var autoUnloadMinutes: Int {
        config.autoUnloadMinutes
    }

    /// Whether low power mode is enabled (throttles inference to reduce CPU/GPU load)
    public var isLowPowerMode: Bool {
        config.lowPowerMode
    }

    /// Configure low power mode
    public func setLowPowerMode(_ enabled: Bool) async {
        config.lowPowerMode = enabled
        saveConfig()
        // Update LLM engine with new setting
        await llmEngine?.setLowPowerMode(enabled)
        logToFile("[AIService] Low power mode set to: \(enabled)")
    }

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
            print("[AIService] Loaded saved config - model: \(decoded.selectedModelId), provider: \(decoded.provider.rawValue)")
        } else {
            print("[AIService] No saved config found, using defaults - model: \(config.selectedModelId)")
        }
    }

    // MARK: - Public API: Initialization

    /// Initialize the AI service - call on app launch
    /// This sets up components but doesn't load models
    public func initialize() async throws {
        // Check if AI is disabled by user
        guard UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true else {
            status = .notConfigured
            logger.info("AI Service disabled by user preference")
            return
        }

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

        // Initialize database manager (use shared instance to prevent concurrent access issues)
        databaseManager = try await DatabaseManager.shared()

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
        logToFile("[AIService] Initialize complete - ragPipeline: \(ragPipeline != nil)")

        // Auto-load cached model on startup
        let modelId = self.config.selectedModelId
        let isCached = isModelCached(modelId)
        logToFile("[AIService] Auto-load check: provider=\(provider.rawValue), modelId=\(modelId), isCached=\(isCached)")

        // Load the appropriate backend based on user's explicit provider choice
        // NO FALLBACK: If the user chose localMLX, we only try local. If they chose OpenAI, we only try OpenAI.
        if provider == .localMLX {
            if isCached {
                logger.info("Auto-loading cached model: \(modelId)")
                logToFile("[AIService] Auto-loading cached local MLX model: \(modelId)")
                do {
                    try await setupModel(modelId)
                    logToFile("[AIService] Model auto-loaded successfully")
                } catch {
                    logger.warning("Failed to auto-load model: \(error.localizedDescription)")
                    logToFile("[AIService] Failed to auto-load local model: \(error.localizedDescription)")
                    // Status will remain .notConfigured or .error - user can manually configure
                    // DO NOT fall back to OpenAI - respect user's choice
                }
            } else {
                logToFile("[AIService] Local MLX model not cached, status remains notConfigured")
                // Model not cached - user needs to download it in settings
                // DO NOT fall back to OpenAI - respect user's choice
            }
        } else if provider == .openAICompatible && !config.openAIKey.isEmpty {
            // Auto-configure OpenAI on startup if saved provider is openAICompatible
            logger.info("Auto-configuring OpenAI backend on startup")
            logToFile("[AIService] Auto-configuring OpenAI backend: model=\(config.openAIModel), temperature=\(config.openAITemperature)")
            do {
                try await configureOpenAI(
                    apiKey: config.openAIKey,
                    baseURL: config.openAIBaseURL.isEmpty ? nil : config.openAIBaseURL,
                    model: config.openAIModel,
                    temperature: config.openAITemperature
                )
                logToFile("[AIService] OpenAI backend auto-configured successfully")
            } catch {
                logger.warning("Failed to auto-configure OpenAI: \(error.localizedDescription)")
                logToFile("[AIService] Failed to auto-configure OpenAI: \(error.localizedDescription)")
                // Status will remain .notConfigured, user can manually configure
            }
        } else if provider == .openAICompatible && config.openAIKey.isEmpty {
            logToFile("[AIService] OpenAI provider selected but no API key configured")
        }

        // Update indexing count
        await refreshIndexingStatus()
        logToFile("[AIService] Indexed recordings count: \(indexedRecordingsCount)")

        logger.info("AI service initialized")
    }

    // MARK: - Public API: Model Setup

    /// Helper method to update download progress from the progress callback
    /// This is called from within the actor to safely update status
    private func updateDownloadProgress(_ progress: Double, modelName: String) {
        // Only update if we're still in downloading state
        if case .downloading = status {
            status = .downloading(progress: progress, modelName: modelName)
        }
    }

    /// Setup a local MLX model (downloads if needed, then loads)
    /// This is the MAIN method for getting a model ready
    public func setupModel(_ modelId: String) async throws {
        // If setup is already in progress, wait for it to complete
        if isSettingUp {
            logToFile("[AIService] setupModel already in progress, waiting for completion...")
            for _ in 0..<120 {  // Wait up to 60 seconds
                try await Task.sleep(nanoseconds: 500_000_000)
                if !isSettingUp {
                    logToFile("[AIService] Previous setup completed, checking status")
                    // If model is now ready, return success
                    if case .ready = status {
                        return
                    }
                    // Otherwise fall through to try setup
                    break
                }
            }
            // If still setting up after timeout, return
            if isSettingUp {
                logToFile("[AIService] Setup timeout, returning")
                return
            }
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

            // Capture model name for progress callback
            let displayName = modelInfo.displayName

            // Use progress handler to update download progress in real-time
            // Capture self weakly for the callback to update progress
            let selfActor = self
            let container = try await MLXLMCommon.loadModelContainer(id: modelId) { progress in
                // Update status with real download progress
                let fractionCompleted = progress.fractionCompleted
                Task {
                    await selfActor.updateDownloadProgress(fractionCompleted, modelName: displayName)
                }
            }
            print("[AIService] loadModelContainer completed successfully")

            status = .loading(modelName: modelInfo.displayName)

            // Store the container
            self.modelContainer = container
            print("[AIService] Stored model container")

            // Configure LLM engine with MLX backend (stateless mode)
            if let engine = llmEngine {
                await engine.setMLXBackend(container)
                // Apply low power mode setting
                await engine.setLowPowerMode(config.lowPowerMode)
                print("[AIService] Configured LLM engine (lowPowerMode: \(config.lowPowerMode))")
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

            // Start auto-unload timer if enabled
            if isAutoUnloadEnabled {
                resetInactivityTimer()
            }

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
    public func configureOpenAI(apiKey: String, baseURL: String?, model: String, temperature: Float = 1.0) async throws {
        logger.info("Configuring OpenAI backend")

        // Ensure initialized
        if !isInitialized {
            try await initialize()
        }

        guard !apiKey.isEmpty else {
            throw AIError.openAINotConfigured
        }

        // Unload any MLX model
        await unloadMLXModel()

        // Configure OpenAI backend on LLM engine
        let baseURLParsed = baseURL.flatMap { URL(string: $0) }
        await llmEngine?.setOpenAIBackend(apiKey: apiKey, baseURL: baseURLParsed, model: model, temperature: temperature)

        // Save config
        config.provider = .openAICompatible
        config.openAIKey = apiKey
        config.openAIBaseURL = baseURL ?? ""
        config.openAIModel = model
        config.openAITemperature = temperature
        saveConfig()

        provider = .openAICompatible
        status = .ready(modelName: model)

        logger.info("OpenAI backend configured: \(model) with temperature: \(temperature)")
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
                    model: config.openAIModel,
                    temperature: config.openAITemperature
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
    public func unloadModel() async {
        cancelAutoUnloadTimer()
        await unloadMLXModel()
        status = .notConfigured
        logger.info("Model unloaded")
    }

    // MARK: - Public API: Clear Models

    /// Clear all downloaded AI models to free disk space
    /// This removes models from both the app's local cache and HuggingFace cache
    /// Returns the total bytes cleared
    @discardableResult
    public func clearAllModels() async throws -> Int64 {
        logger.info("Clearing all downloaded AI models")
        logToFile("[AIService] clearAllModels called")

        // 1. Unload current model first
        await unloadModel()

        var totalBytesCleared: Int64 = 0

        // 2. Clear app's local Models directory
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let localModelsPath = appSupport
                .appendingPathComponent("Engram")
                .appendingPathComponent("Models")
                .appendingPathComponent("llm")

            if fileManager.fileExists(atPath: localModelsPath.path) {
                totalBytesCleared += calculateDirectorySize(localModelsPath)
                try? fileManager.removeItem(at: localModelsPath)
                try? fileManager.createDirectory(at: localModelsPath, withIntermediateDirectories: true)
                logToFile("[AIService] Cleared local models directory: \(localModelsPath.path)")
            }
        }

        // 3. Clear HuggingFace cache for MLX models only
        let hubCacheDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")

        if let contents = try? fileManager.contentsOfDirectory(atPath: hubCacheDir.path) {
            for item in contents {
                // Only clear MLX community models (what this app downloads)
                if item.hasPrefix("models--mlx-community--") {
                    let itemPath = hubCacheDir.appendingPathComponent(item)
                    totalBytesCleared += calculateDirectorySize(itemPath)
                    try? fileManager.removeItem(at: itemPath)
                    logToFile("[AIService] Cleared HuggingFace cache: \(item)")
                }
            }
        }

        // 4. Reset config to default model
        config.selectedModelId = ModelRegistry.defaultModel.id
        saveConfig()

        logger.info("Cleared \(totalBytesCleared) bytes of AI models")
        logToFile("[AIService] Total bytes cleared: \(totalBytesCleared)")

        return totalBytesCleared
    }

    /// Calculate total size of a directory recursively
    private func calculateDirectorySize(_ url: URL) -> Int64 {
        var totalSize: Int64 = 0
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  resourceValues.isRegularFile == true else {
                continue
            }
            totalSize += Int64(resourceValues.totalFileAllocatedSize ?? resourceValues.fileSize ?? 0)
        }

        return totalSize
    }

    /// Calculate total size of all cached models
    public func calculateCachedModelsSize() -> Int64 {
        var totalSize: Int64 = 0

        // Check app's local Models directory
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let localModelsPath = appSupport
                .appendingPathComponent("Engram")
                .appendingPathComponent("Models")
                .appendingPathComponent("llm")
            totalSize += calculateDirectorySize(localModelsPath)
        }

        // Check HuggingFace cache for MLX models
        let hubCacheDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")

        if let contents = try? fileManager.contentsOfDirectory(atPath: hubCacheDir.path) {
            for item in contents {
                if item.hasPrefix("models--mlx-community--") {
                    let itemPath = hubCacheDir.appendingPathComponent(item)
                    totalSize += calculateDirectorySize(itemPath)
                }
            }
        }

        return totalSize
    }

    /// Synchronous version for UI (runs on calling thread)
    public nonisolated func calculateCachedModelsSizeSync() -> Int64 {
        let fm = FileManager.default
        var totalSize: Int64 = 0
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]

        func dirSize(_ url: URL) -> Int64 {
            var size: Int64 = 0
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { return 0 }

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                      values.isRegularFile == true else { continue }
                size += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
            return size
        }

        // Check app's local Models directory
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let localModelsPath = appSupport
                .appendingPathComponent("Engram")
                .appendingPathComponent("Models")
                .appendingPathComponent("llm")
            totalSize += dirSize(localModelsPath)
        }

        // Check HuggingFace cache for MLX models
        let hubCacheDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")

        if let contents = try? fm.contentsOfDirectory(atPath: hubCacheDir.path) {
            for item in contents where item.hasPrefix("models--mlx-community--") {
                totalSize += dirSize(hubCacheDir.appendingPathComponent(item))
            }
        }

        return totalSize
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
                    // Reset inactivity timer
                    self.resetInactivityTimer()

                    // Reload model if it was auto-unloaded
                    try await self.reloadModelIfNeeded()

                    guard case .ready = self.status else {
                        throw AIError.notInitialized
                    }

                    guard let pipeline = self.ragPipeline else {
                        throw AIError.notInitialized
                    }

                    // Mark as actively processing to prevent auto-unload
                    self.isActivelyProcessing = true
                    defer {
                        self.isActivelyProcessing = false
                        self.resetInactivityTimer()
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
                    self.isActivelyProcessing = false
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Public API: Agentic Chat

    /// Agentic chat that intelligently routes queries based on intent
    /// Uses intent classification to determine whether to use RAG search or full transcript
    public func agentChat(
        query: String,
        sessionId: String,
        recordingFilter: Int64? = nil
    ) -> AsyncThrowingStream<String, Error> {
        logToFile("[AIService.agentChat] Query: '\(query)', Filter: \(String(describing: recordingFilter))")
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Reset inactivity timer
                    self.resetInactivityTimer()

                    // Reload model if it was auto-unloaded
                    try await self.reloadModelIfNeeded()

                    guard let pipeline = self.ragPipeline else {
                        self.logToFile("[AIService.agentChat] ERROR: ragPipeline is nil")
                        throw AIError.notInitialized
                    }

                    // Mark as actively processing to prevent auto-unload
                    self.isActivelyProcessing = true
                    defer {
                        self.isActivelyProcessing = false
                        self.resetInactivityTimer()
                    }

                    self.logToFile("[AIService.agentChat] Calling pipeline.agentChat...")
                    let stream = await pipeline.agentChat(
                        query: query,
                        sessionId: sessionId,
                        recordingFilter: recordingFilter
                    )

                    for try await token in stream {
                        continuation.yield(token)
                    }

                    continuation.finish()

                } catch {
                    self.isActivelyProcessing = false
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
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("engram_rag.log")
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
    /// Checks both HuggingFace cache and app's local Models directory
    public func isModelCached(_ modelId: String) -> Bool {
        // Check 1: App's local Models directory (~/Library/Application Support/Engram/Models/llm/)
        let modelName = modelId.components(separatedBy: "/").last ?? modelId
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let localModelPath = appSupport
                .appendingPathComponent("Engram")
                .appendingPathComponent("Models")
                .appendingPathComponent("llm")
                .appendingPathComponent(modelName)

            let configPath = localModelPath.appendingPathComponent("config.json")
            if fileManager.fileExists(atPath: configPath.path) {
                let contents = (try? fileManager.contentsOfDirectory(atPath: localModelPath.path)) ?? []
                let hasSafetensors = contents.contains { $0.hasSuffix(".safetensors") }
                if hasSafetensors {
                    logToFile("[isModelCached] Found in local cache: \(localModelPath.path)")
                    return true
                }
            }
        }

        // Check 2: HuggingFace cache (~/.cache/huggingface/hub/models--{org}--{model})
        let cacheKey = "models--\(modelId.replacingOccurrences(of: "/", with: "--"))"
        let cacheDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(cacheKey)
            .appendingPathComponent("snapshots")

        guard let snapshots = try? fileManager.contentsOfDirectory(atPath: cacheDir.path),
              let latestSnapshot = snapshots.first else {
            logToFile("[isModelCached] No cache found for \(modelId)")
            return false
        }

        let modelPath = cacheDir.appendingPathComponent(latestSnapshot)
        let configPath = modelPath.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configPath.path) else {
            logToFile("[isModelCached] No config.json found for \(modelId)")
            return false
        }

        let contents = (try? fileManager.contentsOfDirectory(atPath: modelPath.path)) ?? []
        let hasSafetensors = contents.contains { $0.hasSuffix(".safetensors") }
        logToFile("[isModelCached] HuggingFace cache \(modelId): hasSafetensors=\(hasSafetensors)")
        return hasSafetensors
    }

    /// Synchronous version for UI (non-async context)
    public nonisolated func isModelCachedSync(_ modelId: String) -> Bool {
        let fm = FileManager.default

        // Check 1: App's local Models directory
        let modelName = modelId.components(separatedBy: "/").last ?? modelId
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let localModelPath = appSupport
                .appendingPathComponent("Engram")
                .appendingPathComponent("Models")
                .appendingPathComponent("llm")
                .appendingPathComponent(modelName)

            let configPath = localModelPath.appendingPathComponent("config.json")
            if fm.fileExists(atPath: configPath.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: localModelPath.path)) ?? []
                if contents.contains(where: { $0.hasSuffix(".safetensors") }) {
                    return true
                }
            }
        }

        // Check 2: HuggingFace cache
        let cacheKey = "models--\(modelId.replacingOccurrences(of: "/", with: "--"))"
        let cacheDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(cacheKey)
            .appendingPathComponent("snapshots")

        guard let snapshots = try? fm.contentsOfDirectory(atPath: cacheDir.path),
              let latestSnapshot = snapshots.first else {
            return false
        }

        let modelPath = cacheDir.appendingPathComponent(latestSnapshot)
        let configPath = modelPath.appendingPathComponent("config.json")
        return fm.fileExists(atPath: configPath.path)
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

    private func unloadMLXModel() async {
        logToFile("[AIService] unloadMLXModel: Setting modelContainer to nil...")
        modelContainer = nil
        logToFile("[AIService] unloadMLXModel: Calling llmEngine?.unload()...")
        await llmEngine?.unload()
        logToFile("[AIService] unloadMLXModel: Complete")
    }

    // MARK: - Auto-Unload Timer Management

    /// Reset the inactivity timer - call this whenever AI is used
    private func resetInactivityTimer() {
        lastActivityTime = Date()

        // Only start timer for local MLX models when auto-unload is enabled
        guard provider == .localMLX, isAutoUnloadEnabled else {
            autoUnloadTask?.cancel()
            autoUnloadTask = nil
            return
        }

        startAutoUnloadTimer()
    }

    /// Start/restart the auto-unload timer
    private func startAutoUnloadTimer() {
        // Cancel existing timer
        autoUnloadTask?.cancel()

        let minutes = config.autoUnloadMinutes
        guard minutes > 0 else { return }

        logToFile("[AIService] Auto-unload timer started (\(minutes) minutes)")

        autoUnloadTask = Task { [weak self] in
            let nanoseconds = UInt64(minutes) * 60 * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard !Task.isCancelled else { return }
            await self?.autoUnloadIfIdle()
        }
    }

    /// Cancel the auto-unload timer
    private func cancelAutoUnloadTimer() {
        autoUnloadTask?.cancel()
        autoUnloadTask = nil
    }

    /// Auto-unload the model if idle for the configured time
    private func autoUnloadIfIdle() async {
        // Don't unload if actively processing
        guard !isActivelyProcessing else {
            logToFile("[AIService] Auto-unload skipped - actively processing")
            // Restart timer since we're still being used
            startAutoUnloadTimer()
            return
        }

        // Don't unload if not using local MLX
        guard provider == .localMLX else {
            logToFile("[AIService] Auto-unload skipped - not using local MLX")
            return
        }

        // Check if model is even loaded
        guard modelContainer != nil else {
            logToFile("[AIService] Auto-unload skipped - model not loaded")
            return
        }

        let idleTime = Date().timeIntervalSince(lastActivityTime)
        let thresholdSeconds = Double(config.autoUnloadMinutes * 60)

        guard idleTime >= thresholdSeconds else {
            // Not idle long enough, restart timer for remaining time
            let remaining = thresholdSeconds - idleTime
            logToFile("[AIService] Auto-unload timer reset - only \(Int(idleTime)) seconds idle, need \(Int(thresholdSeconds))")
            autoUnloadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(remaining) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.autoUnloadIfIdle()
            }
            return
        }

        // Get model name for status
        let modelName = ModelRegistry.model(for: config.selectedModelId)?.displayName ?? config.selectedModelId

        logToFile("[AIService] Auto-unloading model after \(Int(idleTime / 60)) minutes of inactivity")
        logger.info("Auto-unloading model to save memory after \(Int(idleTime / 60)) minutes of inactivity")

        logToFile("[AIService] Step 1: Calling unloadMLXModel...")
        await unloadMLXModel()
        logToFile("[AIService] Step 2: unloadMLXModel complete, setting status...")
        status = .unloadedToSaveMemory(modelName: modelName)
        logToFile("[AIService] Step 3: Auto-unload complete, status set to unloadedToSaveMemory")
    }

    /// Configure auto-unload settings
    public func setAutoUnload(enabled: Bool, minutes: Int) async {
        config.autoUnloadEnabled = enabled
        config.autoUnloadMinutes = max(0, minutes)
        saveConfig()

        logToFile("[AIService] Auto-unload configured: enabled=\(enabled), minutes=\(minutes)")

        if enabled && minutes > 0 && provider == .localMLX {
            if case .ready = status {
                // Model is loaded, start the timer
                resetInactivityTimer()
            }
        } else {
            // Disable: cancel any existing timer
            cancelAutoUnloadTimer()
        }
    }

    /// Reload model if it was auto-unloaded
    private func reloadModelIfNeeded() async throws {
        // Only reload for local MLX provider when model was unloaded to save memory
        guard provider == .localMLX else { return }

        if case .unloadedToSaveMemory = status {
            logToFile("[AIService] Model was auto-unloaded, reloading for user query...")
            logger.info("Reloading model that was auto-unloaded")
            try await setupModel(config.selectedModelId)
            logToFile("[AIService] Model reloaded successfully")
        } else if modelContainer == nil {
            // Check if status is notConfigured and we have a cached model - try to load it
            if case .notConfigured = status, isModelCached(config.selectedModelId) {
                logToFile("[AIService] Model not loaded, loading cached model for user query...")
                try await setupModel(config.selectedModelId)
            }
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

    private func saveConfig() {
        do {
            let data = try JSONEncoder().encode(config)
            UserDefaults.standard.set(data, forKey: "AIService.config")
            UserDefaults.standard.synchronize() // Force immediate write
            logToFile("[AIService] Config saved - model: \(config.selectedModelId), provider: \(config.provider.rawValue)")
        } catch {
            logToFile("[AIService] ERROR: Failed to save config: \(error.localizedDescription)")
            logger.error("Failed to save AI config: \(error.localizedDescription)")
        }
    }
}
