// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import SwiftUI
import Intelligence

// MARK: - Transcription Settings View

@available(macOS 14.0, *)
public struct TranscriptionSettingsView: View {
    // Current persisted values (source of truth for comparison)
    @AppStorage("transcriptionProvider") private var transcriptionProvider = "whisperkit"
    @AppStorage("geminiAPIKey") private var geminiAPIKey = ""
    @AppStorage("geminiModel") private var geminiModel = "gemini-3-flash-preview"
    @AppStorage("whisperModel") private var whisperModel = "small.en"

    // Pending state for deferred apply
    @State private var pendingProvider: String = "whisperkit"
    @State private var pendingWhisperModel: String = "small.en"
    @State private var pendingGeminiAPIKey: String = ""
    @State private var pendingGeminiModel: String = "gemini-3-flash-preview"
    @State private var hasLoadedInitial = false

    // Apply status — .idle and .hasChanges are derived from state, not stored.
    // Only .applying, .success, and .error are explicitly set.
    @State private var applyOverrideStatus: ApplyStatus? = nil
    @State private var applyTask: Task<Void, Never>?
    @State private var successDismissTask: Task<Void, Never>?

    public init() {}

    // MARK: - Derived Apply Status

    /// Combines the override status (applying/success/error) with auto-detected changes
    private var applyStatus: ApplyStatus {
        if let override = applyOverrideStatus {
            return override
        }
        guard hasLoadedInitial else { return .idle }
        if hasUnsavedChanges {
            return .hasChanges(description: unsavedChangesDescription)
        }
        return .idle
    }

    // MARK: - Change Detection

    private var hasUnsavedChanges: Bool {
        guard hasLoadedInitial else { return false }
        if pendingProvider != transcriptionProvider { return true }
        if pendingProvider == "whisperkit" && pendingWhisperModel != whisperModel { return true }
        if pendingProvider == "gemini-cloud" {
            if pendingGeminiAPIKey != geminiAPIKey { return true }
            if pendingGeminiModel != geminiModel { return true }
        }
        return false
    }

    private var unsavedChangesDescription: String {
        var changes: [String] = []
        if pendingProvider != transcriptionProvider {
            changes.append("Provider: \(pendingProvider == "whisperkit" ? "Local" : "Gemini Cloud")")
        }
        if pendingProvider == "whisperkit" && pendingWhisperModel != whisperModel {
            changes.append("Model: \(pendingWhisperModel)")
        }
        if pendingProvider == "gemini-cloud" {
            if pendingGeminiAPIKey != geminiAPIKey { changes.append("API Key") }
            if pendingGeminiModel != geminiModel { changes.append("Model: \(pendingGeminiModel)") }
        }
        return changes.isEmpty ? "Configuration changes" : changes.joined(separator: ", ")
    }

    // MARK: - Body

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Apply Status Banner
                ApplyStatusBanner(
                    status: Binding(
                        get: { applyStatus },
                        set: { applyOverrideStatus = $0 == .idle ? nil : $0 }
                    ),
                    onApply: { applyChanges() },
                    onDiscard: { discardChanges() },
                    onRetry: { applyChanges() }
                )

                // Provider Selection
                SettingsSection(title: "Provider", icon: "text.quote") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose how your recordings are transcribed")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Colors.textMuted)

