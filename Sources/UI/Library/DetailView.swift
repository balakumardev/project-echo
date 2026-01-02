import SwiftUI
import AppKit
import AVFoundation
import Database

// MARK: - Detail View

@available(macOS 14.0, *)
struct DetailView: View {
    let recording: Recording?

    var body: some View {
        if let recording = recording {
            RecordingDetailView(recording: recording)
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
    @StateObject private var viewModel = RecordingDetailViewModel()
    @State private var showDeleteConfirmation = false

    var body: some View {
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
        .background(Theme.Colors.background)
        .task(id: recording.id) {
            await viewModel.loadRecording(recording)
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
