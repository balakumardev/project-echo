import SwiftUI
import AppKit
import Database
import Intelligence

// MARK: - Transcript Section

@available(macOS 14.0, *)
struct TranscriptSection: View {
    let recording: Recording
    @ObservedObject var viewModel: RecordingDetailViewModel
    @AppStorage("aiEnabled") private var aiEnabled = true
    @StateObject private var aiService = AIServiceObservable()

    // MARK: - AI Status Helpers

    /// Whether AI is ready for operations
    private var isAIReady: Bool {
        aiService.isReady
    }

    /// Whether AI can be used (ready or sleeping - sleeping will auto-reload)
    private var canUseAI: Bool {
        aiService.canUseAI
    }

    /// Whether AI is currently loading or downloading
    private var isAILoading: Bool {
        aiService.isLoading
    }

    /// User-friendly help text explaining why AI buttons might be disabled
    private var aiStatusHelpText: String {
        switch aiService.status {
        case .notConfigured:
            return "AI model not configured. Go to Settings to set up an AI model."
        case .unloadedToSaveMemory(let name):
            return "\(name) is sleeping to save memory. It will reload when you use AI features."
        case .downloading(let progress, let name):
            return "Downloading \(name)... \(Int(progress * 100))%. Please wait."
        case .loading(let name):
            return "Loading \(name)... Please wait a moment."
        case .ready:
            return "AI is ready"
        case .error(let message):
            return "AI error: \(message). Try restarting the app or check Settings."
        }
    }

    /// Short status indicator text for the loading state
    private var aiLoadingStatusText: String {
        switch aiService.status {
        case .downloading(let progress, let name):
            return "Downloading \(name)... \(Int(progress * 100))%"
        case .loading(let name):
            return "Loading \(name)..."
        default:
            return ""
        }
    }

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

                    if aiEnabled {
                        // Show AI loading status if AI is initializing
                        if isAILoading {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                Text(aiLoadingStatusText)
                                    .font(Theme.Typography.caption)
                            }
                            .foregroundColor(Theme.Colors.textMuted)
                        }

