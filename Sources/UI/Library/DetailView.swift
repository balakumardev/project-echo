import SwiftUI
import AppKit
import AVFoundation
import Database

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
        mainContent
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
                    viewModel: viewModel,
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
    @ObservedObject var viewModel: RecordingDetailViewModel
    let onDelete: () -> Void
    @AppStorage("aiEnabled") private var aiEnabled = true
    @EnvironmentObject private var aiService: AIServiceObservable

    /// Whether AI can be used (ready or sleeping - sleeping will auto-reload)
    private var canUseAI: Bool {
        aiService.canUseAI
    }

    /// Whether AI is currently loading or downloading
    private var isAILoading: Bool {
        aiService.isLoading
    }

    /// The display title - shows generated title if available, otherwise recording title
    private var displayTitle: String {
        viewModel.generatedTitle ?? recording.title
    }

    var body: some View {
        SurfaceCard(padding: Theme.Spacing.xl) {
            HStack(spacing: Theme.Spacing.lg) {
                // App icon
                AppIconBadge(appName: recording.appName, size: 44)

                // Info
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    // Title with generate/regenerate button
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(displayTitle)
                            .font(Theme.Typography.title1)
                            .foregroundColor(Theme.Colors.textPrimary)

                        // Title generation button (only show if AI is enabled and has transcript)
                        if aiEnabled && recording.hasTranscript {
                            if viewModel.isLoadingTitle {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .help("Generating title...")
                            } else {
                                Button {
                                    viewModel.generateTitle(for: recording)
                                } label: {
                                    Image(systemName: viewModel.generatedTitle != nil ? "arrow.clockwise" : "sparkles")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(canUseAI ? Theme.Colors.primary : Theme.Colors.textMuted)
                                }
                                .buttonStyle(.plain)
                                .disabled(!canUseAI)
                                .help(viewModel.generatedTitle != nil
                                    ? (canUseAI ? "Regenerate title with AI" : aiService.aiStatusHelpText)
                                    : (canUseAI ? "Generate title with AI" : aiService.aiStatusHelpText))
                            }
                        }
                    }

                    HStack(spacing: Theme.Spacing.lg) {
                        Label(recording.date.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                        Label(Formatters.formatDurationAbbreviated(recording.duration), systemImage: "clock")
                        if let app = recording.appName {
                            Label(app, systemImage: "app.fill")
                        }
                    }
                    .font(Theme.Typography.callout)
                    .foregroundColor(Theme.Colors.textSecondary)

                    // Title error message
                    if let error = viewModel.titleError {
                        Text(error)
                            .font(Theme.Typography.caption)
                            .foregroundColor(.orange)
                    }
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
        panel.nameFieldStringValue = displayTitle + "." + (ext.isEmpty ? "m4a" : ext)

        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? FileManager.default.copyItem(at: recording.fileURL, to: url)
            }
        }
    }
}

