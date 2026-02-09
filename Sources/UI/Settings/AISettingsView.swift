// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import SwiftUI
import Intelligence

// MARK: - AI Settings View

@available(macOS 14.0, *)
public struct AISettingsView: View {
    @StateObject private var aiService = AIServiceObservable()
    @AppStorage("aiEnabled") private var aiEnabled = true
    @AppStorage("autoIndexTranscripts") private var autoIndexTranscripts = true
    @AppStorage("autoGenerateSummary") private var autoGenerateSummary = true
    @AppStorage("autoGenerateActionItems") private var autoGenerateActionItems = true
    // Transcription settings (read here for Gemini key sync)
    @AppStorage("transcriptionProvider") private var transcriptionProvider = "whisperkit"
    @AppStorage("geminiAPIKey") private var geminiAPIKey = ""
    @State private var isRebuildingIndex = false
    @State private var rebuildError: String?
    @State private var clearModelsError: String?

    // MARK: - Pending State (unified apply)
    @State private var pendingProvider: AIService.Provider?
    @State private var pendingOpenAIKey: String = ""
    @State private var pendingOpenAIBaseURL: String = ""
    @State private var pendingOpenAIModel: String = ""
    @State private var pendingOpenAITemperature: Float = 1.0
    @State private var pendingMLXModel: String?
    @State private var pendingGeminiKey: String = ""
    @State private var pendingGeminiAIModel: String = GeminiAIModel.gemini25FlashLite.rawValue
    @State private var pendingGeminiTemperature: Float = 0.3
    @State private var hasLoadedInitial = false

    // Apply status (replaces old inline banner)
    @State private var applyStatus: ApplyStatus = .idle
    @State private var applyTask: Task<Void, Never>?
    @State private var successDismissTask: Task<Void, Never>?

    // Loaded config snapshot for comparison (avoids stale AIServiceObservable values)
    @State private var loadedConfig: AIService.Config?

    @State private var showClearModelsConfirmation = false
    @State private var clearedBytesMessage: String?

    private var availableModels: [ModelRegistry.ModelInfo] {
        ModelRegistry.availableModels
    }

    public init() {}

    // MARK: - Effective Selections

    private var effectiveSelectedProvider: AIService.Provider {
        pendingProvider ?? aiService.provider
    }

    private var effectiveSelectedMLXModel: String {
        pendingMLXModel ?? aiService.selectedModelId
    }

    // MARK: - Change Detection (reads from loadedConfig snapshot, not polling observable)

    private var hasUnsavedChanges: Bool {
        guard let config = loadedConfig else { return false }

        if let pending = pendingProvider, pending != config.provider {
            return true
        }

        if effectiveSelectedProvider == .openAICompatible {
            if pendingOpenAIKey != config.openAIKey ||
               pendingOpenAIBaseURL != config.openAIBaseURL ||
               pendingOpenAIModel != config.openAIModel ||
               pendingOpenAITemperature != config.openAITemperature {
                return true
            }
        }

        if effectiveSelectedProvider == .localMLX {
            if let pending = pendingMLXModel, pending != config.selectedModelId {
                return true
            }
        }

        if effectiveSelectedProvider == .gemini {
            if pendingGeminiKey != config.geminiKey ||
               pendingGeminiAIModel != config.geminiAIModel ||
               pendingGeminiTemperature != config.geminiTemperature {
                return true
            }
        }

        return false
    }

    private var currentlyUsingDescription: String {
        switch aiService.provider {
        case .localMLX:
            if case .ready(let name) = aiService.status {
                return "Local MLX - \(name)"
            } else if let modelInfo = ModelRegistry.model(for: aiService.selectedModelId) {
                return "Local MLX - \(modelInfo.displayName) (not loaded)"
            } else {
                return "Local MLX - No model configured"
            }
        case .openAICompatible:
            if case .ready = aiService.status {
                return "OpenAI API - \(loadedConfig?.openAIModel ?? "unknown")"
            } else {
                return "OpenAI API - Not connected"
            }
        case .gemini:
            if case .ready = aiService.status {
                let modelRaw = loadedConfig?.geminiAIModel ?? ""
                let modelName = GeminiAIModel(rawValue: modelRaw)?.displayName ?? modelRaw
                return "Gemini - \(modelName)"
            } else {
                return "Gemini - Not connected"
            }
        }
    }