                        // Summarize button - prominent style to encourage use
                        if viewModel.isLoadingSummary {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Summarizing...")
                                    .font(Theme.Typography.caption)
                            }
                            .foregroundColor(Theme.Colors.textMuted)
                        } else {
                            PillButton(
                                "Summarize",
                                icon: "sparkles",
                                style: .secondary,
                                isCompact: true,
                                isDisabled: !canUseAI
                            ) {
                                viewModel.generateSummary(for: recording)
                            }
                            .help(canUseAI ? "Generate AI summary" : aiStatusHelpText)
                        }

                        // Action Items button - prominent style to encourage use
                        if viewModel.isLoadingActionItems {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Extracting...")
                                    .font(Theme.Typography.caption)
                            }
                            .foregroundColor(Theme.Colors.textMuted)
                        } else {
                            PillButton(
                                "Action Items",
                                icon: "checklist",
                                style: .secondary,
                                isCompact: true,
                                isDisabled: !canUseAI
                            ) {
                                viewModel.generateActionItems(for: recording)
                            }
                            .help(canUseAI ? "Extract action items" : aiStatusHelpText)
                        }
                    }

                    PillButton("Copy All", icon: "doc.on.doc", style: .ghost, isCompact: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript.fullText, forType: .string)
                    }
                }
            }

            // AI Summary section (shown when summary exists or is loading)
            if viewModel.isLoadingSummary || viewModel.summary != nil || viewModel.summaryError != nil {
                SummarySection(recording: recording, viewModel: viewModel)
            }

            // AI Action Items section (shown when action items exist or is loading)
            if viewModel.isLoadingActionItems || viewModel.actionItems != nil || viewModel.actionItemsError != nil {
                ActionItemsSection(recording: recording, viewModel: viewModel)
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
                    },
                    totalCount: viewModel.totalSegmentCount,
                    hasMore: viewModel.hasMoreSegments,
                    isLoadingMore: viewModel.isLoadingMoreSegments,
                    onLoadMore: {
                        Task {
                            await viewModel.loadMoreSegments()
                        }
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

// MARK: - AI Error View

/// A reusable error view for AI operations with helpful context and retry option
@available(macOS 14.0, *)
struct AIErrorView: View {
    let error: String
    let onRetry: (() -> Void)?

    init(error: String, onRetry: (() -> Void)? = nil) {
        self.error = error
        self.onRetry = onRetry
    }

    /// Parse the error to provide user-friendly messages and guidance
    private var errorInfo: (message: String, guidance: String, icon: String) {
        let lowercasedError = error.lowercased()

        if lowercasedError.contains("model not loaded") || lowercasedError.contains("not configured") {
            return (
                message: "AI model is not ready",
                guidance: "Please wait for the model to finish loading, or go to Settings to configure an AI model.",
                icon: "cpu"
            )
        } else if lowercasedError.contains("downloading") {
            return (
                message: "AI model is downloading",
                guidance: "Please wait for the download to complete. This may take a few minutes.",
                icon: "arrow.down.circle"
            )
        } else if lowercasedError.contains("loading") {
            return (
                message: "AI model is loading",
                guidance: "Please wait a moment for the model to load into memory.",
                icon: "hourglass"
            )
        } else if lowercasedError.contains("memory") || lowercasedError.contains("ram") {
            return (
                message: "Not enough memory",
                guidance: "Try closing other applications to free up memory, or select a smaller model in Settings.",
                icon: "memorychip"
            )
        } else if lowercasedError.contains("network") || lowercasedError.contains("internet") || lowercasedError.contains("connection") {
            return (
                message: "Network error",
                guidance: "Please check your internet connection and try again.",
                icon: "wifi.exclamationmark"
            )
        } else if lowercasedError.contains("api") || lowercasedError.contains("key") || lowercasedError.contains("unauthorized") {
            return (
                message: "API configuration error",
                guidance: "Please check your API key and settings in the Settings panel.",
                icon: "key"
            )
        } else {
            return (
                message: "AI operation failed",
                guidance: error,
                icon: "exclamationmark.triangle"
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: errorInfo.icon)
                    .foregroundColor(.orange)
                    .font(.system(size: 16))

                Text(errorInfo.message)
                    .font(Theme.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.Colors.textPrimary)
            }

            Text(errorInfo.guidance)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let onRetry = onRetry {
                HStack {
                    Spacer()
                    PillButton("Try Again", icon: "arrow.clockwise", style: .secondary, isCompact: true) {
                        onRetry()
                    }
                }
                .padding(.top, Theme.Spacing.xs)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Summary Section

@available(macOS 14.0, *)
struct SummarySection: View {
    let recording: Recording
    @ObservedObject var viewModel: RecordingDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Header
            HStack {
                Label("AI Summary", systemImage: "sparkles")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.primary)

                Spacer()

                if viewModel.summary != nil {
                    PillButton("Copy", icon: "doc.on.doc", style: .ghost, isCompact: true) {
                        if let summary = viewModel.summary {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary, forType: .string)
                        }
                    }
                }

                // Close button to dismiss summary
                Button {
                    viewModel.cancelSummary()
                    viewModel.summary = nil
                    viewModel.summaryError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help("Dismiss summary")
            }

            // Content
            if let error = viewModel.summaryError {
                AIErrorView(
                    error: error,
                    onRetry: {
                        viewModel.generateSummary(for: recording)
                    }
                )
            } else if let summary = viewModel.summary {
                Text(markdownAttributedString(from: summary))
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.Colors.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(Theme.Colors.primary.opacity(0.2), lineWidth: 1)
                    )
            } else if viewModel.isLoadingSummary {
                HStack {
                    ProgressView()
                    Text("Generating summary...")
                        .font(Theme.Typography.body)
                        .foregroundColor(Theme.Colors.textSecondary)
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceBackground()
            }
        }
    }

    /// Parse markdown string into AttributedString for proper rendering
    /// Supports bold (**text**), italic (*text*), and other markdown formatting
    private func markdownAttributedString(from text: String) -> AttributedString {
        do {
            // Use AttributedString's markdown parsing
            let attributed = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
            return attributed
        } catch {
            // Fallback to plain text if markdown parsing fails
            return AttributedString(text)
        }
    }
}

// MARK: - Action Items Section

@available(macOS 14.0, *)
struct ActionItemsSection: View {
    let recording: Recording
    @ObservedObject var viewModel: RecordingDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Header
            HStack {
                Label("Action Items", systemImage: "checklist")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.secondary)

                Spacer()

                if viewModel.actionItems != nil {
                    PillButton("Copy", icon: "doc.on.doc", style: .ghost, isCompact: true) {
                        if let actionItems = viewModel.actionItems {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(actionItems, forType: .string)
                        }
                    }
                }

                // Close button to dismiss action items
                Button {
                    viewModel.cancelActionItems()
                    viewModel.actionItems = nil
                    viewModel.actionItemsError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help("Dismiss action items")
            }

            // Content
            if let error = viewModel.actionItemsError {
                AIErrorView(
                    error: error,
                    onRetry: {
                        viewModel.generateActionItems(for: recording)
                    }
                )
            } else if let actionItems = viewModel.actionItems {
                Text(markdownAttributedString(from: actionItems))
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.Colors.secondary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(Theme.Colors.secondary.opacity(0.2), lineWidth: 1)
                    )
            } else if viewModel.isLoadingActionItems {
                HStack {
                    ProgressView()
                    Text("Extracting action items...")
                        .font(Theme.Typography.body)
                        .foregroundColor(Theme.Colors.textSecondary)
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surfaceBackground()
            }
        }
    }

    /// Parse markdown string into AttributedString for proper rendering
    private func markdownAttributedString(from text: String) -> AttributedString {
        do {
            let attributed = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
            return attributed
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Transcript Content

@available(macOS 14.0, *)
struct TranscriptContent: View {
    let transcript: Transcript
    let segments: [TranscriptSegment]
    let onSeek: (TimeInterval) -> Void
    let totalCount: Int
    let hasMore: Bool
    let isLoadingMore: Bool
    let onLoadMore: () -> Void

    init(
        transcript: Transcript,
        segments: [TranscriptSegment],
        onSeek: @escaping (TimeInterval) -> Void,
        totalCount: Int = 0,
        hasMore: Bool = false,
        isLoadingMore: Bool = false,
        onLoadMore: @escaping () -> Void = {}
    ) {
        self.transcript = transcript
        self.segments = segments
        self.onSeek = onSeek
        self.totalCount = totalCount
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.onLoadMore = onLoadMore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Speaker legend
            if !uniqueSpeakers.isEmpty {
                SpeakerLegend(speakers: uniqueSpeakers)
                    .padding(.bottom, Theme.Spacing.sm)
            }

            // Pagination info
            if totalCount > 0 {
                HStack {
                    Text("Showing \(segments.count) of \(totalCount) segments")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)
                    Spacer()
                }
            }

            // Segments or full text - using LazyVStack for efficient rendering
            if segments.isEmpty {
                Text(transcript.fullText)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceBackground()
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(segments, id: \.id) { segment in
                        TranscriptSegmentRow(segment: segment, onSeek: onSeek)
                            .onAppear {
                                // Load more when approaching the end
                                if segment.id == segments.last?.id && hasMore {
                                    onLoadMore()
                                }
                            }
                    }

                    // Load more indicator/button
                    if hasMore {
                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading more segments...")
                                    .font(Theme.Typography.caption)
                                    .foregroundColor(Theme.Colors.textMuted)
                                Spacer()
                            }
                            .padding(Theme.Spacing.md)
                        } else {
                            Button {
                                onLoadMore()
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("Load More Segments", systemImage: "arrow.down.circle")
                                        .font(Theme.Typography.callout)
                                    Spacer()
                                }
                                .padding(Theme.Spacing.md)
                                .background(Theme.Colors.surface)
                                .cornerRadius(Theme.Radius.md)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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