                        Picker("", selection: $pendingProvider) {
                            Text("Local (WhisperKit)").tag("whisperkit")
                            Text("Gemini Cloud").tag("gemini-cloud")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                // Local Provider Settings
                if pendingProvider == "whisperkit" {
                    SettingsSection(title: "WhisperKit Model", icon: "cpu") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("", selection: $pendingWhisperModel) {
                                Text("Tiny").tag("tiny.en")
                                Text("Base").tag("base.en")
                                Text("Small (Recommended)").tag("small.en")
                                Text("Medium").tag("medium.en")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("Larger models are more accurate but use more resources.")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)

                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundColor(Theme.Colors.success)
                                    .font(.system(size: 11))
                                Text("Private: Audio never leaves your device")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }
                        }
                    }
                }

                // Gemini Cloud Settings
                if pendingProvider == "gemini-cloud" {
                    SettingsSection(title: "Gemini Cloud", icon: "cloud") {
                        VStack(alignment: .leading, spacing: 12) {
                            // API Key
                            VStack(alignment: .leading, spacing: 4) {
                                Text("API Key")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                SecureField("Enter your Gemini API key", text: $pendingGeminiAPIKey)
                                    .textFieldStyle(.roundedBorder)

                                Link("Get API key from Google AI Studio",
                                     destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.primary)
                            }

                            Divider()

                            // Model Selection
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                Picker("", selection: $pendingGeminiModel) {
                                    Text("Gemini 3 Pro (Best quality)").tag("gemini-3-pro-preview")
                                    Text("Gemini 3 Flash (Recommended)").tag("gemini-3-flash-preview")
                                    Text("Gemini 2.5 Flash (Balanced)").tag("gemini-2.5-flash")
                                    Text("Gemini 2.5 Flash Lite (Cheapest)").tag("gemini-2.5-flash-lite")
                                }
                                .labelsHidden()

                                Text(geminiModelDescription)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }

                            Divider()

                            // Privacy Warning
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 14))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Cloud Processing")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.orange)
                                    Text("Audio will be sent to Google's servers for transcription. Requires internet connection and may incur API usage fees.")
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
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
        .task {
            initializePendingState()
        }
    }

    // MARK: - Computed Properties

    private var geminiModelDescription: String {
        switch pendingGeminiModel {
        case "gemini-3-pro-preview":
            return "Highest accuracy, advanced reasoning. Best for complex meetings."
        case "gemini-3-flash-preview":
            return "Good balance of speed and quality. Recommended for most use cases."
        case "gemini-2.5-flash":
            return "Stable release with good quality. Reliable for everyday use."
        case "gemini-2.5-flash-lite":
            return "Fastest and lowest cost ($0.30/M audio tokens). Great for most meetings."
        default:
            return "Select a model for cloud transcription."
        }
    }

    // MARK: - Actions

    private func initializePendingState() {
        pendingProvider = transcriptionProvider
        pendingWhisperModel = whisperModel
        pendingGeminiAPIKey = geminiAPIKey
        pendingGeminiModel = geminiModel
        hasLoadedInitial = true
    }

    private func discardChanges() {
        // Cancel any in-flight apply
        applyTask?.cancel()
        applyTask = nil
        successDismissTask?.cancel()
        successDismissTask = nil

        // Reset pending to current persisted values
        pendingProvider = transcriptionProvider
        pendingWhisperModel = whisperModel
        pendingGeminiAPIKey = geminiAPIKey
        pendingGeminiModel = geminiModel
        applyOverrideStatus = nil
    }

    private func applyChanges() {
        // Cancel any previous apply
        applyTask?.cancel()
        successDismissTask?.cancel()

        applyOverrideStatus = .applying
        fileRagLog("[TranscriptionSettings] Applying changes: provider=\(pendingProvider), whisperModel=\(pendingWhisperModel)")

        applyTask = Task {
            do {
                // Detect if whisper model changed (needs reload)
                let whisperModelChanged = pendingWhisperModel != whisperModel

                // Write pending values to UserDefaults
                transcriptionProvider = pendingProvider
                whisperModel = pendingWhisperModel
                geminiAPIKey = pendingGeminiAPIKey
                geminiModel = pendingGeminiModel

                // Push config to running engine + reload model if needed
                try await SettingsEnvironment.transcriptionDelegate?.applyTranscriptionConfig()

                if Task.isCancelled { return }

                await MainActor.run {
                    let message = whisperModelChanged && pendingProvider == "whisperkit"
                        ? "Transcription settings applied. Model reloaded."
                        : "Transcription settings applied."
                    applyOverrideStatus = .success(message: message)
                    fileRagLog("[TranscriptionSettings] Applied successfully")

                    // Auto-dismiss success after 3 seconds
                    successDismissTask = Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if !Task.isCancelled {
                            applyOverrideStatus = nil
                        }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    applyOverrideStatus = .error(message: error.localizedDescription)
                    fileRagLog("[TranscriptionSettings] Apply failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
