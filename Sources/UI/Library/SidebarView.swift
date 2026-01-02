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
                FilterChips(selectedFilter: $selectedFilter)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recordings")
                        .font(Theme.Typography.title2)
                        .foregroundColor(Theme.Colors.textPrimary)
                    Text("Your meeting recordings")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)
                }

                Spacer()

                IconButton(icon: "arrow.clockwise", size: 28, style: .ghost) {
                    onRefresh()
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

@available(macOS 14.0, *)
struct RecordingRow: View {
    let recording: Recording
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Selection indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(isSelected ? Theme.Colors.primary : .clear)
                .frame(width: 3)

            // App icon
            AppIconBadge(appName: recording.appName, size: 40)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                // Title with favorite indicator
                HStack(spacing: 4) {
                    if recording.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                    }
                    Text(recording.title)
                        .font(Theme.Typography.headline)
                        .foregroundColor(Theme.Colors.textPrimary)
                        .lineLimit(1)
                }

                // Metadata
                HStack(spacing: Theme.Spacing.xs) {
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    Text("•")
                    Text(Formatters.formatDuration(recording.duration))
                        .fontDesign(.monospaced)
                }
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)

                // Tags
                if recording.appName != nil || recording.hasTranscript || recording.hasVideo {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let app = recording.appName {
                            SmallBadge(text: app, color: Theme.Colors.secondary)
                        }
                        if recording.hasVideo {
                            SmallBadge(text: "Video", color: Theme.Colors.primary)
                        }
                        if recording.hasTranscript {
                            SmallBadge(text: "Transcribed", color: Theme.Colors.success)
                        }
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            // File size
            Text(Formatters.formatFileSize(recording.fileSize))
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.Colors.textMuted)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.trailing, Theme.Spacing.md)
        .background(isSelected ? Theme.Colors.primaryMuted : .clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Small Badge

@available(macOS 14.0, *)
struct SmallBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}
