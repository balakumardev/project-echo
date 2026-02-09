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
            // Header — title + search
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

            // Filter chips — full width
            FilterChips(
                selectedFilter: $selectedFilter,
                customStartDate: $customStartDate,
                customEndDate: $customEndDate
            )
            .onChange(of: selectedFilter) { _, _ in }
            .padding(.bottom, Theme.Spacing.sm)

            // Info bar — recording count + sort control
            SortInfoBar(
                recordingCount: filteredRecordings.count,
                selectedSort: $selectedSort
            )

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

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Title row
            HStack {
                Text("Recordings")
                    .font(Theme.Typography.title3)
                    .foregroundColor(Theme.Colors.textPrimary)

                Spacer()

                HStack(spacing: Theme.Spacing.sm) {
                    AIStatusIndicator(style: .headerBar)

                    IconButton(icon: "arrow.clockwise", size: 26, style: .ghost) {
                        onRefresh()
                    }
                    .help("Refresh")
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
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.sm)
    }
}

// MARK: - Sort Info Bar

/// Shows recording count on the left and a sort dropdown on the right.
/// Sits between filters and the recording list for easy discoverability.
@available(macOS 14.0, *)
struct SortInfoBar: View {
    let recordingCount: Int
    @Binding var selectedSort: RecordingSort

    var body: some View {
        HStack {
            Text("\(recordingCount) recording\(recordingCount == 1 ? "" : "s")")
                .font(Theme.Typography.subheadline)
                .foregroundColor(Theme.Colors.textMuted)

            Spacer()

            SortMenu(selectedSort: $selectedSort)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.background.opacity(0.5))
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
            .listRowInsets(EdgeInsets(top: 2, leading: Theme.Spacing.sm, bottom: 2, trailing: Theme.Spacing.sm))
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

// MARK: - Recording Row

/// A single recording item in the sidebar list.
/// Features: colored left accent bar, app icon, title, metadata, colorful status badges.
@available(macOS 14.0, *)
struct RecordingRow: View {
    let recording: Recording
    let isSelected: Bool

    @State private var isHovered = false
    @ObservedObject private var processingTracker = ProcessingTracker.shared

    var body: some View {
        HStack(spacing: 0) {
            // Colored left accent bar based on meeting app
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3)
                .padding(.vertical, Theme.Spacing.xs)

            HStack(spacing: Theme.Spacing.md) {
                // App icon badge
                AppIconBadge(appName: recording.appName, size: 34)

                // Main content
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    // Title row
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(recording.title)
                            .font(Theme.Typography.headline)
                            .foregroundColor(isSelected ? .white : Theme.Colors.textPrimary)
                            .lineLimit(2)

                        if recording.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.yellow)
                        }
                    }

                    // Metadata row — date and duration
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(Formatters.formatRelativeDate(recording.date, expanded: false))
                            .help(Formatters.formatRelativeDate(recording.date, expanded: true))

                        Text("\u{00B7}")
                            .foregroundColor(Theme.Colors.textMuted.opacity(0.4))

                        Text(Formatters.formatDuration(recording.duration))
                            .fontDesign(.monospaced)
                    }
                    .font(Theme.Typography.subheadline)
                    .foregroundColor(isSelected ? .white.opacity(0.7) : Theme.Colors.textMuted)

                    // Status badges — processing + static
                    let activeTypes = processingTracker.processingTypes(for: recording.id)
                    if !activeTypes.isEmpty || recording.hasTranscript || recording.hasVideo {
                        HStack(spacing: Theme.Spacing.xs) {
                            // Active processing badges (animated)
                            if activeTypes.contains(.transcription) {
                                ProcessingBadge("Transcribing", color: .blue)
                            }
                            if activeTypes.contains(.summary) {
                                ProcessingBadge("Summarizing", color: Theme.Colors.primary)
                            }
                            if activeTypes.contains(.actionItems) {
                                ProcessingBadge("Extracting", color: Theme.Colors.secondary)
                            }

                            // Static badges (only show if not currently processing that type)
                            if recording.hasTranscript && !activeTypes.contains(.transcription) {
                                StatusBadge("Transcribed", color: Theme.Colors.success, icon: "text.quote")
                            }
                            if recording.hasVideo {
                                StatusBadge("Video", color: Theme.Colors.secondary, icon: "video.fill")
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.Spacing.sm)
        }
        .padding(.trailing, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(isSelected ? Theme.Colors.primary.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .animation(Theme.Animation.fast, value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// App-based accent color for the left bar
    private var accentColor: Color {
        guard let app = recording.appName?.lowercased() else { return Theme.Colors.primary }
        if app.contains("zoom") { return Color(hex: "2D8CFF") }
        if app.contains("teams") { return Color(hex: "5B5FC7") }
        if app.contains("meet") || app.contains("chrome") { return Color(hex: "00AC47") }
        if app.contains("slack") { return Color(hex: "E01E5A") }
        if app.contains("discord") { return Color(hex: "5865F2") }
        return Theme.Colors.primary
    }

    private var backgroundColor: Color {
        if isSelected {
            return Theme.Colors.primary.opacity(0.2)
        }
        if isHovered {
            return Theme.Colors.surfaceHover
        }
        return Theme.Colors.background.opacity(0.3)
    }
}
