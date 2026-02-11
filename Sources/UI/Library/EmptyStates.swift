import SwiftUI

// MARK: - Empty Detail View

/// Displayed when no recording is selected in the detail pane
@available(macOS 14.0, *)
public struct EmptyDetailView: View {
    @AppStorage("showChatPanel_v2") private var showChatPanel = false
    @AppStorage("aiEnabled") private var aiEnabled = true

    public init() {}

    public var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Theme.Colors.primaryMuted)
                    .frame(width: 80, height: 80)

                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(Theme.Colors.primary)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Text("Select a Recording")
                    .font(Theme.Typography.title3)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("Choose a recording from the sidebar to view details")
                    .font(Theme.Typography.callout)
                    .foregroundColor(Theme.Colors.textMuted)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if aiEnabled {
                    Button { showChatPanel.toggle() } label: {
                        Image(systemName: showChatPanel ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    }
                    .help("Toggle AI Chat")
                }
            }
        }
    }
}

// MARK: - Empty State View

/// Displayed when the recording list is empty (search or no recordings)
@available(macOS 14.0, *)
public struct EmptyStateView: View {
    let hasSearch: Bool

    public init(hasSearch: Bool = false) {
        self.hasSearch = hasSearch
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Loading View

/// Displayed while recordings are being loaded
@available(macOS 14.0, *)
public struct LoadingView: View {
    public init() {}

    public var body: some View {
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

// MARK: - Transcript Loading View

/// Displayed while a transcript is being processed
@available(macOS 14.0, *)
public struct TranscriptLoadingView: View {
    public init() {}

    public var body: some View {
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

// MARK: - No Transcript View

/// Displayed when a recording has no transcript with option to generate one
@available(macOS 14.0, *)
public struct NoTranscriptView: View {
    let onGenerate: () -> Void

    public init(onGenerate: @escaping () -> Void) {
        self.onGenerate = onGenerate
    }

    public var body: some View {
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

// MARK: - Previews

#if DEBUG
@available(macOS 14.0, *)
#Preview("Empty Detail View") {
    EmptyDetailView()
        .frame(width: 600, height: 400)
}

@available(macOS 14.0, *)
#Preview("Empty State - No Recordings") {
    EmptyStateView(hasSearch: false)
        .frame(width: 300, height: 300)
        .background(Theme.Colors.surface)
}

@available(macOS 14.0, *)
#Preview("Empty State - No Search Results") {
    EmptyStateView(hasSearch: true)
        .frame(width: 300, height: 300)
        .background(Theme.Colors.surface)
}

@available(macOS 14.0, *)
#Preview("Loading View") {
    LoadingView()
        .frame(width: 300, height: 200)
        .background(Theme.Colors.surface)
}

@available(macOS 14.0, *)
#Preview("Transcript Loading View") {
    TranscriptLoadingView()
        .frame(width: 400)
        .padding()
        .background(Theme.Colors.background)
}

@available(macOS 14.0, *)
#Preview("No Transcript View") {
    NoTranscriptView {
        print("Generate tapped")
    }
    .frame(width: 400)
    .padding()
    .background(Theme.Colors.background)
}
#endif
