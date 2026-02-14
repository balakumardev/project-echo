// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import Foundation
import AVFoundation
import ScreenCaptureKit
import ApplicationServices
import AppKit
import os.log

// MARK: - Permission Status Types

/// Status for permissions that support the full authorization flow
public enum PermissionStatus: String, Sendable {
    case authorized
    case denied
    case notDetermined
    case unknown
}

/// Status for accessibility, which only reports granted/not granted
public enum AccessibilityStatus: String, Sendable {
    case granted
    case notGranted
}

// MARK: - PermissionManager

@MainActor
public final class PermissionManager: ObservableObject {

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "PermissionManager")

    // MARK: - Published Properties

    @Published public private(set) var microphoneStatus: PermissionStatus = .unknown
    @Published public private(set) var screenRecordingStatus: PermissionStatus = .unknown
    @Published public private(set) var accessibilityStatus: AccessibilityStatus = .notGranted

    /// True when both microphone and screen recording are authorized.
    /// Accessibility is informational only and not required.
    public var allRequiredGranted: Bool {
        microphoneStatus == .authorized && screenRecordingStatus == .authorized
    }

    // MARK: - Check All

    /// Refresh the status of all permissions.
    public func checkAll() {
        checkMicrophone()
        checkScreenRecording()
        checkAccessibility()
    }

    // MARK: - Microphone

    private func checkMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphoneStatus = .authorized
        case .denied, .restricted:
            microphoneStatus = .denied
        case .notDetermined:
            microphoneStatus = .notDetermined
        @unknown default:
            microphoneStatus = .unknown
        }
        logger.info("Microphone permission: \(self.microphoneStatus.rawValue)")
    }

    /// Request microphone access. Updates `microphoneStatus` after the user responds.
    public func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = granted ? .authorized : .denied
        logger.info("Microphone request result: \(granted ? "granted" : "denied")")
    }

    // MARK: - Screen Recording

    private func checkScreenRecording() {
        if #available(macOS 15, *) {
            let hasAccess = CGPreflightScreenCaptureAccess()
            screenRecordingStatus = hasAccess ? .authorized : .denied
        } else {
            // macOS 14 fallback: probe with SCShareableContent
            // We set to unknown and then probe asynchronously
            screenRecordingStatus = .unknown
            Task {
                await probeScreenRecordingMacOS14()
            }
        }
        logger.info("Screen recording permission: \(self.screenRecordingStatus.rawValue)")
    }

    /// macOS 14 fallback: attempt to fetch shareable content to detect permission status.
    private func probeScreenRecordingMacOS14() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            screenRecordingStatus = .authorized
        } catch let error as NSError {
            if error.code == -3801 || error.domain == "com.apple.screencapturekit" {
                screenRecordingStatus = .denied
            } else {
                // Other errors (e.g. no windows) likely mean permission is granted
                screenRecordingStatus = .authorized
            }
        }
        logger.info("Screen recording probe (macOS 14): \(self.screenRecordingStatus.rawValue)")
    }

    /// Request screen recording access. On macOS 15+ this triggers the system prompt.
    /// On macOS 14 it opens System Settings since there's no direct request API.
    public func requestScreenRecording() {
        if #available(macOS 15, *) {
            CGRequestScreenCaptureAccess()
            // Re-check after request (the user may not have responded yet)
            let hasAccess = CGPreflightScreenCaptureAccess()
            screenRecordingStatus = hasAccess ? .authorized : .denied
        } else {
            openScreenRecordingSettings()
        }
        logger.info("Screen recording request initiated")
    }

    // MARK: - Accessibility (Informational)

    private func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .granted : .notGranted
        logger.info("Accessibility permission: \(self.accessibilityStatus.rawValue)")
    }

    // MARK: - Open System Settings

    public func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
