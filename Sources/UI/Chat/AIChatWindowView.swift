import SwiftUI
import Database
import Intelligence

/// Standalone AI Chat window view for cross-recording search
@available(macOS 14.0, *)
public struct AIChatWindowView: View {
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var aiService = AIServiceObservable()
    @State private var recordings: [Recording] = []
    @State private var isLoadingRecordings = false
    @AppStorage("aiEnabled") private var aiEnabled = true

    @Environment(\.dismiss) private var dismiss

    public init() {
        // Default init - uses AIService.shared via ChatViewModel
    }

    public var body: some View {
        Group {
            if !aiEnabled {
                AIDisabledView()
            } else {
                VStack(spacing: 0) {
                    // Title bar
                    titleBar

                    // Recording filter
                    recordingFilterBar

                    Divider()
                        .background(Theme.Colors.border)

                    // Chat view
                    ChatView(
                        viewModel: viewModel,
                        onCitationTap: handleCitationTap
                    )
                }
                .task {
                    await loadRecordings()
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
        .background(Theme.Colors.background)
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            // App branding
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.Colors.primary)

                Text("Engram")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("AI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Colors.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Theme.Colors.primaryMuted)
                    )
            }

            Spacer()

            // Status indicator
            Circle()
                .fill(aiService.statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)

            // Close button
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Colors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.surface)
    }

    private var statusText: String {
        switch aiService.status {
        case .ready:
            return "Ready"
        case .loading, .downloading:
            return "Loading..."
        case .error:
            return "Error"
        case .notConfigured:
            return "Not configured"
        }
    }

    // MARK: - Recording Filter Bar

    private var recordingFilterBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 14))
                .foregroundColor(Theme.Colors.textSecondary)

            Picker("", selection: $viewModel.recordingFilter) {
                Text("All Recordings")
                    .tag(nil as Int64?)

                if !recordings.isEmpty {
                    Divider()

                    ForEach(recordings, id: \.id) { recording in
                        Text(recording.title)
                            .tag(recording.id as Int64?)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 250)

            Spacer()

            if isLoadingRecordings {
                ProgressView()
                    .controlSize(.small)
            }

            // Show indexed count (use aiService which polls periodically)
            if aiService.isIndexingLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading...")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)
                }
            } else {
                Text("\(aiService.indexedCount) indexed")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.surface.opacity(0.5))
    }

    // MARK: - Actions

    private func loadRecordings() async {
        isLoadingRecordings = true
        defer { isLoadingRecordings = false }

        do {
            let db = try await DatabaseManager()
            let allRecordings = try await db.getAllRecordings()
            // Only show recordings with transcripts
            recordings = allRecordings.filter { $0.hasTranscript }
        } catch {
            print("Failed to load recordings: \(error)")
        }
    }

    private func handleCitationTap(_ citation: Citation) {
        // TODO: Open the recording at the citation timestamp
        print("Citation tapped: \(citation.recordingTitle) at \(citation.timestamp)")
    }
}

// MARK: - AI Disabled View

@available(macOS 14.0, *)
struct AIDisabledView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(systemName: "sparkles.slash")
                .font(.system(size: 48))
                .foregroundColor(Theme.Colors.textMuted)

            VStack(spacing: Theme.Spacing.sm) {
                Text("AI Features Disabled")
                    .font(Theme.Typography.title2)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("Enable AI features in Settings to use AI Chat")
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button("Open Settings") {
                openSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
struct AIChatWindowView_Previews: PreviewProvider {
    static var previews: some View {
        AIChatWindowView()
            .frame(width: 500, height: 600)
    }
}
#endif
