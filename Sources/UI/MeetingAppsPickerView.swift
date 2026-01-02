import SwiftUI
import AppKit

/// View for selecting which meeting apps to monitor for auto-recording
@available(macOS 14.0, *)
public struct MeetingAppsPickerView: View {
    @AppStorage("enabledMeetingApps") private var enabledAppsRaw = "zoom,teams,meet,slack,discord"
    @ObservedObject private var customAppsManager = CustomMeetingAppsManager.shared

    @State private var showAppPicker = false

    /// Default (built-in) meeting apps
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

    /// Default app bundle IDs (for filtering in app picker)
    private static let defaultAppBundleIds: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.cisco.webexmeetingsapp", "com.apple.FaceTime", "com.skype.skype"
    ]

    private var enabledApps: Set<String> {
        Set(enabledAppsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    }

    /// All bundle IDs that are already configured (default + custom)
    private var allConfiguredBundleIds: Set<String> {
        Self.defaultAppBundleIds.union(customAppsManager.getCustomBundleIds())
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Default Apps Section
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("DEFAULT APPS")
                    .font(Theme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.Colors.textMuted)
                    .tracking(0.5)

                VStack(spacing: 0) {
                    ForEach(Self.supportedApps) { app in
                        MeetingAppRow(
                            app: app,
                            isEnabled: enabledApps.contains(app.id),
                            onToggle: { enabled in
                                toggleApp(id: app.id, enabled: enabled)
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
            }

            // Custom Apps Section
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("CUSTOM APPS")
                        .font(Theme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(Theme.Colors.textMuted)
                        .tracking(0.5)

                    Spacer()

                    Button(action: { showAppPicker = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add App")
                        }
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.primary)
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 0) {
                    if customAppsManager.customApps.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "app.badge.plus")
                                    .font(.system(size: 24))
                                    .foregroundColor(Theme.Colors.textMuted)
                                Text("No custom apps added")
                                    .font(Theme.Typography.caption)
                                    .foregroundColor(Theme.Colors.textMuted)
                                Text("Add any app to detect meetings")
                                    .font(Theme.Typography.caption)
                                    .foregroundColor(Theme.Colors.textMuted.opacity(0.7))
                            }
                            .padding(.vertical, Theme.Spacing.lg)
                            Spacer()
                        }
                    } else {
                        ForEach(customAppsManager.customApps) { app in
                            CustomMeetingAppRow(
                                app: app,
                                isEnabled: enabledApps.contains(app.bundleId),
                                onToggle: { enabled in
                                    toggleApp(id: app.bundleId, enabled: enabled)
                                },
                                onRemove: {
                                    customAppsManager.removeApp(id: app.id)
                                }
                            )

                            if app.id != customAppsManager.customApps.last?.id {
                                Divider()
                                    .background(Theme.Colors.border.opacity(0.5))
                            }
                        }
                    }
                }
                .background(Theme.Colors.surface)
                .cornerRadius(Theme.Radius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Theme.Colors.border, lineWidth: 1)
                )
            }

            // Quick actions
            HStack(spacing: Theme.Spacing.md) {
                Button("Select All") {
                    selectAll()
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

                let totalCount = enabledApps.count
                Text("\(totalCount) app\(totalCount == 1 ? "" : "s") selected")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
            }
        }
        .sheet(isPresented: $showAppPicker) {
            AppPickerView(
                existingBundleIds: allConfiguredBundleIds,
                onSelect: { appInfo in
                    customAppsManager.addApp(
                        bundleId: appInfo.bundleId,
                        displayName: appInfo.displayName
                    )
                }
            )
        }
    }

    private func toggleApp(id: String, enabled: Bool) {
        var apps = enabledApps
        if enabled {
            apps.insert(id)
        } else {
            apps.remove(id)
        }
        enabledAppsRaw = apps.sorted().joined(separator: ",")
    }

    private func selectAll() {
        var all = Set(Self.supportedApps.map(\.id))
        all.formUnion(customAppsManager.customApps.map(\.bundleId))
        enabledAppsRaw = all.sorted().joined(separator: ",")
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

/// Row for a single meeting app (default apps)
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

/// Row for a custom meeting app
@available(macOS 14.0, *)
private struct CustomMeetingAppRow: View {
    let app: CustomMeetingApp
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    @State private var isHovered = false
    @State private var showRemoveConfirmation = false
    @State private var appIcon: NSImage?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // App icon (loaded from system)
            Group {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .cornerRadius(6)
                } else {
                    ZStack {
                        Circle()
                            .fill(isEnabled ? Theme.Colors.secondaryMuted : Theme.Colors.surfaceHover)
                            .frame(width: 32, height: 32)

                        Image(systemName: "app.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isEnabled ? Theme.Colors.secondary : Theme.Colors.textMuted)
                    }
                }
            }

            // App name and bundle ID
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(Theme.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text(app.bundleId)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            // Remove button (visible on hover)
            if isHovered {
                Button(action: { showRemoveConfirmation = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Colors.error)
                }
                .buttonStyle(.plain)
                .help("Remove this app")
            }

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
        .onAppear {
            loadAppIcon()
        }
        .alert("Remove App?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove() }
        } message: {
            Text("Remove \(app.displayName) from the meeting apps list?")
        }
    }

    private func loadAppIcon() {
        // Try to get the app icon from the bundle
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
            appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
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
