// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import SwiftUI
import AVFoundation

// MARK: - Permission Setup View

/// Self-contained permission setup UI for the Settings window.
/// Uses its own observable to check macOS permissions directly,
/// following the same pattern as AIServiceObservable in AISettingsView.
@available(macOS 14.0, *)
public struct PermissionSetupView: View {
    @StateObject private var permissions = PermissionStatusObservable()

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // Success banner when all required permissions granted
                if permissions.allRequiredGranted {
                    successBanner
                }

                // Required Permissions
                SettingsSection(title: "Required Permissions", icon: "lock.shield") {
                    VStack(alignment: .leading, spacing: 0) {
                        permissionCard(
                            icon: "mic.fill",
                            title: "Microphone",
                            description: "Record your voice during meetings",
                            status: permissions.microphoneDisplay,
                            actionLabel: permissions.microphoneDisplay == .denied ? "Open Settings" : "Grant Access",
                            action: { permissions.requestMicrophone() }
                        )

                        Divider().padding(.vertical, Theme.Spacing.sm)

                        permissionCard(
                            icon: "rectangle.inset.filled.and.person.filled",
                            title: "Screen Recording",
                            description: "Capture audio from apps like Zoom and Teams",
                            status: permissions.screenRecordingDisplay,
                            actionLabel: "Open Settings",
                            action: { permissions.requestScreenRecording() }
                        )
                    }
                }

                // Optional Permissions
                SettingsSection(title: "Optional Permissions", icon: "sparkles") {
                    permissionCard(
                        icon: "accessibility",
                        title: "Accessibility",
                        description: "Enables advanced features in future updates",
                        status: permissions.accessibilityDisplay,
                        actionLabel: "Open Settings",
                        action: { permissions.openAccessibilitySettings() },
                        isOptional: true
                    )
                }

                // Helper text and refresh
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.Colors.textMuted)
                        Text("After granting permissions in System Settings, click Refresh or restart Engram.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Colors.textMuted)
                    }

                    Button {
                        permissions.checkAll()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                            Text("Refresh")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.Colors.background)
    }

    // MARK: - Display Status (View-local)

    /// Display-only status used for badge rendering in this view.
    enum DisplayStatus {
        case granted
        case required
        case denied
        case optional
    }

    // MARK: - Success Banner

    private var successBanner: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 24))
                .foregroundColor(Theme.Colors.success)

            VStack(alignment: .leading, spacing: 2) {
                Text("You're all set!")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Colors.textPrimary)
                Text("All required permissions are granted. Engram is ready to record.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Colors.textSecondary)
            }

            Spacer()
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Colors.success.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.Colors.success.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Permission Card

    @ViewBuilder
    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        status: DisplayStatus,
        actionLabel: String,
        action: @escaping () -> Void,
        isOptional: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(isOptional ? Theme.Colors.textSecondary : Theme.Colors.primary)
                .frame(width: 28, height: 28)

            // Title + description
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Colors.textPrimary)

                    statusBadge(for: status)
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Colors.textMuted)
            }

            Spacer()

            // Action button (hidden when granted)
            if status != .granted {
                Button(actionLabel, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.Colors.success)
            }
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private func statusBadge(for status: DisplayStatus) -> some View {
        switch status {
        case .granted:
            badgeLabel("Granted", color: Theme.Colors.success)
        case .required:
            badgeLabel("Required", color: Theme.Colors.warning)
        case .denied:
            badgeLabel("Denied", color: Theme.Colors.error)
        case .optional:
            badgeLabel("Optional", color: Theme.Colors.textMuted)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
    }
}

// MARK: - Permission Status Observable

/// Self-contained observable that checks macOS permission status directly.
/// Lives in the UI module — no dependency on App module's PermissionManager.
/// Follows the AIServiceObservable polling pattern for reactivity.
@available(macOS 14.0, *)
@MainActor
class PermissionStatusObservable: ObservableObject {
    @Published var microphoneAuthorized: Bool = false
    @Published var microphoneDenied: Bool = false
    @Published var screenRecordingAuthorized: Bool = false
    @Published var accessibilityGranted: Bool = false

    init() {
        checkAll()
    }

    // MARK: - Display Mappings

    var microphoneDisplay: PermissionSetupView.DisplayStatus {
        if microphoneAuthorized { return .granted }
        if microphoneDenied { return .denied }
        return .required
    }

    var screenRecordingDisplay: PermissionSetupView.DisplayStatus {
        if screenRecordingAuthorized { return .granted }
        return .required
    }

    var accessibilityDisplay: PermissionSetupView.DisplayStatus {
        if accessibilityGranted { return .granted }
        return .optional
    }

    var allRequiredGranted: Bool {
        microphoneAuthorized && screenRecordingAuthorized
    }

    // MARK: - Check All Permissions

    func checkAll() {
        checkMicrophone()
        checkScreenRecording()
        checkAccessibility()
    }

    // MARK: - Microphone

    private func checkMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphoneAuthorized = true
            microphoneDenied = false
        case .denied, .restricted:
            microphoneAuthorized = false
            microphoneDenied = true
        case .notDetermined:
            microphoneAuthorized = false
            microphoneDenied = false
        @unknown default:
            microphoneAuthorized = false
            microphoneDenied = false
        }
    }

    func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.microphoneAuthorized = granted
                    self?.microphoneDenied = !granted
                }
            }
        } else if status == .denied || status == .restricted {
            openMicrophoneSettings()
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Screen Recording

    private func checkScreenRecording() {
        screenRecordingAuthorized = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecording() {
        openScreenRecordingSettings()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility

    private func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