    // MARK: - Body

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // AI Features & Status
                SettingsSection(title: "AI Features", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Enable AI Features")
                                    .font(Theme.Typography.body)
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(aiService.statusColor)
                                        .frame(width: 8, height: 8)
                                    Text(aiService.statusText)
                                        .font(Theme.Typography.caption)
                                        .foregroundColor(Theme.Colors.textSecondary)
                                }
                            }

                            Spacer()

                            if case .error = aiService.status {
                                Button("Retry") {
                                    aiService.setupModel(aiService.selectedModelId)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Toggle("", isOn: $aiEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        if !aiEnabled {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(Theme.Colors.warning)
                                Text("AI is disabled. Model is not loaded and no AI features are available.")
                                    .font(Theme.Typography.caption)
                                    .foregroundColor(Theme.Colors.warning)
                            }
                        }
                    }
                }

                // AI Provider Section
                SettingsSection(title: "AI Provider", icon: "cpu") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Currently using indicator
                        HStack(spacing: 8) {
                            Circle()
                                .fill(aiService.isReady ? Theme.Colors.success : Theme.Colors.textMuted)
                                .frame(width: 8, height: 8)
                            Text("Currently using:")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                            Text(currentlyUsingDescription)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.Colors.textPrimary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.Colors.surface)
                        )

                        // Apply Status Banner (replaces old inline banner)
                        ApplyStatusBanner(
                            status: $applyStatus,
                            onApply: { applyAllChanges() },
                            onDiscard: { Task { await discardAllChanges() } },
                            onRetry: { applyAllChanges() }
                        )

                        Picker("Provider", selection: Binding(
                            get: { effectiveSelectedProvider.rawValue },
                            set: { newValue in
                                pendingProvider = AIService.Provider(rawValue: newValue) ?? .localMLX
                            }
                        )) {
                            Text("Local (MLX)").tag("local-mlx")
                            Text("OpenAI API").tag("openai")
                            Text("Gemini").tag("gemini")
                        }
                        .pickerStyle(.segmented)

                        Text(providerDescription)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Colors.textMuted)

                        if effectiveSelectedProvider == .localMLX {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Theme.Colors.success)
                                    .font(.system(size: 11))
                                Text("Using built-in macOS embeddings — no download needed")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }
                        }
                    }
                }

                // Model Selection Section (for local provider)
                if effectiveSelectedProvider == .localMLX {
                    SettingsSection(title: "Chat Model", icon: "sparkles") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.primary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Select and activate a model for AI chat")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(Theme.Colors.textSecondary)
                                    Text("Models are downloaded from Hugging Face. Larger models provide better quality but require more memory.")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.Colors.textMuted)
                                }
                            }
                            .padding(.bottom, 4)

                            HStack(spacing: 12) {
                                legendItem(color: Theme.Colors.success, text: "Active")
                                legendItem(color: Theme.Colors.secondary, text: "Sleeping")
                                legendItem(color: Theme.Colors.secondary.opacity(0.6), text: "Downloaded")
                                legendItem(color: Theme.Colors.textMuted, text: "Not Downloaded")
                            }
                            .padding(.bottom, 8)

                            ForEach(availableModels) { model in
                                modelRow(model)
                            }
                        }
                    }
                }

                // OpenAI Configuration Section
                if effectiveSelectedProvider == .openAICompatible {
                    SettingsSection(title: "OpenAI Configuration", icon: "key") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Key")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                SecureField("sk-...", text: $pendingOpenAIKey)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.Colors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(pendingOpenAIKey != (loadedConfig?.openAIKey ?? "") ? Theme.Colors.warning : Theme.Colors.border, lineWidth: 1)
                                    )
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Base URL (optional)")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                TextField("https://api.openai.com/v1", text: $pendingOpenAIBaseURL)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.Colors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(pendingOpenAIBaseURL != (loadedConfig?.openAIBaseURL ?? "") ? Theme.Colors.warning : Theme.Colors.border, lineWidth: 1)
                                    )

                                Text("Leave empty for default OpenAI endpoint")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                TextField("gpt-4o-mini", text: $pendingOpenAIModel)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.Colors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(pendingOpenAIModel != (loadedConfig?.openAIModel ?? "") ? Theme.Colors.warning : Theme.Colors.border, lineWidth: 1)
                                    )
                            }

                            temperatureSlider

                            // Test connection button
                            HStack(spacing: 8) {
                                Button {
                                    testConnectionWithPendingValues()
                                } label: {
                                    if aiService.isTestingConnection {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 14, height: 14)
                                            Text("Testing...")
                                        }
                                    } else {
                                        HStack(spacing: 6) {
                                            Image(systemName: "antenna.radiowaves.left.and.right")
                                                .font(.system(size: 12))
                                            Text("Test Connection")
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(pendingOpenAIKey.isEmpty || aiService.isTestingConnection)

                                Text("Tests with your entered values (before applying)")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            if let result = aiService.connectionTestResult {
                                connectionTestResultView(result)
                            }
                        }
                    }
                }

                // Gemini Configuration Section
                if effectiveSelectedProvider == .gemini {
                    SettingsSection(title: "Gemini Configuration", icon: "key") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("API Key")
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.Colors.textPrimary)

                                    if transcriptionProvider == "gemini-cloud" {
                                        HStack(spacing: 4) {
                                            Image(systemName: "link")
                                                .font(.system(size: 8))
                                            Text("Shared with Transcription")
                                        }
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundColor(Theme.Colors.primary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(Theme.Colors.primaryMuted)
                                        )
                                    }
                                }

                                SecureField("Enter your Gemini API key", text: $pendingGeminiKey)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.Colors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(pendingGeminiKey != (loadedConfig?.geminiKey ?? "") ? Theme.Colors.warning : Theme.Colors.border, lineWidth: 1)
                                    )
                                    .onChange(of: pendingGeminiKey) { _, newValue in
                                        if transcriptionProvider == "gemini-cloud" {
                                            geminiAPIKey = newValue
                                        }
                                    }

                                Link("Get API key from Google AI Studio",
                                     destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.primary)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("AI Model")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                Picker("", selection: $pendingGeminiAIModel) {
                                    ForEach(GeminiAIModel.allCases, id: \.rawValue) { model in
                                        Text(model.displayName).tag(model.rawValue)
                                    }
                                }
                                .labelsHidden()

                                if let model = GeminiAIModel(rawValue: pendingGeminiAIModel) {
                                    Text(model.description)
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.Colors.textMuted)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Temperature")
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.Colors.textPrimary)
                                    Spacer()
                                    Text(String(format: "%.1f", pendingGeminiTemperature))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(pendingGeminiTemperature != (loadedConfig?.geminiTemperature ?? 0.3) ? Theme.Colors.warning : Theme.Colors.textSecondary)
                                }

                                Slider(value: $pendingGeminiTemperature, in: 0.0...2.0, step: 0.1)
                                    .tint(pendingGeminiTemperature != (loadedConfig?.geminiTemperature ?? 0.3) ? Theme.Colors.warning : Theme.Colors.primary)

                                Text("Lower = more factual (0.3 recommended for summaries), higher = more creative")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            HStack(spacing: 8) {
                                Button {
                                    testGeminiConnectionWithPendingValues()
                                } label: {
                                    if aiService.isTestingConnection {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 14, height: 14)
                                            Text("Testing...")
                                        }
                                    } else {
                                        HStack(spacing: 6) {
                                            Image(systemName: "antenna.radiowaves.left.and.right")
                                                .font(.system(size: 12))
                                            Text("Test Connection")
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(pendingGeminiKey.isEmpty || aiService.isTestingConnection)

                                Text("Tests with your entered API key (before applying)")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            if let result = aiService.connectionTestResult {
                                connectionTestResultView(result)
                            }

                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 14))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Cloud Processing")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.orange)
                                    Text("Text will be sent to Google's servers for AI processing. Requires internet connection and may incur API usage fees.")
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.Colors.textMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }

                // Data & Storage
                SettingsSection(title: "Data & Storage", icon: "internaldrive") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: "Auto-index new transcripts",
                            subtitle: "Automatically index transcripts for AI search when created",
                            isOn: $autoIndexTranscripts
                        )

                        Divider()

                        SettingsToggle(
                            title: "Auto-generate summary",
                            subtitle: "Automatically create AI summary when transcript is ready",
                            isOn: $autoGenerateSummary
                        )

                        Divider()

                        SettingsToggle(
                            title: "Auto-generate action items",
                            subtitle: "Automatically extract action items when transcript is ready",
                            isOn: $autoGenerateActionItems
                        )

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Indexed Recordings")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)
                                if aiService.isIndexingLoading {
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .controlSize(.mini)
                                        Text("Loading index...")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.Colors.textMuted)
                                    }
                                } else {
                                    Text("\(aiService.indexedCount) recordings indexed for AI search")
                                        .font(.system(size: 11))
                                        .foregroundColor(Theme.Colors.textMuted)
                                }
                            }

                            Spacer()

                            Button {
                                rebuildIndex()
                            } label: {
                                if isRebuildingIndex {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Rebuild")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isRebuildingIndex)
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Storage Location")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)
                                Text(modelStoragePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.Colors.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button("Reveal") {
                                revealModelStorage()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Downloaded Models")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)
                                Text(aiService.cachedModelsSizeFormatted)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            Spacer()

                            Button {
                                showClearModelsConfirmation = true
                            } label: {
                                if aiService.isClearingModels {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Clear All")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(Theme.Colors.error)
                            .disabled(aiService.isClearingModels || aiService.cachedModelsSize == 0)
                        }

                        if let message = clearedBytesMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Theme.Colors.success)
                                    .font(.system(size: 12))
                                Text(message)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.success)
                            }
                        }

                        if effectiveSelectedProvider == .localMLX {
                            Divider()
                            memoryManagementContent
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
        .alert("Clear All AI Models?", isPresented: $showClearModelsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                clearAllModels()
            }
        } message: {
            Text("This will delete all downloaded AI models (\(aiService.cachedModelsSizeFormatted)) and free up disk space. You can download models again anytime.")
        }
        .task {
            await initializePendingState()
        }
        .onChange(of: hasUnsavedChanges) { _, hasChanges in
            updateBannerForChanges(hasChanges)
        }
        .onChange(of: geminiAPIKey) { _, newValue in
            if transcriptionProvider == "gemini-cloud" && effectiveSelectedProvider == .gemini {
                pendingGeminiKey = newValue
            }
        }
        .alert("Rebuild Failed", isPresented: Binding(
            get: { rebuildError != nil },
            set: { if !$0 { rebuildError = nil } }
        )) {
            Button("OK", role: .cancel) { rebuildError = nil }
        } message: {
            Text(rebuildError ?? "An unknown error occurred while rebuilding the index.")
        }
        .alert("Clear Models Failed", isPresented: Binding(
            get: { clearModelsError != nil },
            set: { if !$0 { clearModelsError = nil } }
        )) {
            Button("OK", role: .cancel) { clearModelsError = nil }
        } message: {
            Text(clearModelsError ?? "An unknown error occurred while clearing models.")
        }
    }

    // MARK: - Temperature Slider

    @ViewBuilder
    private var temperatureSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Temperature")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.textPrimary)
                Spacer()
                Text(String(format: "%.1f", pendingOpenAITemperature))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(pendingOpenAITemperature != (loadedConfig?.openAITemperature ?? 1.0) ? Theme.Colors.warning : Theme.Colors.textSecondary)
            }

            Slider(value: $pendingOpenAITemperature, in: 0.0...2.0, step: 0.1)
                .tint(pendingOpenAITemperature != (loadedConfig?.openAITemperature ?? 1.0) ? Theme.Colors.warning : Theme.Colors.primary)

            Text("Lower = more deterministic, higher = more creative (default: 1.0)")
                .font(.system(size: 11))
                .foregroundColor(Theme.Colors.textMuted)
        }
    }

    // MARK: - Memory Management Section

    @ViewBuilder
    private var memoryManagementContent: some View {
        Group {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-unload Model When Idle")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Colors.textPrimary)
                    Text("Free ~3GB of memory when AI isn't being used")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Colors.textMuted)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { aiService.autoUnloadEnabled },
                    set: { newValue in
                        aiService.setAutoUnload(enabled: newValue, minutes: aiService.autoUnloadMinutes)
                    }
                ))
                .toggleStyle(.switch)
                .tint(Theme.Colors.primary)
                .labelsHidden()
            }

            if aiService.autoUnloadEnabled {
                Divider()

                HStack {
                    Text("Unload After")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Colors.textPrimary)

                    Spacer()

                    Picker("", selection: Binding(
                        get: { aiService.autoUnloadMinutes },
                        set: { newValue in
                            aiService.setAutoUnload(enabled: aiService.autoUnloadEnabled, minutes: newValue)
                        }
                    )) {
                        Text("2 minutes").tag(2)
                        Text("5 minutes").tag(5)
                        Text("10 minutes").tag(10)
                        Text("30 minutes").tag(30)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }

                Text("The model will reload automatically when you use AI features.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.textMuted)
            }

            if case .unloadedToSaveMemory(let modelName) = aiService.status {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundColor(Theme.Colors.primary)
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model is sleeping")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.Colors.textPrimary)
                        Text("\(modelName) was unloaded to save memory")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Colors.textMuted)
                    }

                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.Colors.primaryMuted)
                )
            }
        }
    }

    // MARK: - Legend Item

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(Theme.Colors.textMuted)
        }
    }

    // MARK: - Tier Badge

    private func tierBadge(_ tier: ModelRegistry.Tier) -> some View {
        let (color, bgColor): (Color, Color) = {
            switch tier {
            case .tiny:
                return (Theme.Colors.textSecondary, Theme.Colors.surface)
            case .light:
                return (Theme.Colors.secondary, Theme.Colors.secondaryMuted)
            case .standard:
                return (Theme.Colors.primary, Theme.Colors.primaryMuted)
            case .pro:
                return (Theme.Colors.warning, Theme.Colors.warningMuted)
            }
        }()

        return Text(tier.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(bgColor)
            )
    }

    // MARK: - Model Row

    private func modelRow(_ model: ModelRegistry.ModelInfo) -> some View {
        let isCurrentModel = aiService.selectedModelId == model.id
        let isCached = aiService.isModelCached(model.id)
        let isActive = isCurrentModel && aiService.isReady
        let isSleeping = isCurrentModel && aiService.isUnloadedToSaveMemory
        let isPendingSelection = pendingMLXModel == model.id && model.id != aiService.selectedModelId
        let isPendingInitialLoad = isCurrentModel && isCached && aiService.isIndexingLoading && !aiService.isReady
        let isCurrentlyLoading = isCurrentModel && aiService.isLoading || isPendingInitialLoad

        return HStack(spacing: 12) {
            // Radio button style indicator
            ZStack {
                Circle()
                    .stroke(isActive ? Theme.Colors.success :
                           (isSleeping ? Theme.Colors.secondary :
                           (isPendingSelection ? Theme.Colors.warning :
                           (isCached ? Theme.Colors.secondary : Theme.Colors.textMuted))), lineWidth: 2)
                    .frame(width: 18, height: 18)

                if isActive {
                    Circle()
                        .fill(Theme.Colors.success)
                        .frame(width: 10, height: 10)
                } else if isSleeping {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 8))
                        .foregroundColor(Theme.Colors.secondary)
                } else if isPendingSelection {
                    Circle()
                        .fill(Theme.Colors.warning)
                        .frame(width: 10, height: 10)
                } else if isCurrentlyLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                }
            }

            // Model info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: isActive || isSleeping || isPendingSelection ? .semibold : .medium))
                        .foregroundColor(isActive ? Theme.Colors.success :
                                        (isSleeping ? Theme.Colors.secondary :
                                        (isPendingSelection ? Theme.Colors.warning : Theme.Colors.textPrimary)))

                    tierBadge(model.tier)

                    if model.isDefault {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text("Default")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.Colors.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.primaryMuted)
                        )
                    }

                    if isActive {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8))
                            Text("Active")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.success)
                        )
                    }

                    if isSleeping {
                        HStack(spacing: 2) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 8))
                            Text("Sleeping")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.secondary)
                        )
                    }

                    if isPendingSelection {
                        HStack(spacing: 2) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 8))
                            Text("Pending")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Theme.Colors.warning)
                        )
                    }
                }

                Text(model.description)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.textMuted)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 9))
                        Text(model.sizeString)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Colors.textMuted)

                    HStack(spacing: 4) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 9))
                        Text(String(format: "%.1f GB RAM", model.memoryGB))
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Colors.textMuted)

                    if isCached {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                            Text("Downloaded")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.Colors.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 9))
                            Text("Not Downloaded")
                        }
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.textMuted)
                    }
                }
            }

            Spacer()

            // Action buttons
            if isActive {
                VStack(spacing: 2) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.Colors.success)
                    Text("In Use")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.Colors.success)
                }
            } else if isSleeping {
                VStack(spacing: 2) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.Colors.secondary)
                    Text("Sleeping")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.Colors.secondary)
                }
            } else if isPendingSelection {
                Button {
                    pendingMLXModel = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12))
                        Text("Undo")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.Colors.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .stroke(Theme.Colors.warning, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Cancel selection")
            } else if isCurrentlyLoading {
                VStack(spacing: 2) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.Colors.textMuted)
                }
            } else if aiService.isLoading {
                EmptyView()
            } else if isCached {
                // FIX: Cached model "Activate" now only sets pending, doesn't immediately load
                Button {
                    pendingMLXModel = model.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12))
                        Text("Activate")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Theme.Colors.primary)
                    )
                }
                .buttonStyle(.plain)
                .help("Activate this model (click Apply to load)")
            } else {
                // Not downloaded - Download starts immediately (takes minutes),
                // but model is not activated until Apply
                Button {
                    pendingMLXModel = model.id
                    aiService.setupModel(model.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12))
                        Text("Download")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.Colors.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .stroke(Theme.Colors.primary, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Download and select this model (\(model.sizeString))")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Theme.Colors.success.opacity(0.08) :
                      (isSleeping ? Theme.Colors.secondary.opacity(0.08) :
                      (isPendingSelection ? Theme.Colors.warning.opacity(0.08) :
                      (isCached ? Theme.Colors.secondary.opacity(0.05) : Theme.Colors.background))))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Theme.Colors.success.opacity(0.4) :
                        (isSleeping ? Theme.Colors.secondary.opacity(0.5) :
                        (isPendingSelection ? Theme.Colors.warning.opacity(0.5) :
                        (isCached ? Theme.Colors.secondary.opacity(0.2) : Theme.Colors.borderSubtle))),
                        lineWidth: isActive || isSleeping || isPendingSelection ? 2 : 1)
        )
    }

    // MARK: - Computed Properties

    private var providerDescription: String {
        switch effectiveSelectedProvider {
        case .localMLX:
            return "Uses Apple's MLX framework for on-device AI. Best for Apple Silicon Macs. Your data stays private."
        case .openAICompatible:
            return "Uses OpenAI's API. Requires internet connection and API key. Faster but data is sent to OpenAI."
        case .gemini:
            return "Uses Google's Gemini API. Requires API key. Fast and cost-effective for text tasks."
        }
    }

    private var modelStoragePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cache/huggingface/hub").path
    }

    // MARK: - Views

    @ViewBuilder
    private func connectionTestResultView(_ result: AIServiceObservable.ConnectionTestResult) -> some View {
        HStack(spacing: 6) {
            switch result {
            case .success(let modelCount):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
                if modelCount > 0 {
                    Text("Connected! (\(modelCount) models available)")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                } else {
                    Text("Connected!")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                }
            case .failure(let message):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 14))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func initializePendingState() async {
        guard !hasLoadedInitial else { return }
        let config = await AIService.shared.currentConfig
        loadedConfig = config
        pendingOpenAIKey = config.openAIKey
        pendingOpenAIBaseURL = config.openAIBaseURL
        pendingOpenAIModel = config.openAIModel
        pendingOpenAITemperature = config.openAITemperature
        pendingGeminiKey = config.geminiKey
        pendingGeminiAIModel = config.geminiAIModel
        pendingGeminiTemperature = config.geminiTemperature
        // If Gemini AI key is empty but transcription key is set, sync it
        if config.geminiKey.isEmpty && !geminiAPIKey.isEmpty {
            pendingGeminiKey = geminiAPIKey
        }
        pendingProvider = nil
        pendingMLXModel = nil
        hasLoadedInitial = true
        fileRagLog("[AISettings] Initialized pending state from service config")
    }

    private func discardAllChanges() async {
        // Cancel any in-flight apply
        applyTask?.cancel()
        applyTask = nil
        successDismissTask?.cancel()
        successDismissTask = nil

        let config = await AIService.shared.currentConfig
        loadedConfig = config
        pendingProvider = nil
        pendingMLXModel = nil
        pendingOpenAIKey = config.openAIKey
        pendingOpenAIBaseURL = config.openAIBaseURL
        pendingOpenAIModel = config.openAIModel
        pendingOpenAITemperature = config.openAITemperature
        pendingGeminiKey = config.geminiKey
        pendingGeminiAIModel = config.geminiAIModel
        pendingGeminiTemperature = config.geminiTemperature
        applyStatus = .idle
        aiService.clearConnectionTestResult()
        fileRagLog("[AISettings] Discarded all pending changes")
    }

    private func updateBannerForChanges(_ hasChanges: Bool) {
        switch applyStatus {
        case .applying, .success:
            return
        case .error:
            if hasChanges {
                applyStatus = .hasChanges(description: unsavedChangesDescription)
            }
            return
        default:
            break
        }

        if hasChanges {
            applyStatus = .hasChanges(description: unsavedChangesDescription)
        } else {
            applyStatus = .idle
        }
    }

    private var unsavedChangesDescription: String {
        var changes: [String] = []

        if let pending = pendingProvider, pending != (loadedConfig?.provider ?? .localMLX) {
            let name: String
            switch pending {
            case .localMLX: name = "Local MLX"
            case .openAICompatible: name = "OpenAI API"
            case .gemini: name = "Gemini"
            }
            changes.append("Provider: \(name)")
        }

        if effectiveSelectedProvider == .openAICompatible {
            if pendingOpenAIKey != (loadedConfig?.openAIKey ?? "") { changes.append("API Key") }
            if pendingOpenAIBaseURL != (loadedConfig?.openAIBaseURL ?? "") { changes.append("Base URL") }
            if pendingOpenAIModel != (loadedConfig?.openAIModel ?? "") { changes.append("Model: \(pendingOpenAIModel)") }
            if pendingOpenAITemperature != (loadedConfig?.openAITemperature ?? 1.0) { changes.append("Temperature: \(String(format: "%.1f", pendingOpenAITemperature))") }
        }

        if effectiveSelectedProvider == .localMLX {
            if let pending = pendingMLXModel, pending != (loadedConfig?.selectedModelId ?? "") {
                if let modelInfo = ModelRegistry.model(for: pending) {
                    changes.append("Model: \(modelInfo.displayName)")
                } else {
                    changes.append("Model changed")
                }
            }
        }

        if effectiveSelectedProvider == .gemini {
            if pendingGeminiKey != (loadedConfig?.geminiKey ?? "") { changes.append("API Key") }
            if pendingGeminiAIModel != (loadedConfig?.geminiAIModel ?? "") {
                if let model = GeminiAIModel(rawValue: pendingGeminiAIModel) {
                    changes.append("Model: \(model.displayName)")
                } else {
                    changes.append("Model changed")
                }
            }
            if pendingGeminiTemperature != (loadedConfig?.geminiTemperature ?? 0.3) { changes.append("Temperature: \(String(format: "%.1f", pendingGeminiTemperature))") }
        }

        return changes.isEmpty ? "Configuration changes" : changes.joined(separator: ", ")
    }

    private func applyAllChanges() {
        // Cancel any previous apply
        applyTask?.cancel()
        successDismissTask?.cancel()

        applyStatus = .applying
        fileRagLog("[AISettings] applyAllChanges called")

        applyTask = Task {
            do {
                let targetProvider = pendingProvider ?? aiService.provider

                if targetProvider == .openAICompatible && !pendingOpenAIKey.isEmpty {
                    fileRagLog("[AISettings] Configuring OpenAI with settings (temperature: \(pendingOpenAITemperature))")
                    try await AIService.shared.configureOpenAI(
                        apiKey: pendingOpenAIKey,
                        baseURL: pendingOpenAIBaseURL.isEmpty ? nil : pendingOpenAIBaseURL,
                        model: pendingOpenAIModel,
                        temperature: pendingOpenAITemperature
                    )
                }

                if targetProvider == .localMLX {
                    if let newModel = pendingMLXModel, newModel != aiService.selectedModelId {
                        fileRagLog("[AISettings] Setting up MLX model: \(newModel)")
                        try await AIService.shared.setupModel(newModel)
                    } else if let newProvider = pendingProvider, newProvider != aiService.provider {
                        fileRagLog("[AISettings] Switching to localMLX provider")
                        try await AIService.shared.setProvider(.localMLX)
                    }
                }

                if targetProvider == .gemini && !pendingGeminiKey.isEmpty {
                    fileRagLog("[AISettings] Configuring Gemini with model: \(pendingGeminiAIModel)")
                    try await AIService.shared.configureGemini(
                        apiKey: pendingGeminiKey,
                        model: pendingGeminiAIModel,
                        temperature: pendingGeminiTemperature
                    )

                    if transcriptionProvider == "gemini-cloud" {
                        geminiAPIKey = pendingGeminiKey
                    }
                }

                if Task.isCancelled { return }

                // Refresh loadedConfig from the service after successful apply
                let savedConfig = await AIService.shared.currentConfig

                await MainActor.run {
                    loadedConfig = savedConfig
                    pendingProvider = nil
                    pendingMLXModel = nil
                    pendingOpenAIKey = savedConfig.openAIKey
                    pendingOpenAIBaseURL = savedConfig.openAIBaseURL
                    pendingOpenAIModel = savedConfig.openAIModel
                    pendingOpenAITemperature = savedConfig.openAITemperature
                    pendingGeminiKey = savedConfig.geminiKey
                    pendingGeminiAIModel = savedConfig.geminiAIModel
                    pendingGeminiTemperature = savedConfig.geminiTemperature
                    aiService.clearConnectionTestResult()

                    applyStatus = .success(message: "AI settings applied successfully.")
                    fileRagLog("[AISettings] applyAllChanges completed successfully")

                    successDismissTask = Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if !Task.isCancelled {
                            applyStatus = .idle
                        }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    applyStatus = .error(message: error.localizedDescription)
                    fileRagLog("[AISettings] applyAllChanges failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func testConnectionWithPendingValues() {
        guard !pendingOpenAIKey.isEmpty else { return }
        aiService.clearConnectionTestResult()
        aiService.testOpenAIConnectionWith(apiKey: pendingOpenAIKey, baseURL: pendingOpenAIBaseURL)
    }

    private func testGeminiConnectionWithPendingValues() {
        guard !pendingGeminiKey.isEmpty else { return }
        aiService.clearConnectionTestResult()
        aiService.testGeminiConnectionWith(apiKey: pendingGeminiKey)
    }

    private func rebuildIndex() {
        isRebuildingIndex = true
        fileRagLog("[AISettings] Rebuild button clicked")
        Task {
            do {
                try await AIService.shared.rebuildIndex()
                fileRagLog("[AISettings] Rebuild completed successfully")
            } catch {
                fileRagLog("[AISettings] Rebuild failed: \(error.localizedDescription)")
                await MainActor.run {
                    rebuildError = error.localizedDescription
                }
            }
            await MainActor.run {
                isRebuildingIndex = false
            }
        }
    }

    private func revealModelStorage() {
        let url = URL(fileURLWithPath: modelStoragePath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    private func clearAllModels() {
        clearedBytesMessage = nil
        Task {
            do {
                let bytesCleared = try await aiService.clearAllModels()
                await MainActor.run {
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file
                    clearedBytesMessage = "Cleared \(formatter.string(fromByteCount: bytesCleared))"

                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        clearedBytesMessage = nil
                    }
                }
                fileRagLog("[AISettings] Cleared \(bytesCleared) bytes of AI models")
            } catch {
                await MainActor.run {
                    clearModelsError = error.localizedDescription
                }
                fileRagLog("[AISettings] Failed to clear models: \(error.localizedDescription)")
            }
        }
    }
}
