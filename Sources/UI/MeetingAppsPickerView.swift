import SwiftUI

/// View for selecting which meeting apps to monitor for auto-recording
@available(macOS 14.0, *)
public struct MeetingAppsPickerView: View {
    @AppStorage("enabledMeetingApps") private var enabledAppsRaw = "zoom,teams,meet,slack,discord"

    /// All supported meeting apps
    public static let supportedApps: [MeetingAppInfo] = [
        MeetingAppInfo(id: "zoom", displayName: "Zoom", icon: "video.fill", browserBased: false),
        MeetingAppInfo(id: "teams", displayName: "Microsoft Teams", icon: "person.3.fill", browserBased: false),
        MeetingAppInfo(id: "meet", displayName: "Google Meet", icon: "globe", browserBased: true),
        MeetingAppInfo(id: "slack", displayName: "Slack", icon: "bubble.left.fill", browserBased: false),
        MeetingAppInfo(id: "discord", displayName: "Discord", icon: "headphones", browserBased: false),
        MeetingAppInfo(id: "webex", displayName: "Webex", icon: "video.circle.fill", browserBased: false),
        MeetingAppInfo(id: "facetime", displayName: "FaceTime", icon: "video.fill", browserBased: false),
        MeetingAppInfo(id: "skype", displayName: "Skype", icon: "phone.fill", browserBased: false),
    ]

    private var enabledApps: Set<String> {
        get {
            Set(enabledAppsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }
        nonmutating set {
            enabledAppsRaw = newValue.sorted().joined(separator: ",")
        }
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // App list
            VStack(spacing: 0) {
                ForEach(Self.supportedApps) { app in
                    MeetingAppRow(
                        app: app,
                        isEnabled: enabledApps.contains(app.id),
                        onToggle: { enabled in
                            var apps = enabledApps
                            if enabled {
                                apps.insert(app.id)
                            } else {
                                apps.remove(app.id)
                            }
                            enabledAppsRaw = apps.sorted().joined(separator: ",")
                        }
                    )

                    if app.id != Self.supportedApps.last?.id {
                        Divider()
                            .background(Theme.Colors.border.opacity(0.5))
                    }
                }
            }
            .background(Theme.Colors.surface)
            .cornerRadius(Theme.Radius.md)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )

            // Quick actions
            HStack(spacing: Theme.Spacing.md) {
                Button("Select All") {
                    enabledAppsRaw = Self.supportedApps.map(\.id).joined(separator: ",")
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.primary)

                Button("Deselect All") {
                    enabledAppsRaw = ""
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textMuted)

                Spacer()

                Text("\(enabledApps.count) app\(enabledApps.count == 1 ? "" : "s") selected")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
            }
        }
    }
}

/// Info about a supported meeting app
public struct MeetingAppInfo: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let icon: String
    public let browserBased: Bool

    public init(id: String, displayName: String, icon: String, browserBased: Bool) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.browserBased = browserBased
    }
}

/// Row for a single meeting app
@available(macOS 14.0, *)
private struct MeetingAppRow: View {
    let app: MeetingAppInfo
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // App icon
            ZStack {
                Circle()
                    .fill(isEnabled ? Theme.Colors.primaryMuted : Theme.Colors.surfaceHover)
                    .frame(width: 32, height: 32)

                Image(systemName: app.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isEnabled ? Theme.Colors.primary : Theme.Colors.textMuted)
            }

            // App name and type
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(Theme.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.Colors.textPrimary)

                if app.browserBased {
                    Text("Browser-based")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)
                }
            }

            Spacer()

            // Toggle
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .tint(Theme.Colors.primary)
            .labelsHidden()
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(isHovered ? Theme.Colors.surfaceHover.opacity(0.5) : .clear)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
struct MeetingAppsPickerView_Previews: PreviewProvider {
    static var previews: some View {
        MeetingAppsPickerView()
            .frame(width: 400)
            .padding()
    }
}
#endif
