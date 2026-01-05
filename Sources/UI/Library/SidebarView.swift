import SwiftUI
import AppKit
import Database

// MARK: - Sidebar View

@available(macOS 14.0, *)
struct SidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Binding var selectedRecording: Recording?
    @Binding var searchText: String
    @Binding var selectedFilter: RecordingFilter
    @Binding var selectedSort: RecordingSort
    @Binding var customStartDate: Date?
    @Binding var customEndDate: Date?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SidebarHeader(
                searchText: $searchText,
                onSearch: { query in
                    Task {
                        await viewModel.search(query: query)
                    }
                },
                onRefresh: {
                    Task {
                        await viewModel.refresh()
                    }
                }
            )

            // Filters
            VStack(spacing: Theme.Spacing.sm) {
                FilterChips(
                    selectedFilter: $selectedFilter,
                    customStartDate: $customStartDate,
                    customEndDate: $customEndDate
                )
                    .onChange(of: selectedFilter) { _, _ in
                        // Filter will be applied in filteredRecordings
                    }

                HStack {
                    Spacer()
                    SortMenu(selectedSort: $selectedSort)
                }
                .padding(.horizontal, Theme.Spacing.md)
            }
            .padding(.vertical, Theme.Spacing.sm)

            Divider()
                .background(Theme.Colors.border)

            // Recording list
            if viewModel.isLoading {
                LoadingView()
            } else if filteredRecordings.isEmpty {
                EmptyStateView(hasSearch: !searchText.isEmpty)
            } else {
                RecordingList(
                    recordings: filteredRecordings,
                    selectedRecording: $selectedRecording,
                    onDelete: { recording in
                        Task {
                            await viewModel.deleteRecording(recording)
                            if selectedRecording?.id == recording.id {
                                selectedRecording = nil
                            }
                        }
                    },
                    onExportAudio: exportRecording,
                    onExportTranscript: { recording in
                        Task {
                            await exportTranscript(recording)
                        }
                    },
                    onToggleFavorite: { recording in
                        Task {
                            await viewModel.toggleFavorite(for: recording)
                        }
                    }
                )
            }

            // Footer with branding
            SidebarFooter()
        }
        .background(Theme.Colors.surface)
    }

    private var filteredRecordings: [Recording] {
        var recordings = viewModel.recordings

        // Apply filter
        switch selectedFilter {
        case .all:
            break
        case .today:
            let today = Calendar.current.startOfDay(for: Date())
            recordings = recordings.filter { $0.date >= today }
        case .thisWeek:
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            recordings = recordings.filter { $0.date >= weekAgo }
        case .custom:
            // Custom date range filter
            if let start = customStartDate {
                recordings = recordings.filter { $0.date >= start }
            }
            if let end = customEndDate {
                recordings = recordings.filter { $0.date < end }
            }
        case .hasTranscript:
            recordings = recordings.filter { $0.hasTranscript }
        case .favorites:
            recordings = recordings.filter { $0.isFavorite }
        }

        // Apply sort
        switch selectedSort {
        case .dateDesc:
            recordings.sort { $0.date > $1.date }
        case .dateAsc:
            recordings.sort { $0.date < $1.date }
        case .durationDesc:
            recordings.sort { $0.duration > $1.duration }
        case .durationAsc:
            recordings.sort { $0.duration < $1.duration }
        case .title:
            recordings.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }

        return recordings
    }

    private func exportRecording(_ recording: Recording) {
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

    private func exportTranscript(_ recording: Recording) async {
        if let transcript = await viewModel.getTranscript(for: recording) {
            await MainActor.run {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.nameFieldStringValue = recording.title + ".txt"

                panel.begin { response in
                    if response == .OK, let url = panel.url {
                        try? transcript.fullText.write(to: url, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar Header

@available(macOS 14.0, *)
struct SidebarHeader: View {
    @Binding var searchText: String
    let onSearch: (String) -> Void
    let onRefresh: () -> Void

    @AppStorage("aiEnabled") private var aiEnabled = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Title row with AI controls
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.Colors.primary)

                        Text("Engram")
                            .font(Theme.Typography.title2)
                            .foregroundColor(Theme.Colors.textPrimary)
                    }
                    Text("Your meeting recordings")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)
                }

                Spacer()

                // AI Status and Controls
                HStack(spacing: Theme.Spacing.sm) {
                    // AI Status Indicator
                    AIStatusIndicator(style: .headerBar)

                    // AI Chat Button
                    IconButton(icon: "bubble.left.and.bubble.right", size: 28, style: .ghost) {
                        openWindow(id: "ai-chat")
                    }
                    .help("Open AI Chat")
                    .disabled(!aiEnabled)
                    .opacity(aiEnabled ? 1.0 : 0.5)

                    // Refresh Button
                    IconButton(icon: "arrow.clockwise", size: 28, style: .ghost) {
                        onRefresh()
                    }
                }
            }

            // Search
            SearchField(text: $searchText, placeholder: "Search recordings...") {
                onSearch(searchText)
            }
            .onChange(of: searchText) { _, newValue in
                onSearch(newValue)
            }
        }
        .padding(Theme.Spacing.lg)
    }
}

