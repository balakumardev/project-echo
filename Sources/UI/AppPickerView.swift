import SwiftUI
import AppKit

/// View for picking an installed application to add to the whitelist
@available(macOS 14.0, *)
public struct AppPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var installedApps: [InstalledAppInfo] = []
    @State private var isLoading = true
    @State private var selectedApp: InstalledAppInfo?

    let onSelect: (InstalledAppInfo) -> Void
    let existingBundleIds: Set<String>  // Apps already added (to filter out)

    public init(
        existingBundleIds: Set<String>,
        onSelect: @escaping (InstalledAppInfo) -> Void
    ) {
        self.existingBundleIds = existingBundleIds
        self.onSelect = onSelect
    }

    private var filteredApps: [InstalledAppInfo] {
        let available = installedApps.filter { !existingBundleIds.contains($0.bundleId) }

        if searchText.isEmpty {
            return available
        }
        return available.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleId.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Application")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()
                .background(Theme.Colors.border)

            // Search field
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.Colors.textMuted)
                TextField("Search applications...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(Theme.Colors.textPrimary)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.Colors.surface)
            .cornerRadius(Theme.Radius.md)
            .padding()

            // App list
            if isLoading {
                Spacer()
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading applications...")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)
                }
                Spacer()
            } else if filteredApps.isEmpty {
                Spacer()
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "app.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.Colors.textMuted)
                    Text(searchText.isEmpty ? "No apps available" : "No matching apps found")
                        .font(Theme.Typography.callout)
                        .foregroundColor(Theme.Colors.textMuted)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            AppPickerRow(
                                app: app,
                                isSelected: selectedApp?.bundleId == app.bundleId
                            )
                            .onTapGesture {
                                selectedApp = app
                            }

                            if app.id != filteredApps.last?.id {
                                Divider()
                                    .background(Theme.Colors.border.opacity(0.5))
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }

            Divider()
                .background(Theme.Colors.border)

            // Footer with Browse and Add buttons
            HStack {
                Button(action: browseForApp) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "folder")
                        Text("Browse...")
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Add") {
                    if let app = selectedApp {
                        onSelect(app)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedApp == nil)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .background(Theme.Colors.background)
        .task {
            await loadApps()
        }
    }

    private func loadApps() async {
        // Load on background thread
        let apps = await Task.detached(priority: .userInitiated) {
            discoverInstalledApps()
        }.value

        await MainActor.run {
            self.installedApps = apps
            self.isLoading = false
        }
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Select an application to add for meeting detection"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            if let appInfo = getAppInfo(from: url) {
                // Check if already exists
                if !existingBundleIds.contains(appInfo.bundleId) {
                    onSelect(appInfo)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - App Picker Row

@available(macOS 14.0, *)
private struct AppPickerRow: View {
    let app: InstalledAppInfo
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // App icon
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .cornerRadius(6)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.Colors.textMuted)
                    .frame(width: 32, height: 32)
            }

            // App info
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

            // Selection indicator
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.Colors.primary)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            isSelected ? Theme.Colors.primaryMuted :
            (isHovered ? Theme.Colors.surfaceHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
struct AppPickerView_Previews: PreviewProvider {
    static var previews: some View {
        AppPickerView(existingBundleIds: []) { _ in }
    }
}
#endif
