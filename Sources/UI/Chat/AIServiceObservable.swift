import Foundation
import SwiftUI
import Combine
import Intelligence

/// Observable wrapper for AIService to use in SwiftUI views
/// Polls the AIService actor for status updates
@available(macOS 14.0, *)
@MainActor
public class AIServiceObservable: ObservableObject {

    // MARK: - Published State

    @Published public var status: AIService.Status = .notConfigured
    @Published public var provider: AIService.Provider = .localMLX
    @Published public var indexedCount: Int = 0
    @Published public var totalIndexable: Int = 0

    // Config bindings
    @Published public var selectedModelId: String
    @Published public var openAIKey: String = ""
    @Published public var openAIBaseURL: String = ""
    @Published public var openAIModel: String = "gpt-4o-mini"

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
    }

    private func loadFromService() {
        Task {
            let config = await AIService.shared.currentConfig
            await MainActor.run {
                self.selectedModelId = config.selectedModelId
                self.openAIKey = config.openAIKey
                self.openAIBaseURL = config.openAIBaseURL
                self.openAIModel = config.openAIModel
                self.provider = config.provider
            }
        }
    }

    // MARK: - Computed Properties

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
        case .downloading, .loading:
            return .orange
        case .error:
            return .red
        case .notConfigured:
            return .gray
        }
    }

    // MARK: - Actions

    /// Setup a model (downloads if needed, then loads)
    public func setupModel(_ modelId: String) {
        print("[AIServiceObservable] setupModel called for: \(modelId)")
        selectedModelId = modelId
        Task {
            do {
                print("[AIServiceObservable] Calling AIService.shared.setupModel...")
                try await AIService.shared.setupModel(modelId)
                print("[AIServiceObservable] setupModel completed successfully")
            } catch {
                print("[AIServiceObservable] setupModel failed: \(error)")
                // Error is reflected in status
            }
        }
    }

    /// Setup the default model
    public func setupDefaultModel() {
        setupModel(ModelRegistry.defaultModel.id)
    }

    /// Configure OpenAI backend
    public func configureOpenAI() {
        guard !openAIKey.isEmpty else { return }
        Task {
            do {
                try await AIService.shared.configureOpenAI(
                    apiKey: openAIKey,
                    baseURL: openAIBaseURL.isEmpty ? nil : openAIBaseURL,
                    model: openAIModel
                )
            } catch {
                // Error is reflected in status
            }
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

    // MARK: - Model Info Helpers

    public func modelInfo(for id: String) -> ModelRegistry.ModelInfo? {
        ModelRegistry.model(for: id)
    }

    public func isModelCached(_ id: String) -> Bool {
        AIService.shared.isModelCachedSync(id)
    }
}
