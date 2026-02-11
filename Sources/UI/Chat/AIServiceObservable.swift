import Foundation
import SwiftUI
import Combine
import Intelligence

/// Observable wrapper for AIService to use in SwiftUI views
/// Polls the AIService actor for status updates (display-only values).
/// Config values are now read directly from AIService.shared.currentConfig in settings views.
@available(macOS 14.0, *)
@MainActor
public class AIServiceObservable: ObservableObject {

    // MARK: - Published State (display-only, polled from AIService)

    @Published public var status: AIService.Status = .notConfigured
    @Published public var provider: AIService.Provider = .localMLX
    @Published public var selectedModelId: String
    @Published public var indexedCount: Int = 0
    @Published public var totalIndexable: Int = 0
    @Published public var isIndexingLoading: Bool = true

    /// Whether the AIService is currently initializing (startup phase)
    @Published public var isInitializing: Bool = true

    /// Whether the AIService has completed initialization
    @Published public var isInitialized: Bool = false

    // Connection test state
    @Published public var isTestingConnection: Bool = false
    @Published public var connectionTestResult: ConnectionTestResult?

    // Model clearing state
    @Published public var isClearingModels: Bool = false
    @Published public var cachedModelsSize: Int64 = 0

    // Auto-unload settings
    @Published public var autoUnloadEnabled: Bool = true
    @Published public var autoUnloadMinutes: Int = 5

    /// Result of a connection test
    public enum ConnectionTestResult: Equatable {
        case success(modelCount: Int)
        case failure(message: String)
    }

    // AI enabled toggle
    @AppStorage("aiEnabled") var aiEnabled = true

    // MARK: - Private

    private var statusTask: Task<Void, Never>?
    private let pollInterval: UInt64 = 500_000_000 // 0.5 seconds

    // MARK: - Initialization

    public init() {
        self.selectedModelId = ModelRegistry.defaultModel.id
        loadFromService()
        startStatusPolling()
    }

    deinit {
        statusTask?.cancel()
    }

    // MARK: - Status Polling

