import SwiftUI
import AppKit
import AVFoundation
import AVKit
import Database

// MARK: - Recording Video URL Helper

extension Recording {
    /// Derive the video file URL from the audio recording URL
    /// Audio: Echo_2026-01-02T10-30-00-0800.mov
    /// Video: Echo_2026-01-02T10-30-00-0800_video.mov
    var videoURL: URL? {
        let audioFileName = fileURL.deletingPathExtension().lastPathComponent
        let videoFileName = audioFileName + "_video.mov"
        let videoURL = fileURL.deletingLastPathComponent().appendingPathComponent(videoFileName)

        // Check if video file exists
        if FileManager.default.fileExists(atPath: videoURL.path) {
            return videoURL
        }
        return nil
    }

    var hasVideo: Bool {
        videoURL != nil
    }
}

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

                // Video player (if video exists)
                if let videoURL = recording.videoURL {
                    VideoPlayerCard(videoURL: videoURL)
                }

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

// MARK: - Video Player Card

/// A wrapper class to hold AVPlayer and manage its lifecycle
@available(macOS 14.0, *)
@MainActor
final class VideoPlayerModel: ObservableObject {
    @Published var player: AVPlayer
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var showPlaybackIndicator = false
    @Published var isFullscreen = false

    private var timeObserver: Any?
    private var fullscreenWindow: NSWindow?
    let videoURL: URL

    init(url: URL) {
        self.videoURL = url
        self.player = AVPlayer(url: url)
        setupObservers()
    }

    private func setupObservers() {
        // Get duration when ready
        let playerRef = player
        Task {
            if let item = playerRef.currentItem,
               let durationValue = try? await item.asset.load(.duration) {
                self.duration = durationValue.seconds.isNaN ? 0 : durationValue.seconds
            }
        }

        // Add time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentTime = time.seconds.isNaN ? 0 : time.seconds

                // Check if playback ended
                if let duration = self.player.currentItem?.duration.seconds,
                   !duration.isNaN && self.currentTime >= duration - 0.1 {
                    self.isPlaying = false
                }
            }
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            // If at end, restart from beginning
            if currentTime >= duration - 0.5 {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()

        // Show playback indicator briefly
        showPlaybackIndicator = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showPlaybackIndicator = false
        }
    }

    func seek(by seconds: Double) {
        let newTime = max(0, min(duration, currentTime + seconds))
        let cmTime = CMTime(seconds: newTime, preferredTimescale: 600)
        player.seek(to: cmTime)
    }

    func seek(to percentage: Double) {
        let newTime = percentage * duration
        let cmTime = CMTime(seconds: newTime, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggleFullscreen() {
        if isFullscreen {
            exitFullscreen()
        } else {
            enterFullscreen()
        }
    }

    private func enterFullscreen() {
        guard fullscreenWindow == nil else { return }

        // Create fullscreen window
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]

        // Create fullscreen content view
        let contentView = NSHostingView(rootView: FullscreenVideoPlayer(model: self))
        window.contentView = contentView

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)

        fullscreenWindow = window
        isFullscreen = true
    }

    func exitFullscreen() {
        if let window = fullscreenWindow {
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            window.close()
            fullscreenWindow = nil
        }
        isFullscreen = false
    }

    nonisolated func cleanup() {
        // Note: deinit can't be async, so we just let AVPlayer clean itself up
    }
}

/// Native AVPlayerView wrapper
@available(macOS 14.0, *)
struct NativeVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.videoGravity = .resizeAspect
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// Fullscreen video player view
@available(macOS 14.0, *)
struct FullscreenVideoPlayer: View {
    @ObservedObject var model: VideoPlayerModel
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Video
            Color.black
            NativeVideoPlayerView(player: model.player)
                .aspectRatio(16/9, contentMode: .fit)

