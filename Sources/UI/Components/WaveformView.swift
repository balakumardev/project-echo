import SwiftUI
import AVFoundation

/// Audio waveform visualization
@available(macOS 14.0, *)
public struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let duration: TimeInterval
    let onSeek: ((TimeInterval) -> Void)?

    @State private var hoverProgress: Double?
    @State private var isDragging = false

    private let barCount = 100
    private let barSpacing: CGFloat = 2

    public init(
        samples: [Float] = [],
        progress: Double = 0,
        duration: TimeInterval = 0,
        onSeek: ((TimeInterval) -> Void)? = nil
    ) {
        self.samples = samples
        self.progress = progress
        self.duration = duration
        self.onSeek = onSeek
    }

    public var body: some View {
        GeometryReader { geometry in
            let barWidth = (geometry.size.width - CGFloat(barCount - 1) * barSpacing) / CGFloat(barCount)
            let normalizedSamples = normalizeAndResample(to: barCount)

            ZStack(alignment: .leading) {
                // Background waveform
                HStack(spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        WaveformBar(
                            height: normalizedSamples[index],
                            maxHeight: geometry.size.height,
                            width: barWidth,
                            isPlayed: false,
                            isHovered: isBarHovered(index)
                        )
                    }
                }

                // Played portion overlay
                HStack(spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        WaveformBar(
                            height: normalizedSamples[index],
                            maxHeight: geometry.size.height,
                            width: barWidth,
                            isPlayed: true,
                            isHovered: isBarHovered(index)
                        )
                    }
                }
                .mask(
                    Rectangle()
                        .frame(width: geometry.size.width * currentProgress)
                )

                // Hover time indicator
                if let hover = hoverProgress, !isDragging {
                    TimeTooltip(time: duration * hover)
                        .position(
                            x: geometry.size.width * hover,
                            y: -20
                        )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        hoverProgress = progress
                    }
                    .onEnded { value in
                        isDragging = false
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        onSeek?(duration * progress)
                        hoverProgress = nil
                    }
            )
            .onHover { hovering in
                if !hovering {
                    hoverProgress = nil
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if !isDragging {
                        hoverProgress = max(0, min(1, location.x / geometry.size.width))
                    }
                case .ended:
                    if !isDragging {
                        hoverProgress = nil
                    }
                }
            }
        }
        .frame(height: 60)
    }

    private var currentProgress: Double {
        isDragging ? (hoverProgress ?? progress) : progress
    }

    private func isBarHovered(_ index: Int) -> Bool {
        guard let hover = hoverProgress else { return false }
        let barProgress = Double(index) / Double(barCount)
        return abs(barProgress - hover) < 0.02
    }

    private func normalizeAndResample(to count: Int) -> [CGFloat] {
        guard !samples.isEmpty else {
            // Generate placeholder waveform
            return (0..<count).map { i in
                let x = Double(i) / Double(count)
                return CGFloat(0.3 + 0.4 * sin(x * 20) * sin(x * 3))
            }
        }

        let chunkSize = max(1, samples.count / count)
        var result: [CGFloat] = []

        for i in 0..<count {
            let start = i * chunkSize
            let end = min(start + chunkSize, samples.count)
            if start < samples.count {
                let chunk = samples[start..<end]
                let avg = chunk.reduce(0, +) / Float(chunk.count)
                result.append(CGFloat(min(1, max(0.1, abs(avg) * 2))))
            } else {
                result.append(0.2)
            }
        }

        return result
    }
}

/// Individual waveform bar
@available(macOS 14.0, *)
struct WaveformBar: View {
    let height: CGFloat
    let maxHeight: CGFloat
    let width: CGFloat
    let isPlayed: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: width / 2)
            .fill(barColor)
            .frame(width: width, height: max(4, height * maxHeight * 0.9))
            .frame(height: maxHeight, alignment: .center)
    }

    private var barColor: Color {
        if isPlayed {
            return isHovered ? Theme.Colors.primaryHover : Theme.Colors.waveformPlayed
        }
        return isHovered ? Theme.Colors.textMuted : Theme.Colors.waveformUnplayed
    }
}

/// Time tooltip on hover
@available(macOS 14.0, *)
struct TimeTooltip: View {
    let time: TimeInterval

    var body: some View {
        Text(formatTime(time))
            .font(Theme.Typography.monoSmall)
            .foregroundColor(Theme.Colors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.Colors.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
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

/// Compact waveform for lists
@available(macOS 14.0, *)
public struct MiniWaveform: View {
    let samples: [Float]
    let isPlaying: Bool

    private let barCount = 20

    public init(samples: [Float] = [], isPlaying: Bool = false) {
        self.samples = samples
        self.isPlaying = isPlaying
    }

    public var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(isPlaying ? Theme.Colors.primary : Theme.Colors.textMuted)
                    .frame(width: 2, height: barHeight(for: index))
                    .animation(
                        isPlaying ?
                            Animation.easeInOut(duration: 0.3)
                                .repeatForever()
                                .delay(Double(index) * 0.05) :
                            .default,
                        value: isPlaying
                    )
            }
        }
        .frame(height: 16)
    }

    private func barHeight(for index: Int) -> CGFloat {
        if samples.isEmpty {
            return CGFloat.random(in: 4...14)
        }
        let sampleIndex = (index * samples.count) / barCount
        return max(4, CGFloat(abs(samples[sampleIndex])) * 14)
    }
}

