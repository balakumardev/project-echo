import SwiftUI
import Intelligence

/// AI Status Indicator Component
/// Displays the current AI service status with appropriate visual feedback
/// Used in the sidebar header and other locations needing AI status display
@available(macOS 14.0, *)
public struct AIStatusIndicator: View {
    @EnvironmentObject private var aiService: AIServiceObservable
    @AppStorage("aiEnabled") private var aiEnabled = true
    @Environment(\.openURL) private var openURL

    public enum Style {
        case compact      // Small dot indicator
        case detailed     // Full status text with icon
        case headerBar    // Compact with hover expansion
    }

    let style: Style
    var onSettingsTap: (() -> Void)?

    @State private var isHovered = false
    @State private var showPopover = false

    // Ready notification animation states
    @State private var showReadyPulse = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.0
    @State private var previousStatusIsReady = false

    public init(style: Style = .compact, onSettingsTap: (() -> Void)? = nil) {
        self.style = style
        self.onSettingsTap = onSettingsTap
    }

    public var body: some View {
        Group {
            switch style {
            case .compact:
                compactView
            case .detailed:
                detailedView
            case .headerBar:
                headerBarView
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: aiService.status) { _, newStatus in
            handleStatusChange(newStatus: newStatus)
        }
    }

    // MARK: - Status Change Handler

    private func handleStatusChange(newStatus: AIService.Status) {
        let isNowReady = {
            if case .ready = newStatus { return true }
            return false
        }()

        // Detect transition TO ready state
        if isNowReady && !previousStatusIsReady && aiEnabled {
            triggerReadyNotification()
        }

        previousStatusIsReady = isNowReady
    }

    private func triggerReadyNotification() {
        showReadyPulse = true
        glowOpacity = 0.8

        // Pulse animation sequence
        withAnimation(Theme.Animation.bouncy) {
            pulseScale = 1.3
        }

        // Contract back
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(Theme.Animation.spring) {
                pulseScale = 1.0
            }
        }

        // Second pulse
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(Theme.Animation.bouncy) {
                pulseScale = 1.2
            }
        }

