import SwiftUI
import Database
import Intelligence

/// Unified chat panel that lives in LibraryView's right sidebar.
/// Supports scoping queries to a specific recording or searching across all recordings.
@available(macOS 14.0, *)
struct UnifiedChatPanel: View {
    @ObservedObject var chatViewModel: ChatViewModel
    let selectedRecording: Recording?
    let recordings: [Recording]
    var onCitationTap: ((Citation) -> Void)?
    @AppStorage("showChatPanel_v2") private var showChatPanel = false

    @State private var isLoadingRecordings = false
    @State private var userManuallySetScope = false

    /// Custom binding for the scope Picker that tracks manual user changes
    private var scopeBinding: Binding<Int64?> {
        Binding(
            get: { chatViewModel.recordingFilter },
            set: { newValue in
                userManuallySetScope = true
                chatViewModel.recordingFilter = newValue
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            panelHeader

            // Scope selector
            scopeSelector

            // Chat content
            ChatView(viewModel: chatViewModel, onCitationTap: onCitationTap)
        }
        .background(Theme.Colors.surface)
        .onChange(of: selectedRecording?.id) { _, newId in
            // New recording selected — reset manual flag and auto-follow
            userManuallySetScope = false
            if let newId = newId {
                chatViewModel.recordingFilter = newId
            } else {
                chatViewModel.recordingFilter = nil
            }
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Colors.primary)

            Text("AI Chat")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)

            Spacer()

            Button {
                showChatPanel = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Colors.textMuted)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.Colors.surfaceHover))
            }
            .buttonStyle(.plain)
            .help("Close chat panel")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .overlay(
            Rectangle()
                .fill(Theme.Colors.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Scope Selector

    private var scopeSelector: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.textSecondary)

            Picker("", selection: scopeBinding) {
                Text("All Recordings")
                    .tag(nil as Int64?)

                if let selected = selectedRecording {
                    Divider()
                    Text(selected.title)
                        .tag(selected.id as Int64?)
                }

                let transcribed = recordings.filter { rec in
                    rec.hasTranscript && rec.id != selectedRecording?.id
                }
                if !transcribed.isEmpty {
                    Divider()
                    ForEach(transcribed, id: \.id) { recording in
                        Text(recording.title)
                            .tag(recording.id as Int64?)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.surface.opacity(0.5))
        .overlay(
            Rectangle()
                .fill(Theme.Colors.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
