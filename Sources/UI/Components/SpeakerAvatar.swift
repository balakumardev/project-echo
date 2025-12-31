import SwiftUI

/// Speaker avatar with gradient background
@available(macOS 14.0, *)
public struct SpeakerAvatar: View {
    let name: String
    let size: CGFloat
    let showName: Bool

    public init(name: String, size: CGFloat = 32, showName: Bool = false) {
        self.name = name
        self.size = size
        self.showName = showName
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Avatar circle
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(Theme.Colors.speakerGradient(for: name))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: Theme.Colors.speakerColor(for: name).opacity(0.3), radius: 4, x: 0, y: 2)

            if showName {
                Text(name)
                    .font(Theme.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.Colors.textPrimary)
            }
        }
    }

    private var initials: String {
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

/// Speaker legend showing all speakers
@available(macOS 14.0, *)
public struct SpeakerLegend: View {
    let speakers: [String]

    public init(speakers: [String]) {
        self.speakers = speakers
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(speakers, id: \.self) { speaker in
                    SpeakerBadge(name: speaker)
                }
            }
            .padding(.horizontal, Theme.Spacing.xs)
        }
    }
}

/// Compact speaker badge
@available(macOS 14.0, *)
public struct SpeakerBadge: View {
    let name: String
    var isActive: Bool = false

    @State private var isHovered = false

    public init(name: String, isActive: Bool = false) {
        self.name = name
        self.isActive = isActive
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(Theme.Colors.speakerGradient(for: name))
                .frame(width: 8, height: 8)

            Text(name)
                .font(Theme.Typography.footnote)
                .fontWeight(.medium)
                .foregroundColor(isActive ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            Capsule()
                .fill(isActive || isHovered ? Theme.Colors.surfaceHover : Theme.Colors.surface)
        )
        .overlay(
            Capsule()
                .stroke(
                    isActive ? Theme.Colors.speakerColor(for: name).opacity(0.5) : Theme.Colors.borderSubtle,
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// App icon with gradient background
@available(macOS 14.0, *)
public struct AppIconBadge: View {
    let appName: String?
    let size: CGFloat

    public init(appName: String?, size: CGFloat = 48) {
        self.appName = appName
        self.size = size
    }

    public var body: some View {
        Image(systemName: AppIcons.icon(for: appName))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Theme.Colors.appGradient(for: appName))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}

/// Status badge (transcript, recording, etc.)
@available(macOS 14.0, *)
public struct StatusBadge: View {
    let text: String
    let color: Color
    let icon: String?

    public init(_ text: String, color: Color = Theme.Colors.success, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(Theme.Typography.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
    }
}

