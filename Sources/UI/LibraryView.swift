import SwiftUI
import AppKit
import AVFoundation
import Database

// MARK: - Main Library View

/// Main library view showing all recordings with modern dark theme
@available(macOS 14.0, *)
public struct LibraryView: View {

    @StateObject private var viewModel = LibraryViewModel()
    @State private var selectedRecording: Recording?
    @State private var searchText = ""
    @State private var selectedFilter: RecordingFilter = .all
    @State private var selectedSort: RecordingSort = .dateDesc

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            SidebarView(
                viewModel: viewModel,
                selectedRecording: $selectedRecording,
                searchText: $searchText,
                selectedFilter: $selectedFilter,
                selectedSort: $selectedSort
            )
            .frame(width: 340)

            // Divider
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 1)

            // Detail view
            DetailView(recording: selectedRecording)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.background)
        .task {
            await viewModel.loadRecordings()
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

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
            // TODO: Implement favorites
            break
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
                // Title
                Text(recording.title)
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .lineLimit(1)

                // Metadata
                HStack(spacing: Theme.Spacing.xs) {
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    Text("•")
                    Text(formatDuration(recording.duration))
                        .fontDesign(.monospaced)
                }
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)

                // Tags
                if recording.appName != nil || recording.hasTranscript {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let app = recording.appName {
                            SmallBadge(text: app, color: Theme.Colors.secondary)
                        }
                        if recording.hasTranscript {
                            SmallBadge(text: "Transcribed", color: Theme.Colors.success)
                        }
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            // File size
            Text(formatFileSize(recording.fileSize))
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// Simple badge without hover effects
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

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                // Header card
                DetailHeader(recording: recording)

                // Audio player
                if let player = viewModel.audioPlayer {
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
    }
}

// MARK: - Detail Header

@available(macOS 14.0, *)
struct DetailHeader: View {
    let recording: Recording

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
                        Label(formatDuration(recording.duration), systemImage: "clock")
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
                        // Delete action
                    }
                }
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: duration) ?? ""
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

// MARK: - Audio Player Card

@available(macOS 14.0, *)
struct AudioPlayerCard: View {
    let player: AVAudioPlayer
    let recording: Recording
    let onSeek: (TimeInterval) -> Void

    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var playbackRate: Float = 1.0
    @State private var volume: Float = 1.0
    @State private var timer: Timer?

