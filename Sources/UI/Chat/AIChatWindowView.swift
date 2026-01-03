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

    @Environment(\.dismiss) private var dismiss

    public init() {
        // Default init - uses AIService.shared via ChatViewModel
    }

    public var body: some View {
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
        .frame(minWidth: 400, minHeight: 500)
        .background(Theme.Colors.background)
        .task {
            await loadRecordings()
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            Text("AI Chat")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)

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

            // Show indexed count
            Text("\(viewModel.indexedCount) indexed")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)
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
