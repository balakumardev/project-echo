import SwiftUI
import AVFoundation
import Database

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
                    Text(Formatters.formatTime(currentTime))
                        .font(Theme.Typography.monoBody)
                        .foregroundColor(Theme.Colors.textSecondary)

                    Spacer()

                    Text("-" + Formatters.formatTime(player.duration - currentTime))
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
                        .accessibilityLabel("Skip back 10 seconds")

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
                        .accessibilityLabel(isPlaying ? "Pause" : "Play")

                        IconButton(icon: "goforward.10", size: 40, style: .ghost) {
                            player.currentTime = min(player.duration, player.currentTime + 10)
                        }
                        .accessibilityLabel("Skip forward 10 seconds")
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
        .accessibilityLabel("Playback speed \(formatRate(rate))")
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
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(volume * 100)) percent")
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
            .accessibilityLabel("Volume control")
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