    var body: some View {
        GlassCard(padding: Theme.Spacing.lg) {
            VStack(spacing: Theme.Spacing.lg) {
                // Waveform
                WaveformView(
                    progress: player.duration > 0 ? currentTime / player.duration : 0,
                    duration: player.duration,
                    onSeek: { time in
                        player.currentTime = time
                        currentTime = time
                    }
                )

                // Time display
                HStack {
                    Text(formatTime(currentTime))
                        .font(Theme.Typography.monoBody)
                        .foregroundColor(Theme.Colors.textSecondary)

                    Spacer()

                    Text("-" + formatTime(player.duration - currentTime))
                        .font(Theme.Typography.monoBody)
                        .foregroundColor(Theme.Colors.textMuted)
                }

                // Controls
                HStack(spacing: Theme.Spacing.xl) {
                    // Playback rate
                    PlaybackRateButton(rate: $playbackRate) { newRate in
                        player.rate = newRate
                    }

                    Spacer()

                    // Main controls
                    HStack(spacing: Theme.Spacing.lg) {
                        IconButton(icon: "gobackward.10", size: 40, style: .ghost) {
                            player.currentTime = max(0, player.currentTime - 10)
                        }

                        // Play/Pause button
                        Button {
                            togglePlayback()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Theme.Colors.primary)
                                    .frame(width: 56, height: 56)

                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(.white)
                                    .offset(x: isPlaying ? 0 : 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .shadow(color: Theme.Colors.primary.opacity(0.4), radius: 12, y: 4)

                        IconButton(icon: "goforward.10", size: 40, style: .ghost) {
                            player.currentTime = min(player.duration, player.currentTime + 10)
                        }
                    }

                    Spacer()

                    // Volume
                    VolumeControl(volume: $volume) { newVolume in
                        player.volume = newVolume
                    }
                }
            }
        }
        .onAppear {
            startTimer()
        }
        .onDisappear {
            timer?.invalidate()
            player.stop()
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.enableRate = true
            player.rate = playbackRate
            player.play()
        }
        isPlaying.toggle()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] _ in
            Task { @MainActor in
                currentTime = player.currentTime
                if player.currentTime >= player.duration - 0.1 {
                    isPlaying = false
                }
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Playback Rate Button

@available(macOS 14.0, *)
struct PlaybackRateButton: View {
    @Binding var rate: Float
    let onChange: (Float) -> Void

    private let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        Menu {
            ForEach(rates, id: \.self) { r in
                Button {
                    rate = r
                    onChange(r)
                } label: {
                    HStack {
                        Text(formatRate(r))
                        if rate == r {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(formatRate(rate))
                .font(Theme.Typography.monoSmall)
                .fontWeight(.medium)
                .foregroundColor(Theme.Colors.textSecondary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.surfaceHover)
                )
        }
        .menuStyle(.borderlessButton)
    }

    private func formatRate(_ rate: Float) -> String {
        if rate == 1.0 {
            return "1x"
        }
        return String(format: "%.2gx", rate)
    }
}

// MARK: - Volume Control

@available(macOS 14.0, *)
struct VolumeControl: View {
    @Binding var volume: Float
    let onChange: (Float) -> Void

    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if isExpanded {
                Slider(value: $volume, in: 0...1) { _ in
                    onChange(volume)
                }
                .frame(width: 80)
                .tint(Theme.Colors.primary)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button {
                withAnimation(Theme.Animation.spring) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Colors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isExpanded ? Theme.Colors.surfaceHover : .clear)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var volumeIcon: String {
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }
}

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
            } else if recording.hasTranscript {
                PillButton("Load Transcript", icon: "arrow.down.doc", style: .secondary) {
                    Task {
                        await viewModel.loadTranscript(for: recording)
                    }
                }
            } else {
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
                            Text(formatTimestamp(segment.startTime))
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

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Empty States

@available(macOS 14.0, *)
struct EmptyDetailView: View {
    @State private var animationPhase: CGFloat = 0

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            // Animated waveform icon
            ZStack {
                Circle()
                    .fill(Theme.Colors.primaryMuted)
                    .frame(width: 120, height: 120)

                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(Theme.Colors.primary)
                    .scaleEffect(1 + sin(animationPhase) * 0.05)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Text("Select a Recording")
                    .font(Theme.Typography.title2)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("Choose a recording from the sidebar to view details and play audio")
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animationPhase = .pi
            }
        }
    }
}

@available(macOS 14.0, *)
struct EmptyStateView: View {
    let hasSearch: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: hasSearch ? "magnifyingglass" : "waveform.path")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.Colors.textMuted)

            Text(hasSearch ? "No Results" : "No Recordings")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textSecondary)

            Text(hasSearch
                 ? "Try a different search term"
                 : "Start a recording from the menu bar")
                .font(Theme.Typography.callout)
                .foregroundColor(Theme.Colors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@available(macOS 14.0, *)
struct LoadingView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(Theme.Colors.primary)

            Text("Loading recordings...")
                .font(Theme.Typography.callout)
                .foregroundColor(Theme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@available(macOS 14.0, *)
struct TranscriptLoadingView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .tint(Theme.Colors.primary)

            Text("Processing transcript...")
                .font(Theme.Typography.callout)
                .foregroundColor(Theme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xxl)
        .surfaceBackground()
    }
}

@available(macOS 14.0, *)
struct NoTranscriptView: View {
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "text.quote")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(Theme.Colors.textMuted)

            Text("No transcript available")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textSecondary)

            Text("Generate a transcript using on-device AI")
                .font(Theme.Typography.callout)
                .foregroundColor(Theme.Colors.textMuted)

            PillButton("Generate Transcript", icon: "sparkles", style: .primary) {
                onGenerate()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xxl)
        .surfaceBackground()
    }
}
