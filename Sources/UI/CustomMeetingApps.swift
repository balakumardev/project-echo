import Foundation
import AppKit

// MARK: - Custom Meeting App Model

/// Represents a user-added custom meeting app
public struct CustomMeetingApp: Codable, Identifiable, Equatable, Sendable {
    public let id: String           // UUID for unique identification
    public let bundleId: String     // App bundle identifier
    public let displayName: String  // User-visible app name
    public let addedDate: Date      // When user added this app

    public init(bundleId: String, displayName: String) {
        self.id = UUID().uuidString
        self.bundleId = bundleId
        self.displayName = displayName
        self.addedDate = Date()
    }
}

// MARK: - Custom Apps Manager

/// Manages persistence and retrieval of custom meeting apps
@MainActor
public class CustomMeetingAppsManager: ObservableObject {

    public static let shared = CustomMeetingAppsManager()

    @Published public private(set) var customApps: [CustomMeetingApp] = []

    private let storageKey = "customMeetingApps"

    private init() {
        loadCustomApps()
    }

    /// Load custom apps from UserDefaults
    public func loadCustomApps() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let apps = try? JSONDecoder().decode([CustomMeetingApp].self, from: data) else {
            customApps = []
            return
        }
        customApps = apps
    }

    /// Save custom apps to UserDefaults
    private func saveCustomApps() {
        guard let data = try? JSONEncoder().encode(customApps) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Add a new custom app
    @discardableResult
    public func addApp(bundleId: String, displayName: String) -> Bool {
        // Check if already exists
        guard !customApps.contains(where: { $0.bundleId == bundleId }) else {
            return false
        }

        let app = CustomMeetingApp(bundleId: bundleId, displayName: displayName)
        customApps.append(app)
        saveCustomApps()

        // Auto-enable the newly added app
        addToEnabledApps(bundleId: bundleId)

        return true
    }

    /// Remove a custom app
    public func removeApp(id: String) {
        guard let app = customApps.first(where: { $0.id == id }) else { return }
        customApps.removeAll { $0.id == id }
        saveCustomApps()

        // Remove from enabled apps
        removeFromEnabledApps(bundleId: app.bundleId)
    }

    /// Get bundle IDs of all custom apps
    public func getCustomBundleIds() -> Set<String> {
        Set(customApps.map { $0.bundleId })
    }

    /// Check if an app is a custom app
    public func isCustomApp(bundleId: String) -> Bool {
        customApps.contains { $0.bundleId == bundleId }
    }

    /// Check if a custom app is enabled
    public func isEnabled(bundleId: String) -> Bool {
        let enabledApps = getEnabledApps()
        return enabledApps.contains(bundleId)
    }

    // MARK: - Enabled State Helpers

    private func getEnabledApps() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: "enabledMeetingApps") ?? ""
        return Set(raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    }

    private func addToEnabledApps(bundleId: String) {
        var enabledApps = getEnabledApps()
        enabledApps.insert(bundleId)
        UserDefaults.standard.set(enabledApps.sorted().joined(separator: ","), forKey: "enabledMeetingApps")
    }

    private func removeFromEnabledApps(bundleId: String) {
        var enabledApps = getEnabledApps()
        enabledApps.remove(bundleId)
        UserDefaults.standard.set(enabledApps.sorted().joined(separator: ","), forKey: "enabledMeetingApps")
    }
}

// MARK: - Installed Apps Discovery

/// Info about an installed application
public struct InstalledAppInfo: Identifiable, Equatable {
    public let id: String  // bundleId
    public let bundleId: String
    public let displayName: String
    public let icon: NSImage?
    public let path: URL
}

/// Discover installed applications from standard locations
public func discoverInstalledApps() -> [InstalledAppInfo] {
    var apps: [InstalledAppInfo] = []

    let applicationDirs = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]

    let fm = FileManager.default

    for appDir in applicationDirs {
        guard let contents = try? fm.contentsOfDirectory(
            at: appDir,
            includingPropertiesForKeys: [.isApplicationKey],
            options: [.skipsHiddenFiles]
        ) else { continue }

        for url in contents where url.pathExtension == "app" {
            if let appInfo = getAppInfo(from: url) {
                // Avoid duplicates
                if !apps.contains(where: { $0.bundleId == appInfo.bundleId }) {
                    apps.append(appInfo)
                }
            }
        }
    }

    // Sort alphabetically by display name
    return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
}

/// Get app info from a specific .app path
public func getAppInfo(from url: URL) -> InstalledAppInfo? {
    guard let bundle = Bundle(url: url),
          let bundleId = bundle.bundleIdentifier else { return nil }

    let displayName = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
        ?? (bundle.infoDictionary?["CFBundleName"] as? String)
        ?? url.deletingPathExtension().lastPathComponent

    let icon = NSWorkspace.shared.icon(forFile: url.path)

    return InstalledAppInfo(
        id: bundleId,
        bundleId: bundleId,
        displayName: displayName,
        icon: icon,
        path: url
    )
}