            // Click to play/pause
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    model.togglePlayback()
                    showControlsTemporarily()
                }

            // Play/Pause indicator overlay
            if model.showPlaybackIndicator {
                ZStack {
                    Circle()
                        .fill(.black.opacity(0.6))
                        .frame(width: 80, height: 80)

                    Image(systemName: model.isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(.white)
                }
                .transition(.opacity.combined(with: .scale))
            }

            // Controls overlay
            if showControls {
                VStack {
                    // Top bar
                    HStack {
                        Spacer()
                        Button {
                            model.exitFullscreen()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Circle().fill(.black.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                        .padding()
                    }

                    Spacer()

                    // Bottom controls
                    VStack(spacing: 12) {
                        // Progress bar
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.white.opacity(0.3))
                                    .frame(height: 6)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.white)
                                    .frame(width: model.duration > 0 ? geometry.size.width * CGFloat(model.currentTime / model.duration) : 0, height: 6)
                            }
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let percentage = min(max(0, value.location.x / geometry.size.width), 1)
                                        model.seek(to: Double(percentage))
                                        showControlsTemporarily()
                                    }
                            )
                        }
                        .frame(height: 6)

                        // Controls row
                        HStack(spacing: 24) {
                            Text(formatTime(model.currentTime))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundColor(.white)

                            Spacer()

                            Button { model.seek(by: -10); showControlsTemporarily() } label: {
                                Image(systemName: "gobackward.10")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)

                            Button { model.togglePlayback(); showControlsTemporarily() } label: {
                                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)

                            Button { model.seek(by: 10); showControlsTemporarily() } label: {
                                Image(systemName: "goforward.10")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Text("-" + formatTime(model.duration - model.currentTime))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .padding(20)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            showControlsTemporarily()
        }
        .onHover { hovering in
            if hovering {
                showControlsTemporarily()
            }
        }
        .onKeyPress(.escape) {
            model.exitFullscreen()
            return .handled
        }
        .focusable()
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .animation(.easeOut(duration: 0.3), value: model.showPlaybackIndicator)
    }

    private func showControlsTemporarily() {
        showControls = true
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            if !Task.isCancelled && model.isPlaying {
                showControls = false
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite else { return "0:00" }
        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

@available(macOS 14.0, *)
struct VideoPlayerCard: View {
    let videoURL: URL

    @StateObject private var model: VideoPlayerModel
    @State private var isHovering = false

    init(videoURL: URL) {
        self.videoURL = videoURL
        self._model = StateObject(wrappedValue: VideoPlayerModel(url: videoURL))
    }

    var body: some View {
        GlassCard(padding: Theme.Spacing.lg) {
            VStack(spacing: Theme.Spacing.md) {
                // Section header
                HStack {
                    Label("Meeting Video", systemImage: "video.fill")
                        .font(Theme.Typography.headline)
                        .foregroundColor(Theme.Colors.textPrimary)
                    Spacer()

                    // Fullscreen button
                    Button {
                        model.toggleFullscreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Enter fullscreen")

                    // Export video button
                    Button {
                        exportVideo()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Export video")
                }

                // Video player with click overlay
                ZStack {
                    NativeVideoPlayerView(player: model.player)
                        .aspectRatio(16/9, contentMode: .fit)

                    // Click to play/pause overlay
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.togglePlayback()
                        }

                    // Play/Pause indicator
                    if model.showPlaybackIndicator {
                        ZStack {
                            Circle()
                                .fill(.black.opacity(0.6))
                                .frame(width: 64, height: 64)

                            Image(systemName: model.isPlaying ? "play.fill" : "pause.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .transition(.opacity.combined(with: .scale))
                    }

                    // Hover play button (when paused)
                    if isHovering && !model.isPlaying && !model.showPlaybackIndicator {
                        ZStack {
                            Circle()
                                .fill(.black.opacity(0.5))
                                .frame(width: 56, height: 56)

                            Image(systemName: "play.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .offset(x: 2)
                        }
                        .transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
                )
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovering = hovering
                    }
                }
                .animation(.easeOut(duration: 0.3), value: model.showPlaybackIndicator)

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Track
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Colors.surfaceHover)
                            .frame(height: 6)

                        // Progress
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Colors.primary)
                            .frame(width: model.duration > 0 ? geometry.size.width * CGFloat(model.currentTime / model.duration) : 0, height: 6)

                        // Scrubber handle
                        if model.duration > 0 {
                            Circle()
                                .fill(Theme.Colors.primary)
                                .frame(width: 12, height: 12)
                                .offset(x: geometry.size.width * CGFloat(model.currentTime / model.duration) - 6)
                                .opacity(isHovering ? 1 : 0)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let percentage = min(max(0, value.location.x / geometry.size.width), 1)
                                model.seek(to: Double(percentage))
                            }
                    )
                }
                .frame(height: 12)

                // Time and controls row
                HStack(spacing: Theme.Spacing.md) {
                    Text(formatTime(model.currentTime))
                        .font(Theme.Typography.monoBody)
                        .foregroundColor(Theme.Colors.textSecondary)

                    Spacer()

                    // Skip back
                    Button { model.seek(by: -10) } label: {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)

                    // Play/Pause button
                    Button {
                        model.togglePlayback()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Theme.Colors.primary)
                                .frame(width: 40, height: 40)

                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .offset(x: model.isPlaying ? 0 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .shadow(color: Theme.Colors.primary.opacity(0.3), radius: 6, y: 2)

                    // Skip forward
                    Button { model.seek(by: 10) } label: {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("-" + formatTime(model.duration - model.currentTime))
                        .font(Theme.Typography.monoBody)
                        .foregroundColor(Theme.Colors.textMuted)
                }
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite else { return "0:00" }
        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.movie]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".mov"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? FileManager.default.copyItem(at: videoURL, to: url)
            }
        }
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
