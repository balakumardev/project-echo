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
        GlassCard(padding: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.md) {
                // Compact header with label
                HStack {
                    Label("Audio Recording", systemImage: "waveform")
                        .font(Theme.Typography.callout)
                        .foregroundColor(Theme.Colors.textSecondary)
                    Spacer()
                    // Playback rate
                    PlaybackRateButton(rate: $playbackRate) { newRate in
                        player.rate = newRate
                    }
                }

                // Progress bar with scrubber
                GeometryReader { geometry in
                    let progress = player.duration > 0 ? currentTime / player.duration : 0
                    let scrubberX = geometry.size.width * CGFloat(progress)

                    ZStack(alignment: .leading) {
                        // Track background
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.Colors.surfaceHover)
                            .frame(height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)

                        // Progress fill
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.Colors.primary)
                            .frame(width: max(0, scrubberX), height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)

                        // Scrubber handle
                        Circle()
                            .fill(Theme.Colors.primary)
                            .frame(width: 14, height: 14)
                            .shadow(color: Theme.Colors.primary.opacity(0.4), radius: 3, y: 1)
                            .position(x: max(7, min(geometry.size.width - 7, scrubberX)), y: geometry.size.height / 2)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newProgress = min(max(0, value.location.x / geometry.size.width), 1)
                                let newTime = player.duration * newProgress
                                player.currentTime = newTime
                                currentTime = newTime
                            }
                    )
                }
                .frame(height: 24)

                // Controls row - compact
                HStack(spacing: Theme.Spacing.md) {
                    // Time
                    Text(Formatters.formatTime(currentTime))
                        .font(Theme.Typography.monoSmall)
                        .foregroundColor(Theme.Colors.textSecondary)
                        .frame(width: 50, alignment: .leading)

                    Spacer()

                    // Skip back
                    Button {
                        player.currentTime = max(0, player.currentTime - 10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)

                    // Play/Pause button - smaller
                    Button {
                        togglePlayback()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Theme.Colors.primary)
                                .frame(width: 44, height: 44)

                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .offset(x: isPlaying ? 0 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .shadow(color: Theme.Colors.primary.opacity(0.3), radius: 8, y: 3)

                    // Skip forward
                    Button {
                        player.currentTime = min(player.duration, player.currentTime + 10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Remaining time
                    Text("-" + Formatters.formatTime(player.duration - currentTime))
                        .font(Theme.Typography.monoSmall)
                        .foregroundColor(Theme.Colors.textMuted)
                        .frame(width: 50, alignment: .trailing)

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