        // Final contract
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(Theme.Animation.spring) {
                pulseScale = 1.0
            }
        }

        // Fade out glow after pulses complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(Theme.Animation.slow) {
                glowOpacity = 0.0
            }
        }

        // Reset pulse state
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showReadyPulse = false
        }
    }

    // MARK: - Compact View (Small Dot)

    private var compactView: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .scaleEffect(pulseScale)
            .background(
                Circle()
                    .fill(Theme.Colors.success)
                    .frame(width: 16, height: 16)
                    .blur(radius: 6)
                    .opacity(glowOpacity)
                    .scaleEffect(pulseScale * 1.5)
            )
            .help(statusTooltip)
    }

    // MARK: - Header Bar View (Compact + Hover)

    private var headerBarView: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                // Status icon with pulse effect
                statusIcon
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
                    .scaleEffect(pulseScale)

                // Status dot with glow
                ZStack {
                    // Glow background
                    if showReadyPulse {
                        Circle()
                            .fill(Theme.Colors.success)
                            .frame(width: 14, height: 14)
                            .blur(radius: 4)
                            .opacity(glowOpacity)
                            .scaleEffect(pulseScale)
                    }

                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .scaleEffect(pulseScale)
                }

                // Expanded text on hover or during ready notification
                if isHovered || showReadyPulse {
                    Text(shortStatusText)
                        .font(Theme.Typography.caption)
                        .foregroundColor(showReadyPulse ? Theme.Colors.success : Theme.Colors.textSecondary)
                        .fontWeight(showReadyPulse ? .semibold : .regular)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                ZStack {
                    // Ready glow background
                    if showReadyPulse {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.Colors.successMuted)
                            .opacity(glowOpacity * 0.5)
                    }

                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(isHovered ? Theme.Colors.surfaceHover : Color.clear)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(showReadyPulse ? Theme.Colors.success.opacity(glowOpacity * 0.6) : Color.clear, lineWidth: 1)
            )
            .animation(Theme.Animation.fast, value: isHovered)
            .animation(Theme.Animation.normal, value: showReadyPulse)
        }
        .buttonStyle(.plain)
        .help(statusTooltip)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            statusPopover
        }
    }

    // MARK: - Detailed View (Full Status)

    private var detailedView: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Icon with pulse and glow
            ZStack {
                // Glow background for ready state
                if showReadyPulse {
                    Circle()
                        .fill(Theme.Colors.success)
                        .frame(width: 28, height: 28)
                        .blur(radius: 8)
                        .opacity(glowOpacity * 0.6)
                        .scaleEffect(pulseScale)
                }

                statusIcon
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(statusColor)
                    .scaleEffect(pulseScale)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(statusText)
                        .font(Theme.Typography.body)
                        .foregroundColor(Theme.Colors.textPrimary)
                        .fontWeight(showReadyPulse ? .semibold : .regular)

                    // Checkmark animation when ready
                    if showReadyPulse {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.Colors.success)
                            .font(.system(size: 12))
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                if case .downloading(let progress, _) = aiService.status {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                }
            }
        }
        .padding(.vertical, showReadyPulse ? Theme.Spacing.xs : 0)
        .padding(.horizontal, showReadyPulse ? Theme.Spacing.sm : 0)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(showReadyPulse ? Theme.Colors.successMuted : Color.clear)
                .opacity(glowOpacity * 0.4)
        )
        .animation(Theme.Animation.normal, value: showReadyPulse)
    }

    // MARK: - Status Popover

    private var statusPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Header
            HStack {
                statusIcon
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(statusColor)

                Text("AI Status")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)

                Spacer()
            }

            Divider()

            // Status details
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Status:")
                        .foregroundColor(Theme.Colors.textSecondary)
                    Spacer()
                    Text(statusText)
                        .foregroundColor(Theme.Colors.textPrimary)
                }

                if case .ready(let modelName) = aiService.status {
                    HStack {
                        Text("Model:")
                            .foregroundColor(Theme.Colors.textSecondary)
                        Spacer()
                        Text(modelName)
                            .foregroundColor(Theme.Colors.textPrimary)
                            .lineLimit(1)
                    }
                }

                if case .unloadedToSaveMemory(let modelName) = aiService.status {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Model:")
                                .foregroundColor(Theme.Colors.textSecondary)
                            Spacer()
                            Text(modelName)
                                .foregroundColor(Theme.Colors.textPrimary)
                                .lineLimit(1)
                        }
                        Text("Unloaded to save ~3GB of memory. Will reload automatically when you use AI features.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if case .downloading(let progress, _) = aiService.status {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloading...")
                            .foregroundColor(Theme.Colors.textSecondary)
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    }
                }
            }
            .font(Theme.Typography.caption)

            Divider()

            // AI Enable Toggle
            Toggle(isOn: $aiEnabled) {
                HStack {
                    Image(systemName: aiEnabled ? "sparkles" : "sparkles.slash")
                        .foregroundColor(aiEnabled ? Theme.Colors.primary : Theme.Colors.textMuted)
                    Text("Enable AI Features")
                        .font(Theme.Typography.body)
                }
            }
            .toggleStyle(.switch)

            // Error retry button
            if case .error = aiService.status {
                Button {
                    Task {
                        await aiService.retryInitialization()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 260)
    }

    // MARK: - Status Helpers

    private var statusIcon: Image {
        if !aiEnabled {
            return Image(systemName: "sparkles.slash")
        }

        // Show loading icon if initializing (even if status says notConfigured)
        if aiService.isInitializing && !aiService.isInitialized {
            return Image(systemName: "circle.dotted")
        }

        switch aiService.status {
        case .notConfigured:
            return Image(systemName: "sparkle.magnifyingglass")
        case .unloadedToSaveMemory:
            return Image(systemName: "moon.zzz")
        case .downloading:
            return Image(systemName: "arrow.down.circle")
        case .loading:
            return Image(systemName: "circle.dotted")
        case .ready:
            return Image(systemName: "sparkles")
        case .error:
            return Image(systemName: "exclamationmark.triangle")
        }
    }

    private var statusColor: Color {
        if !aiEnabled {
            return Theme.Colors.textMuted
        }

        // Show loading color if initializing (even if status says notConfigured)
        if aiService.isInitializing && !aiService.isInitialized {
            return Theme.Colors.warning
        }

        switch aiService.status {
        case .notConfigured:
            return Theme.Colors.textMuted
        case .unloadedToSaveMemory:
            return Theme.Colors.primary.opacity(0.7)
        case .downloading, .loading:
            return Theme.Colors.warning
        case .ready:
            return Theme.Colors.success
        case .error:
            return Theme.Colors.error
        }
    }

    private var statusText: String {
        if !aiEnabled {
            return "AI Disabled"
        }

        // Show initializing if still in startup phase
        if aiService.isInitializing && !aiService.isInitialized {
            return "Initializing..."
        }

        switch aiService.status {
        case .notConfigured:
            return "Not Configured"
        case .unloadedToSaveMemory(let modelName):
            return "Sleeping: \(modelName)"
        case .downloading(_, let modelName):
            return "Downloading \(modelName)..."
        case .loading(let modelName):
            return "Loading \(modelName)..."
        case .ready(let modelName):
            return "Ready: \(modelName)"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private var shortStatusText: String {
        if !aiEnabled {
            return "Disabled"
        }

        // Show initializing if still in startup phase
        if aiService.isInitializing && !aiService.isInitialized {
            return "Initializing..."
        }

        switch aiService.status {
        case .notConfigured:
            return "Not Set Up"
        case .unloadedToSaveMemory:
            return "Sleeping"
        case .downloading:
            return "Downloading..."
        case .loading:
            return "Loading..."
        case .ready:
            return "Ready"
        case .error:
            return "Error"
        }
    }

    private var statusTooltip: String {
        if !aiEnabled {
            return "AI features are disabled. Click to enable."
        }

        // Show initializing tooltip if still in startup phase
        if aiService.isInitializing && !aiService.isInitialized {
            return "AI is initializing..."
        }

        switch aiService.status {
        case .notConfigured:
            return "AI not configured. Click to set up."
        case .unloadedToSaveMemory(let modelName):
            return "\(modelName) unloaded to save memory. Will reload when needed."
        case .downloading(let progress, let modelName):
            return "Downloading \(modelName): \(Int(progress * 100))%"
        case .loading(let modelName):
            return "Loading \(modelName)..."
        case .ready(let modelName):
            return "AI Ready: \(modelName)"
        case .error(let message):
            return "AI Error: \(message). Click to retry."
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
#Preview {
    VStack(spacing: 20) {
        AIStatusIndicator(style: .compact)
        AIStatusIndicator(style: .headerBar)
        AIStatusIndicator(style: .detailed)
    }
    .environmentObject(AIServiceObservable())
    .padding()
    .background(Theme.Colors.background)
}
#endif
