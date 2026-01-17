import SwiftUI

/// Individual message bubble component
@available(macOS 14.0, *)
public struct MessageBubble: View {
    let message: DisplayMessage
    var onCitationTap: ((Citation) -> Void)?

    /// Whether to show the full timestamp
    @State private var showFullTimestamp: Bool = false

    /// Whether citations are expanded
    @State private var citationsExpanded: Bool = false

    public init(
        message: DisplayMessage,
        onCitationTap: ((Citation) -> Void)? = nil
    ) {
        self.message = message
        self.onCitationTap = onCitationTap
    }

    public var body: some View {
        if message.role == "user" {
            userMessageBubble
        } else {
            assistantMessageBubble
        }
    }

    // MARK: - User Message Bubble

    private var userMessageBubble: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                // Message content
                Text(message.content)
                    .font(Theme.Typography.body)
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.primary)
                    .cornerRadius(Theme.Radius.lg)
                    .cornerRadius(Theme.Radius.xs, corners: [.topRight])

                // Timestamp
                Text(formattedTimestamp)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
                    .onTapGesture {
                        withAnimation(Theme.Animation.fast) {
                            showFullTimestamp.toggle()
                        }
                    }
            }

            // User avatar
            Circle()
                .fill(Theme.Colors.primary.opacity(0.2))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.Colors.primary)
                )
        }
    }

    // MARK: - Assistant Message Bubble

    private var assistantMessageBubble: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            // Assistant avatar
            Circle()
                .fill(Theme.Colors.surface)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.Colors.primary)
                )

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // Message content
                Text(message.content)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.surface)
                    .cornerRadius(Theme.Radius.lg)
                    .cornerRadius(Theme.Radius.xs, corners: [.topLeft])

                // Citations
                if let citations = message.citations, !citations.isEmpty {
                    citationsSection(citations)
                }

                // Timestamp
                Text(formattedTimestamp)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
                    .onTapGesture {
                        withAnimation(Theme.Animation.fast) {
                            showFullTimestamp.toggle()
                        }
                    }
            }

            Spacer(minLength: 60)
        }
    }

    // MARK: - Citations Section

    private func citationsSection(_ citations: [Citation]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Header
            Button(action: {
                withAnimation(Theme.Animation.fast) {
                    citationsExpanded.toggle()
                }
            }) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))

                    Text("\(citations.count) source\(citations.count == 1 ? "" : "s")")
                        .font(Theme.Typography.caption)

                    Spacer()

                    Image(systemName: citationsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Theme.Colors.textSecondary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
            }
            .buttonStyle(.plain)
            .hoverEffect(cornerRadius: Theme.Radius.sm)

            // Expanded citations
            if citationsExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(citations) { citation in
                        CitationCard(
                            citation: citation,
                            onTap: {
                                onCitationTap?(citation)
                            }
                        )
                    }
                }
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Colors.surfaceHover.opacity(0.5))
        .cornerRadius(Theme.Radius.md)
    }

    // MARK: - Timestamp Formatting

    private var formattedTimestamp: String {
        if showFullTimestamp {
            return fullDateFormatter.string(from: message.timestamp)
        } else {
            return relativeTimestamp
        }
    }

    private var relativeTimestamp: String {
        let interval = Date().timeIntervalSince(message.timestamp)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            return shortDateFormatter.string(from: message.timestamp)
        }
    }

    private var fullDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private var shortDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }
}

// MARK: - Citation Card

@available(macOS 14.0, *)
struct CitationCard: View {
    let citation: Citation
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // Recording title and timestamp
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.primary)

                    Text(citation.recordingTitle)
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textSecondary)
                        .lineLimit(1)

                    Text("@")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)

                    Text(formatTimestamp(citation.timestamp))
                        .font(Theme.Typography.monoSmall)
                        .foregroundColor(Theme.Colors.primary)
                }

                // Speaker
                HStack(spacing: Theme.Spacing.xs) {
                    Circle()
                        .fill(Theme.Colors.speakerColor(for: citation.speaker))
                        .frame(width: 8, height: 8)

                    Text(citation.speaker)
                        .font(Theme.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundColor(Theme.Colors.textPrimary)
                }

                // Quote text
                Text("\"\(citation.text)\"")
                    .font(Theme.Typography.callout)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .lineLimit(3)
                    .italic()
            }
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Theme.Colors.surfaceHover : Theme.Colors.surface)
            .cornerRadius(Theme.Radius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.Animation.fast) {
                isHovered = hovering
            }
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
struct MessageBubble_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // User message
            MessageBubble(
                message: DisplayMessage(
                    role: "user",
                    content: "What were the action items from the last meeting?"
                )
            )

            // Assistant message with citations
            MessageBubble(
                message: DisplayMessage(
                    role: "assistant",
                    content: "Based on the meeting transcript, here are the key action items:\n\n1. John will prepare the budget proposal by Friday\n2. Sarah needs to review the design mockups\n3. Team will reconvene next Tuesday",
                    citations: [
                        Citation(
                            segmentId: 1,
                            recordingId: 1,
                            recordingTitle: "Team Standup - Nov 15",
                            speaker: "John",
                            timestamp: 125.5,
                            text: "I'll have the budget proposal ready by end of week."
                        ),
                        Citation(
                            segmentId: 2,
                            recordingId: 1,
                            recordingTitle: "Team Standup - Nov 15",
                            speaker: "Sarah",
                            timestamp: 180.2,
                            text: "Let me take a look at those mockups and get back to you."
                        )
                    ]
                )
            )
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.background)
        .frame(width: 500)
    }
}
#endif
