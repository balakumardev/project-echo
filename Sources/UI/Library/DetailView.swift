import SwiftUI
import AppKit
import AVFoundation
import Database
import Intelligence

// MARK: - Detail View

@available(macOS 14.0, *)
struct DetailView: View {
    let recording: Recording?
    @Binding var seekToTimestamp: TimeInterval?

    init(recording: Recording?, seekToTimestamp: Binding<TimeInterval?> = .constant(nil)) {
        self.recording = recording
        self._seekToTimestamp = seekToTimestamp
    }

    var body: some View {
        if let recording = recording {
            RecordingDetailView(recording: recording, seekToTimestamp: $seekToTimestamp)
                .id(recording.id)
        } else {
            EmptyDetailView()
        }
    }
}

// MARK: - Recording Detail View

@available(macOS 14.0, *)
struct RecordingDetailView: View {
    let recording: Recording
    @Binding var seekToTimestamp: TimeInterval?
    @StateObject private var viewModel = RecordingDetailViewModel()
    @State private var showDeleteConfirmation = false
    @AppStorage("showChatPanel_v2") private var showChatPanel = false
    @AppStorage("aiEnabled") private var aiEnabled = true

    init(recording: Recording, seekToTimestamp: Binding<TimeInterval?> = .constant(nil)) {
        self.recording = recording
        self._seekToTimestamp = seekToTimestamp
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main content
            mainContent

            // Chat panel
            if showChatPanel {
                Divider()
                ChatPanel(recording: recording)
                    .frame(width: 350)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showChatPanel)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if aiEnabled {
                    Button {
                        showChatPanel.toggle()
                    } label: {
                        Image(systemName: showChatPanel ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    }
                    .help("Toggle AI Chat")
                }
            }
        }
        .task(id: recording.id) {
            await viewModel.loadRecording(recording)
        }
        .onChange(of: viewModel.audioPlayer) { _, player in
            // Seek to pending timestamp when player becomes available
            if let player = player, let timestamp = seekToTimestamp {
                player.currentTime = min(timestamp, player.duration)
                player.play()
                seekToTimestamp = nil
            }
        }
        .confirmationDialog("Delete Recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteRecording(recording)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete '\(recording.title)' and its transcript.")
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Header card
                DetailHeader(
                    recording: recording,
                    onDelete: {
                        showDeleteConfirmation = true
                    }
                )

                // Video player if video exists, otherwise audio player
                if let videoURL = recording.videoURL {
                    VideoPlayerCard(videoURL: videoURL)
                } else if let player = viewModel.audioPlayer {
                    AudioPlayerCard(
                        player: player,
                        recording: recording,
                        onSeek: { time in
                            player.currentTime = time
                        }
                    )
                }

                // Transcript section
                TranscriptSection(
                    recording: recording,
                    viewModel: viewModel
                )
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(minWidth: 500) // Prevent content from being squished when chat panel is open
        .background(Theme.Colors.background)
    }
}

// MARK: - Detail Header

@available(macOS 14.0, *)
struct DetailHeader: View {
    let recording: Recording
    let onDelete: () -> Void

    var body: some View {
        GlassCard(padding: Theme.Spacing.xl) {
            HStack(spacing: Theme.Spacing.lg) {
                // App icon
                AppIconBadge(appName: recording.appName, size: 64)

                // Info
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(recording.title)
                        .font(Theme.Typography.title1)
                        .foregroundColor(Theme.Colors.textPrimary)

                    HStack(spacing: Theme.Spacing.lg) {
                        Label(recording.date.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                        Label(Formatters.formatDurationAbbreviated(recording.duration), systemImage: "clock")
                        if let app = recording.appName {
                            Label(app, systemImage: "app.fill")
                        }
                    }
                    .font(Theme.Typography.callout)
                    .foregroundColor(Theme.Colors.textSecondary)
                }

                Spacer()

                // Actions
                HStack(spacing: Theme.Spacing.sm) {
                    // Show in Finder button
                    IconButton(icon: "folder", size: 36, style: .ghost) {
                        NSWorkspace.shared.activateFileViewerSelecting([recording.fileURL])
                    }
                    .help("Show in Finder")

                    IconButton(icon: "square.and.arrow.up", size: 36, style: .ghost) {
                        exportRecording()
                    }
                    IconButton(icon: "trash", size: 36, style: .danger) {
                        onDelete()
                    }
                }
            }
        }
    }

    private func exportRecording() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.audio, .movie]
        let ext = recording.fileURL.pathExtension
        panel.nameFieldStringValue = recording.title + "." + (ext.isEmpty ? "m4a" : ext)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? FileManager.default.copyItem(at: recording.fileURL, to: url)
            }
        }
    }
}

// MARK: - Chat Panel

/// A wrapper view that initializes the ChatViewModel for a specific recording
/// Uses AIService.shared for AI operations
@available(macOS 14.0, *)
struct ChatPanel: View {
    let recording: Recording
    @StateObject private var chatViewModel: ChatViewModel

    init(recording: Recording) {
        self.recording = recording
        // ChatViewModel now uses AIService.shared directly
        _chatViewModel = StateObject(wrappedValue: ChatViewModel(recording: recording))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeader

            // Chat content
            ChatView(viewModel: chatViewModel)
        }
        .background(Theme.Colors.surface)
    }

    private var chatHeader: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.Colors.primary)

            Text("AI Chat")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)

            Spacer()
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
}
