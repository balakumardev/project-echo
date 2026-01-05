import SwiftUI
import AppKit
import AVFoundation
import AVKit

// MARK: - Video Player Model

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

    func cleanup() {
        // Remove time observer to prevent leaks
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        player.pause()
    }

    deinit {
        // Ensure cleanup on deallocation
        // Note: Can't call cleanup() directly since deinit is nonisolated
        // The time observer uses [weak self] so it won't retain us
    }
}

// MARK: - Native AVPlayerView Wrapper

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

// MARK: - Fullscreen Video Player

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
                            Text(Formatters.formatTime(model.currentTime))
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

                            Text("-" + Formatters.formatTime(model.duration - model.currentTime))
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
}

// MARK: - Video Player Card

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
                    // Black background for proper letterboxing
                    Color.black

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
                .frame(maxWidth: .infinity)
                .aspectRatio(16/9, contentMode: .fit)
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
                    Text(Formatters.formatTime(model.currentTime))
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

                    Text("-" + Formatters.formatTime(model.duration - model.currentTime))
                        .font(Theme.Typography.monoBody)
                        .foregroundColor(Theme.Colors.textMuted)
                }
            }
        }
        .onDisappear {
            model.cleanup()
        }
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
