// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import SwiftUI
import ServiceManagement
import Intelligence

// MARK: - About Settings View

@available(macOS 14.0, *)
public struct AboutSettingsView: View {
    @State private var showResetConfirmation = false
    @State private var isResetting = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 20) {
                // App icon and name
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.Colors.primary, Theme.Colors.secondary],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 64, height: 64)

                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.white)
                    }
                    .shadow(color: Theme.Colors.primary.opacity(0.3), radius: 10, y: 3)

                    VStack(spacing: 4) {
                        Text("Engram")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(Theme.Colors.textPrimary)

                        Text("Version \(appVersion)")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.Colors.textMuted)
                    }

                    Text("Your meetings, remembered.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Colors.textSecondary)
                        .italic()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                // Links
                HStack(spacing: 16) {
                    AboutLink(title: "Website", icon: "globe", urlString: "https://balakumar.dev")
                    AboutLink(title: "GitHub", icon: "chevron.left.forwardslash.chevron.right", urlString: "https://github.com/nickkumara")
                }

                // Privacy section
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.Colors.success)
                        Text("PRIVACY")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.Colors.textMuted)
                            .tracking(0.5)
                    }
                    .padding(.bottom, Theme.Spacing.md)

                    VStack(alignment: .leading, spacing: 0) {
                        PrivacyFeatureRow(
                            icon: "internaldrive.fill",
                            title: "Audio stored locally",
                            description: "All recordings are saved only on your Mac"
                        )

                        Divider().padding(.vertical, 8)

                        PrivacyFeatureRow(
                            icon: "cpu.fill",
                            title: "On-device AI transcription",
                            description: "WhisperKit runs entirely on your hardware"
                        )

                        Divider().padding(.vertical, 8)

                        PrivacyFeatureRow(
                            icon: "icloud.slash.fill",
                            title: "No cloud uploads",
                            description: "Your audio never leaves your device"
                        )

                        Divider().padding(.vertical, 8)

                        PrivacyFeatureRow(
                            icon: "chart.bar.xaxis",
                            title: "No analytics or tracking",
                            description: "Zero telemetry, no usage data collected"
                        )
                    }
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

                // Reset section
                SettingsSection(title: "Reset", icon: "arrow.counterclockwise") {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset All Settings")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Colors.textPrimary)
                            Text("Restore all settings to their defaults")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Colors.textMuted)
                        }

                        Spacer()

                        Button {
                            showResetConfirmation = true
                        } label: {
                            if isResetting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Reset")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Theme.Colors.error)
                        .disabled(isResetting)
                    }
                }

                // Footer
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Crafted by")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Colors.textMuted)
                        Button("Bala Kumar") {
                            if let url = URL(string: "https://balakumar.dev") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.Colors.primary)
                    }

                    Text("\u{00A9} 2024-2026 Bala Kumar. All rights reserved.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.textMuted)
                }
                .padding(.top, 4)
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
        .alert("Reset All Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text("This will restore all settings to their defaults. This cannot be undone.")
        }
    }

    private func resetAllSettings() {
        isResetting = true

        // General settings
        UserDefaults.standard.removeObject(forKey: "autoRecord")
        UserDefaults.standard.removeObject(forKey: "autoTranscribe")
        UserDefaults.standard.removeObject(forKey: "storageLocation")
        UserDefaults.standard.removeObject(forKey: "autoRecordOnWake")
        UserDefaults.standard.removeObject(forKey: "recordVideoEnabled")
        UserDefaults.standard.removeObject(forKey: "windowSelectionMode")
        UserDefaults.standard.removeObject(forKey: "sampleRate")
        UserDefaults.standard.removeObject(forKey: "audioQuality")
        UserDefaults.standard.removeObject(forKey: "enabledMeetingApps")
        UserDefaults.standard.removeObject(forKey: "customMeetingApps")

        // AI settings
        UserDefaults.standard.removeObject(forKey: "aiEnabled")
        UserDefaults.standard.removeObject(forKey: "autoIndexTranscripts")
        UserDefaults.standard.removeObject(forKey: "autoGenerateSummary")
        UserDefaults.standard.removeObject(forKey: "autoGenerateActionItems")
        UserDefaults.standard.removeObject(forKey: "showChatPanel_v2")

        // Transcription settings
        UserDefaults.standard.removeObject(forKey: "transcriptionProvider")
        UserDefaults.standard.removeObject(forKey: "geminiAPIKey")
        UserDefaults.standard.removeObject(forKey: "geminiModel")
        UserDefaults.standard.removeObject(forKey: "whisperModel")

        // AI Service config (JSON blob)
        UserDefaults.standard.removeObject(forKey: "AIService.config")

        // Reload custom apps
        CustomMeetingAppsManager.shared.loadCustomApps()

        // Unregister login item
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval {
            try? SMAppService.mainApp.unregister()
        }

        // Unload AI model
        Task {
            await AIService.shared.unloadModel()
            await MainActor.run {
                isResetting = false
            }
        }
    }
}
