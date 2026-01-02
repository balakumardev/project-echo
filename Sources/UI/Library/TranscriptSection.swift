import SwiftUI
import AppKit
import Database

// MARK: - Transcript Section

@available(macOS 14.0, *)
struct TranscriptSection: View {
    let recording: Recording
    @ObservedObject var viewModel: RecordingDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Header
            HStack {
                Text("Transcript")
                    .font(Theme.Typography.title3)
                    .foregroundColor(Theme.Colors.textPrimary)

                Spacer()

                if let transcript = viewModel.transcript {
                    Text("\(transcript.fullText.split(separator: " ").count) words")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)

                    PillButton("Copy All", icon: "doc.on.doc", style: .ghost, isCompact: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript.fullText, forType: .string)
                    }
                }
            }

            // Content
            if viewModel.isLoadingTranscript {
                TranscriptLoadingView()
            } else if let transcript = viewModel.transcript {
                TranscriptContent(
                    transcript: transcript,
                    segments: viewModel.segments,
                    onSeek: { time in
                        viewModel.audioPlayer?.currentTime = time
                        viewModel.audioPlayer?.play()
                    }
                )
            } else {
                // No transcript loaded - show generate button
                // (loadRecording already attempted to load from DB, so this means none exists)
                NoTranscriptView {
                    Task {
                        await viewModel.generateTranscript(for: recording)
                    }
                }
            }
        }
    }
}

// MARK: - Transcript Content

@available(macOS 14.0, *)
struct TranscriptContent: View {
    let transcript: Transcript
    let segments: [TranscriptSegment]
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Speaker legend
            if !uniqueSpeakers.isEmpty {
                SpeakerLegend(speakers: uniqueSpeakers)
                    .padding(.bottom, Theme.Spacing.sm)
            }

            // Segments or full text
            if segments.isEmpty {
                Text(transcript.fullText)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceBackground()
            } else {
                ForEach(segments, id: \.id) { segment in
                    TranscriptSegmentRow(segment: segment, onSeek: onSeek)
                }
            }
        }
    }

    private var uniqueSpeakers: [String] {
        Array(Set(segments.map { $0.speaker })).sorted()
    }
}

// MARK: - Transcript Segment Row

@available(macOS 14.0, *)
struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let onSeek: (TimeInterval) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            // Speaker avatar
            SpeakerAvatar(name: segment.speaker, size: 36)

            // Content
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Header
                HStack {
                    Text(segment.speaker)
                        .font(Theme.Typography.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(Theme.Colors.speakerColor(for: segment.speaker))

                    Spacer()

                    // Timestamp button
                    Button {
                        onSeek(segment.startTime)
                    } label: {
                        HStack(spacing: 4) {
                            if isHovered {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 8))
                            }
                            Text(Formatters.formatTimestamp(segment.startTime))
                                .font(Theme.Typography.monoSmall)
                        }
                        .foregroundColor(isHovered ? Theme.Colors.primary : Theme.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                // Text
                Text(segment.text)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isHovered ? Theme.Colors.surfaceHover : Theme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
        )
        .animation(Theme.Animation.fast, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