// MARK: - Recording List

@available(macOS 14.0, *)
struct RecordingList: View {
    let recordings: [Recording]
    @Binding var selectedRecording: Recording?
    let onDelete: (Recording) -> Void
    let onExportAudio: (Recording) -> Void
    let onExportTranscript: (Recording) -> Void
    let onToggleFavorite: (Recording) -> Void

    var body: some View {
        List(recordings, selection: $selectedRecording) { recording in
            RecordingRow(
                recording: recording,
                isSelected: selectedRecording?.id == recording.id
            )
            .tag(recording)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .contextMenu {
                Button {
                    onToggleFavorite(recording)
                } label: {
                    Label(
                        recording.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: recording.isFavorite ? "star.slash" : "star"
                    )
                }

                Divider()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([recording.fileURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }

                Button {
                    onExportAudio(recording)
                } label: {
                    Label("Export Audio", systemImage: "square.and.arrow.up")
                }

                if recording.hasTranscript {
                    Button {
                        onExportTranscript(recording)
                    } label: {
                        Label("Export Transcript", systemImage: "doc.text")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    onDelete(recording)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Status Indicators

/// Compact icon-based status indicators for recording metadata
/// Shows transcript and video status as small, subtle icons
@available(macOS 14.0, *)
struct StatusIndicators: View {
    let hasTranscript: Bool
    let hasVideo: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if hasTranscript {
                Image(systemName: "text.quote")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Colors.success)
                    .opacity(isHovered ? 1.0 : 0.5)
                    .help("Transcribed")
            }

            if hasVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.Colors.primary)
                    .opacity(isHovered ? 1.0 : 0.5)
                    .help("Has video")
            }
        }
        .animation(Theme.Animation.fast, value: isHovered)
    }
}

// MARK: - Recording Row

/// A single recording item in the sidebar list
/// Displays: selection indicator, app icon, title, relative date, duration, status icons, favorite star, file size
@available(macOS 14.0, *)
struct RecordingRow: View {
    let recording: Recording
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Selection indicator - purple bar on left when selected
            RoundedRectangle(cornerRadius: 2)
                .fill(isSelected ? Theme.Colors.primary : .clear)
                .frame(width: 3)

            // App icon badge (reduced size for compact look)
            AppIconBadge(appName: recording.appName, size: 36)

            // Main content - title and metadata
            VStack(alignment: .leading, spacing: 3) {
                // Title row
                Text(recording.title)
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .lineLimit(1)

                // Metadata row - relative date and duration
                HStack(spacing: Theme.Spacing.xs) {
                    // Relative date - tooltip shows full date/time on hover
                    Text(Formatters.formatRelativeDate(recording.date, expanded: false))
                        .help(Formatters.formatRelativeDate(recording.date, expanded: true))

                    Text("•")
                        .foregroundColor(Theme.Colors.textMuted.opacity(0.5))

                    // Duration with monospaced font for alignment
                    Text(Formatters.formatDuration(recording.duration))
                        .fontDesign(.monospaced)
                }
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)
            }

            Spacer(minLength: Theme.Spacing.sm)

            // Status indicators (transcript, video) - subtle icons
            StatusIndicators(
                hasTranscript: recording.hasTranscript,
                hasVideo: recording.hasVideo,
                isHovered: isHovered
            )

            // Favorite star - trailing position
            if recording.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
            }

            // File size - muted, more visible on hover
            Text(Formatters.formatFileSize(recording.fileSize))
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)
                .opacity(isHovered ? 1.0 : 0.7)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.trailing, Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(backgroundColor)
        )
        .scaleEffect(isHovered && !isSelected ? 1.005 : 1.0)
        .animation(Theme.Animation.fast, value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// Background color based on selection and hover state
    private var backgroundColor: Color {
        if isSelected {
            return Theme.Colors.primaryMuted
        }
        if isHovered {
            return Theme.Colors.surfaceHover
        }
        return .clear
    }
}

// MARK: - Sidebar Footer

@available(macOS 14.0, *)
struct SidebarFooter: View {
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(Theme.Colors.primary.opacity(0.6))

            Text("Engram")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.Colors.textMuted)

            Text("•")
                .foregroundColor(Theme.Colors.textMuted.opacity(0.4))

            Text("by Bala Kumar")
                .font(.system(size: 11))
                .foregroundColor(Theme.Colors.textMuted.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.surface.opacity(0.5))
        .opacity(isHovered ? 1.0 : 0.8)
        .onHover { hovering in
            withAnimation(Theme.Animation.fast) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if let url = URL(string: "https://balakumar.dev") {
                NSWorkspace.shared.open(url)
            }
        }
        .help("Visit balakumar.dev")
    }
}
