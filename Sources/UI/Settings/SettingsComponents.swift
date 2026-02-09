// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import SwiftUI

// MARK: - Settings Section

public struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    public init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Section header
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Colors.primary)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.Colors.textMuted)
                    .tracking(0.5)
            }

            // Section content
            content
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }
}

// MARK: - Settings Toggle

public struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    public init(title: String, subtitle: String, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    public var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Theme.Colors.primary)
                .labelsHidden()
        }
    }
}

// MARK: - Privacy Feature Row

public struct PrivacyFeatureRow: View {
    let icon: String
    let title: String
    let description: String

    public init(icon: String, title: String, description: String) {
        self.icon = icon
        self.title = title
        self.description = description
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Theme.Colors.success)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Colors.textPrimary)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.textMuted)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(Theme.Colors.success)
        }
    }
}

// MARK: - About Link

public struct AboutLink: View {
    let title: String
    let icon: String
    let urlString: String?

    @State private var isHovered = false

    public init(title: String, icon: String, urlString: String? = nil) {
        self.title = title
        self.icon = icon
        self.urlString = urlString
    }

    public var body: some View {
        Button {
            if let urlString = urlString, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundColor(isHovered ? Theme.Colors.primary : Theme.Colors.textSecondary)
            .frame(width: 64, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Theme.Colors.surfaceHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Apply Status Banner

/// State machine for deferred-apply settings
public enum ApplyStatus: Equatable {
    case idle
    case hasChanges(description: String)
    case applying
    case success(message: String)
    case error(message: String)
}

/// Shared banner component for deferred-apply settings tabs.
/// Shows unsaved changes, applying spinner, success/error feedback.
@available(macOS 14.0, *)
public struct ApplyStatusBanner: View {
    @Binding var status: ApplyStatus
    var onApply: () -> Void
    var onDiscard: () -> Void
    var onRetry: (() -> Void)?

    public init(
        status: Binding<ApplyStatus>,
        onApply: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onRetry: (() -> Void)? = nil
    ) {
        self._status = status
        self.onApply = onApply
        self.onDiscard = onDiscard
        self.onRetry = onRetry
    }

    public var body: some View {
        switch status {
        case .idle:
            EmptyView()

        case .hasChanges(let description):
            bannerContainer(borderColor: Theme.Colors.warning, bgColor: Theme.Colors.warningMuted) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.Colors.warning)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("You have unsaved changes")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.Colors.textPrimary)
                            Text(description)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                        }
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        Button {
                            onDiscard()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11))
                                Text("Discard")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Button {
                            onApply()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 11))
                                Text("Apply Changes")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

        case .applying:
            bannerContainer(borderColor: Theme.Colors.warning, bgColor: Theme.Colors.warningMuted) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                        Text("Applying changes...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.Colors.textPrimary)
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        Button {
                            onDiscard()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 11))
                                Text("Cancel")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()
                    }
                }
            }

        case .success(let message):
            bannerContainer(borderColor: Theme.Colors.success, bgColor: Theme.Colors.success.opacity(0.12)) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.Colors.success)
                        .font(.system(size: 14))
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Colors.success)
                    Spacer()
                }
            }

        case .error(let message):
            bannerContainer(borderColor: Theme.Colors.error, bgColor: Theme.Colors.errorMuted) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.Colors.error)
                            .font(.system(size: 14))
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.Colors.error)
                            .lineLimit(3)
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        Button {
                            onDiscard()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11))
                                Text("Discard")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        if let onRetry {
                            Button {
                                onRetry()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11))
                                    Text("Retry")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(Theme.Colors.error)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bannerContainer<Content: View>(
        borderColor: Color,
        bgColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor.opacity(0.5), lineWidth: 1.5)
            )
    }
}