    private func startStatusPolling() {
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(nanoseconds: self?.pollInterval ?? 500_000_000)
            }
        }
    }

    private func refreshStatus() async {
        let service = AIService.shared
        self.status = await service.status
        self.provider = await service.provider
        self.indexedCount = await service.indexedRecordingsCount

        // Update model selection from service (needed for model row display)
        let config = await service.currentConfig
        if self.selectedModelId != config.selectedModelId {
            self.selectedModelId = config.selectedModelId
        }

        // Update initialization state
        let initialized = await service.isInitialized
        let initializing = await service.isInitializing
        self.isInitialized = initialized
        self.isInitializing = initializing
        self.isIndexingLoading = !initialized || initializing

        // Update cached models size (only if not currently clearing)
        if !isClearingModels {
            self.cachedModelsSize = AIService.shared.calculateCachedModelsSizeSync()
        }
    }

    private func loadFromService() {
        Task {
            let config = await AIService.shared.currentConfig
            let currentStatus = await AIService.shared.status

            await MainActor.run {
                self.selectedModelId = config.selectedModelId
                self.provider = config.provider
                self.autoUnloadEnabled = config.autoUnloadEnabled
                self.autoUnloadMinutes = config.autoUnloadMinutes
            }

            // Auto-trigger Gemini setup if provider is gemini and key is set but not ready
            if config.provider == .gemini,
               case .notConfigured = currentStatus,
               !config.geminiKey.isEmpty {
                fileRagLog("[AIServiceObservable] Auto-triggering Gemini setup")
                do {
                    try await AIService.shared.configureGemini(
                        apiKey: config.geminiKey,
                        model: config.geminiAIModel,
                        temperature: config.geminiTemperature
                    )
                    fileRagLog("[AIServiceObservable] Gemini auto-configured successfully")
                } catch {
                    fileRagLog("[AIServiceObservable] Failed to auto-configure Gemini: \(error)")
                }
            }

            // Auto-trigger model setup if model is cached but not loaded
            if config.provider == .localMLX,
               case .notConfigured = currentStatus,
               AIService.shared.isModelCachedSync(config.selectedModelId) {
                fileRagLog("[AIServiceObservable] Auto-triggering setup for cached model: \(config.selectedModelId)")
                do {
                    try await AIService.shared.setupModel(config.selectedModelId)
                    fileRagLog("[AIServiceObservable] Cached model auto-loaded successfully")
                } catch {
                    fileRagLog("[AIServiceObservable] Failed to auto-load cached model: \(error)")
                }
            }
        }
    }

    // MARK: - Computed Properties

    var isDisabled: Bool {
        !aiEnabled
    }

    public var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    public var isLoading: Bool {
        switch status {
        case .downloading, .loading:
            return true
        default:
            return false
        }
    }

    public var statusText: String {
        switch status {
        case .notConfigured:
            return "Not configured"
        case .unloadedToSaveMemory(let name):
            return "Sleeping: \(name)"
        case .downloading(let progress, let name):
            return "Downloading \(name)... \(Int(progress * 100))%"
        case .loading(let name):
            return "Loading \(name)..."
        case .ready(let name):
            return "Ready: \(name)"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    public var statusColor: Color {
        switch status {
        case .ready:
            return .green
        case .unloadedToSaveMemory:
            return .blue.opacity(0.7)
        case .downloading, .loading:
            return .orange
        case .error:
            return .red
        case .notConfigured:
            return .gray
        }
    }

    // MARK: - Actions

    func retryInitialization() async {
        guard aiEnabled else { return }
        do {
            try await AIService.shared.initialize()
        } catch {
            // Error will be reflected in status
        }
    }

    /// Setup a model (downloads if needed, then loads)
    public func setupModel(_ modelId: String) {
        fileRagLog("[AIServiceObservable] setupModel called for: \(modelId)")
        selectedModelId = modelId
        Task {
            do {
                fileRagLog("[AIServiceObservable] Calling AIService.shared.setupModel...")
                try await AIService.shared.setupModel(modelId)
                fileRagLog("[AIServiceObservable] setupModel completed successfully")
            } catch {
                fileRagLog("[AIServiceObservable] setupModel failed: \(error)")
                // Error is reflected in status
            }
        }
    }

    /// Setup the default model
    public func setupDefaultModel() {
        setupModel(ModelRegistry.defaultModel.id)
    }

    /// Test Gemini API connection by listing available models
    public func testGeminiConnectionWith(apiKey: String) {
        guard !apiKey.isEmpty else {
            connectionTestResult = .failure(message: "API key is required")
            return
        }

        isTestingConnection = true
        connectionTestResult = nil

        Task {
            do {
                let result = try await performGeminiConnectionTest(apiKey: apiKey)
                await MainActor.run {
                    self.connectionTestResult = result
                    self.isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    self.connectionTestResult = .failure(message: error.localizedDescription)
                    self.isTestingConnection = false
                }
            }
        }
    }

    /// Perform Gemini connection test by listing models
    private func performGeminiConnectionTest(apiKey: String) async throws -> ConnectionTestResult {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            return .failure(message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        // Use a session with SOCKS5 proxy (same as Gemini transcriber)
        let proxyConfig = URLSessionConfiguration.default
        proxyConfig.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable: true,
            kCFNetworkProxiesSOCKSProxy: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort: 11111
        ]
        let session = URLSession(configuration: proxyConfig)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(message: "Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return .success(modelCount: models.count)
            }
            return .success(modelCount: 0)
        case 400:
            return .failure(message: "Invalid API key (400 Bad Request)")
        case 403:
            return .failure(message: "Access denied (403 Forbidden)")
        case 429:
            return .failure(message: "Rate limited (429). Try again later.")
        default:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .failure(message: message)
            }
            return .failure(message: "HTTP \(httpResponse.statusCode)")
        }
    }

    /// Test OpenAI API connection with specific values (does not modify stored properties)
    public func testOpenAIConnectionWith(apiKey: String, baseURL: String) {
        guard !apiKey.isEmpty else {
            connectionTestResult = .failure(message: "API key is required")
            return
        }

        isTestingConnection = true
        connectionTestResult = nil

        Task {
            do {
                let result = try await performConnectionTest(apiKey: apiKey, baseURL: baseURL)
                await MainActor.run {
                    self.connectionTestResult = result
                    self.isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    self.connectionTestResult = .failure(message: error.localizedDescription)
                    self.isTestingConnection = false
                }
            }
        }
    }

    /// Clear the connection test result
    public func clearConnectionTestResult() {
        connectionTestResult = nil
    }

    /// Perform the actual connection test with provided credentials
    private func performConnectionTest(apiKey: String, baseURL: String) async throws -> ConnectionTestResult {
        let baseURLString = baseURL.isEmpty ? "https://api.openai.com" : baseURL
        guard let parsedBaseURL = URL(string: baseURLString) else {
            return .failure(message: "Invalid base URL")
        }

        let modelsURL = parsedBaseURL.appendingPathComponent("v1/models")

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(message: "Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]] {
                return .success(modelCount: models.count)
            }
            return .success(modelCount: 0)
        case 401:
            return .failure(message: "Invalid API key (401 Unauthorized)")
        case 403:
            return .failure(message: "Access denied (403 Forbidden)")
        case 404:
            return .failure(message: "Endpoint not found (404). Check the base URL.")
        case 429:
            return .failure(message: "Rate limited (429). Try again later.")
        case 500...599:
            return .failure(message: "Server error (\(httpResponse.statusCode))")
        default:
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .failure(message: message)
            }
            return .failure(message: "HTTP \(httpResponse.statusCode)")
        }
    }

    /// Switch provider
    public func setProvider(_ newProvider: AIService.Provider) {
        Task {
            do {
                try await AIService.shared.setProvider(newProvider)
            } catch {
                // Error is reflected in status
            }
        }
    }

    /// Unload current model
    public func unloadModel() {
        Task {
            await AIService.shared.unloadModel()
        }
    }

    /// Configure auto-unload settings
    public func setAutoUnload(enabled: Bool, minutes: Int) {
        self.autoUnloadEnabled = enabled
        self.autoUnloadMinutes = minutes
        Task {
            await AIService.shared.setAutoUnload(enabled: enabled, minutes: minutes)
        }
    }

    /// Whether the model is currently unloaded to save memory
    public var isUnloadedToSaveMemory: Bool {
        if case .unloadedToSaveMemory = status { return true }
        return false
    }

    /// Whether AI can be used (ready or sleeping - sleeping will auto-reload)
    public var canUseAI: Bool {
        isReady || isUnloadedToSaveMemory
    }

    /// Clear all downloaded AI models
    /// Returns the number of bytes cleared
    public func clearAllModels() async throws -> Int64 {
        await MainActor.run {
            isClearingModels = true
        }

        defer {
            Task { @MainActor in
                self.isClearingModels = false
                self.cachedModelsSize = AIService.shared.calculateCachedModelsSizeSync()
            }
        }

        return try await AIService.shared.clearAllModels()
    }

    /// Formatted string of cached models size
    public var cachedModelsSizeFormatted: String {
        if cachedModelsSize == 0 {
            return "No models downloaded"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: cachedModelsSize)
    }

    /// User-friendly help text explaining why AI buttons might be disabled
    public var aiStatusHelpText: String {
        switch status {
        case .notConfigured:
            return "AI model not configured. Go to Settings to set up an AI model."
        case .unloadedToSaveMemory(let name):
            return "\(name) is sleeping to save memory. It will reload when you use AI features."
        case .downloading(let progress, let name):
            return "Downloading \(name)... \(Int(progress * 100))%. Please wait."
        case .loading(let name):
            return "Loading \(name)... Please wait a moment."
        case .ready:
            return "AI is ready"
        case .error(let message):
            return "AI error: \(message). Try restarting the app or check Settings."
        }
    }

    // MARK: - Model Info Helpers

    public func modelInfo(for id: String) -> ModelRegistry.ModelInfo? {
        ModelRegistry.model(for: id)
    }

    public func isModelCached(_ id: String) -> Bool {
        AIService.shared.isModelCachedSync(id)
    }
}
