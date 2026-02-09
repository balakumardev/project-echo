// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import Foundation

/// Protocol for the App module to implement transcription settings application.
/// Decouples settings views from AppDelegate.
@MainActor
public protocol TranscriptionSettingsDelegate: AnyObject {
    /// Push transcription config from UserDefaults to the running engine and reload model if needed.
    /// Throws on error so the UI can display feedback.
    func applyTranscriptionConfig() async throws
}

/// Central registry for settings delegates.
/// AppDelegate registers itself at startup; settings views call through here.
@MainActor
public enum SettingsEnvironment {
    public static weak var transcriptionDelegate: TranscriptionSettingsDelegate?
}
