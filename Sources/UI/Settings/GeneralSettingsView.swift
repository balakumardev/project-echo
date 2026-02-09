// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import SwiftUI
import ServiceManagement

// MARK: - General Settings View

public struct GeneralSettingsView: View {
    @AppStorage("autoRecord") private var autoRecord = true
    @AppStorage("autoTranscribe") private var autoTranscribe = true
    @AppStorage("storageLocation") private var storageLocation = "~/Documents/Engram"
    @AppStorage("autoRecordOnWake") private var autoRecordOnWake: Bool = true
    @AppStorage("recordVideoEnabled") private var recordVideoEnabled: Bool = false
    @AppStorage("windowSelectionMode") private var windowSelectionMode: String = "smart"
    @AppStorage("sampleRate") private var sampleRate = 48000
    @AppStorage("audioQuality") private var audioQuality = "high"

    // Login item state
    @State private var launchAtLogin: Bool = false
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var isLoadingLoginStatus: Bool = true
    @State private var loginItemError: String?
    @State private var showLoginItemError: Bool = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Startup Section
                SettingsSection(title: "Startup", icon: "power") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at Login")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)
                                Text("Automatically start Engram when you log in")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            if isLoadingLoginStatus {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 51, height: 31) // Match toggle size
                            } else {
                                Toggle("", isOn: $launchAtLogin)
                                    .toggleStyle(.switch)
                                    .tint(Theme.Colors.primary)
                                    .labelsHidden()
                                    .onChange(of: launchAtLogin) { _, newValue in
                                        setLoginItemEnabled(newValue)
                                    }
                            }
                        }

                        // Show status if requires approval (using cached status to avoid blocking main thread)
                        if !isLoadingLoginStatus && loginItemStatus == .requiresApproval {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 11))
                                Text("Open System Settings > General > Login Items to approve")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                            .padding(.top, 8)
                        }
                    }
                }
                .task {
                    // Load login item status asynchronously to avoid blocking main thread
                    // SMAppService.mainApp.status is slow (~1-3s) as it queries launch services
                    await loadLoginItemStatusAsync()
                }
                .alert("Login Item Error", isPresented: $showLoginItemError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(loginItemError ?? "An unknown error occurred")
                }

                // Recording Section
                SettingsSection(title: "Recording", icon: "waveform") {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsToggle(
                            title: "Auto-record Meetings",
                            subtitle: "Automatically start recording when a meeting app uses your microphone",
                            isOn: $autoRecord
                        )

                        Divider().padding(.vertical, Theme.Spacing.sm)

                        SettingsToggle(
                            title: "Auto-transcribe recordings",
                            subtitle: "Automatically transcribe recordings when they finish",
                            isOn: $autoTranscribe
                        )

                        Divider().padding(.vertical, Theme.Spacing.sm)

                        SettingsToggle(
                            title: "Resume on wake",
                            subtitle: "Check for active meetings when your Mac wakes from sleep",
                            isOn: $autoRecordOnWake
                        )

                        Divider().padding(.vertical, Theme.Spacing.sm)

                        SettingsToggle(
                            title: "Record screen video",
                            subtitle: "Capture meeting window video along with audio (uses more storage)",
                            isOn: $recordVideoEnabled
                        )

                        if recordVideoEnabled {
                            Divider().padding(.vertical, Theme.Spacing.sm)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Window selection")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.Colors.textPrimary)

                                Picker("", selection: $windowSelectionMode) {
                                    Text("Smart").tag("smart")
                                    Text("Always Ask").tag("alwaysAsk")
                                    Text("Auto").tag("auto")
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                Text(windowSelectionHelpText)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Colors.textMuted)
                            }
                            .padding(.leading, 8)
                        }
                    }
                }

                // Meeting Apps Section
                if autoRecord {
                    SettingsSection(title: "Meeting Apps", icon: "app.badge.checkmark") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Select which apps to monitor for meetings:")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)

                            MeetingAppsPickerView()
                        }
                    }
                }

                // Audio Quality Section
                SettingsSection(title: "Audio Quality", icon: "waveform.badge.plus") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sample Rate")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Colors.textPrimary)

                            Picker("", selection: $sampleRate) {
                                Text("44.1 kHz").tag(44100)
                                Text("48 kHz").tag(48000)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Quality Preset")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Colors.textPrimary)

                            Picker("", selection: $audioQuality) {
                                Text("Standard").tag("standard")
                                Text("High").tag("high")
                                Text("Maximum").tag("maximum")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("Higher quality uses more disk space")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                        }
                    }
                }

                // Storage Section
                SettingsSection(title: "Storage", icon: "folder") {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.Colors.secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Storage Location")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Colors.textPrimary)
                            Text(storageLocation)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button("Change...") {
                            chooseStorageLocation()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
    }

    private func chooseStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            storageLocation = url.path
        }
    }

    private var windowSelectionHelpText: String {
        switch windowSelectionMode {
        case "alwaysAsk":
            return "You'll choose which window to record for every meeting"
        case "auto":
            return "Automatically picks the meeting window without asking"
        default:
            return "Detects meeting window automatically, asks only if uncertain"
        }
    }

    /// Loads login item status asynchronously to avoid blocking the main thread
    /// SMAppService.mainApp.status is slow (~1-3s) as it communicates with launch services daemon
    private func loadLoginItemStatusAsync() async {
        isLoadingLoginStatus = true

        // Run the slow status check on a background thread
        let status = await Task.detached(priority: .userInitiated) {
            SMAppService.mainApp.status
        }.value

        // Update UI on main thread
        await MainActor.run {
            loginItemStatus = status
            updateLoginItemStateFromCachedStatus()
            isLoadingLoginStatus = false
        }
    }

    /// Updates the toggle state based on the cached SMAppService status (fast, no system calls)
    private func updateLoginItemStateFromCachedStatus() {
        switch loginItemStatus {
        case .enabled:
            launchAtLogin = true
        case .notRegistered, .notFound:
            launchAtLogin = false
        case .requiresApproval:
            // User needs to approve in System Settings, but we keep it "on" to show intent
            launchAtLogin = true
        @unknown default:
            launchAtLogin = false
        }
    }

    /// Registers or unregisters the app as a login item
    private func setLoginItemEnabled(_ enabled: Bool) {
        // Use cached status to avoid blocking main thread with repeated status checks
        let currentStatus = loginItemStatus

        do {
            if enabled {
                // Check if already enabled to avoid unnecessary registration
                if currentStatus != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                // Only unregister if currently registered
                if currentStatus == .enabled || currentStatus == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            }
            // Refresh status asynchronously after change
            Task {
                await loadLoginItemStatusAsync()
            }
        } catch {
            loginItemError = error.localizedDescription
            showLoginItemError = true
            // Refresh status asynchronously to revert toggle to actual state
            Task {
                await loadLoginItemStatusAsync()
            }
        }
    }
}
