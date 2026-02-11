// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import Foundation
import Intelligence
import Database
import UI
import os.log

/// Coordinates automatic AI content generation after transcription completes.
/// Handles summary generation, action items extraction, title generation,
/// transcript indexing, and missing-title regeneration on startup.
@available(macOS 14.0, *)
class AIContentCoordinator {

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "AIContent")

    // MARK: - Dependencies

    let database: DatabaseManager

    // MARK: - Settings (read from UserDefaults)

    private var autoGenerateSummary: Bool {
        UserDefaults.standard.object(forKey: "autoGenerateSummary") as? Bool ?? true
    }

    private var autoGenerateActionItems: Bool {
        UserDefaults.standard.object(forKey: "autoGenerateActionItems") as? Bool ?? true
    }

    // MARK: - Init

    init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Auto-Generate AI Content

    /// Automatically generate AI summary and action items for a recording.
    /// Called by the ProcessingQueue after transcription completes.
    func autoGenerateAIContent(recordingId: Int64) async {
        let aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true
        guard aiEnabled else { return }
        guard autoGenerateSummary || autoGenerateActionItems else { return }

        do {
            // Verify transcript exists and has meaningful content
            if let transcript = try? await database.getTranscript(forRecording: recordingId) {
                if !hasMeaningfulContent(transcript.fullText) {
                    logger.warning("Skipping auto-generation for recording \(recordingId) - transcript has no meaningful content")
                    if autoGenerateSummary {
                        try? await database.saveSummary(recordingId: recordingId, summary: "[No meaningful audio content]")
                    }
                    if autoGenerateActionItems {
                        try? await database.saveActionItems(recordingId: recordingId, actionItems: "[No action items]")
                    }
                    return
                }
            } else {
                logger.warning("Skipping auto-generation for recording \(recordingId) - no transcript found")
                return
            }

            // Generate summary if enabled
            if autoGenerateSummary {
                await generateSummary(recordingId: recordingId)
            }

            // Generate action items if enabled
            if autoGenerateActionItems {
                await generateActionItemsContent(recordingId: recordingId)
            }
        } catch {
            logger.warning("Auto AI generation failed for recording \(recordingId): \(error.localizedDescription)")
        }
    }

    // MARK: - Summary Generation

    private func generateSummary(recordingId: Int64) async {
        logger.info("Auto-generating summary for recording \(recordingId)")

        NotificationCenter.default.post(
            name: .processingDidStart,
            object: nil,
            userInfo: ["recordingId": recordingId, "type": ProcessingType.summary.rawValue]
        )

        do {
            let summaryStream = await AIGenerationService.generateSummary(for: recordingId)
            var summary = ""
            for try await token in summaryStream {
                summary += token
            }

            NotificationCenter.default.post(
                name: .processingDidComplete,
                object: nil,
                userInfo: ["recordingId": recordingId, "type": ProcessingType.summary.rawValue]
            )

            if !summary.isEmpty {
                try await database.saveSummary(recordingId: recordingId, summary: summary)
                logger.info("Auto-generated summary for recording \(recordingId)")

                try? await AIService.shared.indexRecordingSummary(recordingId: recordingId)

                FileLogger.shared.debug("[AutoGen] Summary saved for recording \(recordingId), calling generateTitleFromSummary...")
                await generateTitleFromSummary(recordingId: recordingId, summary: summary)
                FileLogger.shared.debug("[AutoGen] generateTitleFromSummary completed for recording \(recordingId)")

                NotificationCenter.default.post(
                    name: .recordingContentDidUpdate,
                    object: nil,
                    userInfo: ["recordingId": recordingId, "type": "summary"]
                )
            } else {
                try await database.saveSummary(recordingId: recordingId, summary: "[No summary generated]")
                logger.info("No summary generated for recording \(recordingId) - marked as processed")
            }
        } catch {
            NotificationCenter.default.post(
                name: .processingDidComplete,
                object: nil,
                userInfo: ["recordingId": recordingId, "type": ProcessingType.summary.rawValue]
            )
            logger.warning("Summary generation failed for recording \(recordingId): \(error.localizedDescription)")
        }
    }

    // MARK: - Action Items Generation

    private func generateActionItemsContent(recordingId: Int64) async {
        logger.info("Auto-generating action items for recording \(recordingId)")

        NotificationCenter.default.post(
            name: .processingDidStart,
            object: nil,
            userInfo: ["recordingId": recordingId, "type": ProcessingType.actionItems.rawValue]
        )

        do {
            let actionStream = await AIGenerationService.generateActionItems(for: recordingId)
            var actionItems = ""
            for try await token in actionStream {
                actionItems += token
            }

            NotificationCenter.default.post(
                name: .processingDidComplete,
                object: nil,
                userInfo: ["recordingId": recordingId, "type": ProcessingType.actionItems.rawValue]
            )

            if let cleanedActionItems = TextCleaning.cleanActionItemsResponse(actionItems) {
                try await database.saveActionItems(recordingId: recordingId, actionItems: cleanedActionItems)
                logger.info("Auto-generated action items for recording \(recordingId)")

                try? await AIService.shared.indexRecordingSummary(recordingId: recordingId)

                NotificationCenter.default.post(
                    name: .recordingContentDidUpdate,
                    object: nil,
                    userInfo: ["recordingId": recordingId, "type": "actionItems"]
                )
            } else {
                try await database.saveActionItems(recordingId: recordingId, actionItems: "[No action items]")
                logger.info("No action items found for recording \(recordingId) - marked as processed")
            }
        } catch {
            NotificationCenter.default.post(
                name: .processingDidComplete,
                object: nil,
                userInfo: ["recordingId": recordingId, "type": ProcessingType.actionItems.rawValue]
            )
            logger.warning("Action items generation failed for recording \(recordingId): \(error.localizedDescription)")
        }
    }

    // MARK: - Title Generation

    /// Generate a meaningful title from the meeting summary using LLM.
    func generateTitleFromSummary(recordingId: Int64, summary: String) async {
        FileLogger.shared.rag("[TitleGen] Starting for recording \(recordingId), summary length: \(summary.count)")
        do {
            logger.info("Generating title for recording \(recordingId) from summary...")
            FileLogger.shared.rag("[TitleGen] Calling directGenerate for recording \(recordingId)...")

            let titleStream = await AIGenerationService.generateTitleFromSummary(summary)

            var generatedTitle = ""
            for try await token in titleStream {
                generatedTitle += token
            }
            FileLogger.shared.rag("[TitleGen] Raw generated title length: \(generatedTitle.count)")

            // Strip <think>...</think> tags from reasoning models
            if let thinkEndRange = generatedTitle.range(of: "</think>") {
                generatedTitle = String(generatedTitle[thinkEndRange.upperBound...])
                FileLogger.shared.rag("[TitleGen] Stripped thinking tags, remaining: '\(generatedTitle)'")
            }

            // Clean up the generated title
            generatedTitle = generatedTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "\n", with: " ")

            guard !generatedTitle.isEmpty, generatedTitle.count >= 3, generatedTitle.count <= 100 else {
                logger.warning("Generated title is invalid: '\(generatedTitle)'")
                FileLogger.shared.rag("[TitleGen] INVALID title for recording \(recordingId): '\(generatedTitle)' (length: \(generatedTitle.count))")
                return
            }

            FileLogger.shared.rag("[TitleGen] Updating database title for recording \(recordingId) to: '\(generatedTitle)'")
            try await database.updateTitle(recordingId: recordingId, newTitle: generatedTitle)
            logger.info("Updated recording \(recordingId) title to: \(generatedTitle)")
            FileLogger.shared.rag("[TitleGen] SUCCESS: Recording \(recordingId) title updated to: '\(generatedTitle)'")

            NotificationCenter.default.post(
                name: .recordingContentDidUpdate,
                object: nil,
                userInfo: ["recordingId": recordingId, "type": "title"]
            )

        } catch {
            logger.warning("Failed to generate title for recording \(recordingId): \(error.localizedDescription)")
            FileLogger.shared.rag("[TitleGen] ERROR for recording \(recordingId): \(error.localizedDescription)")
        }
    }

    // MARK: - Transcript Indexing

    /// Automatically index a transcript for RAG search.
    func autoIndexTranscript(recordingId: Int64, transcriptId: Int64) async {
        do {
            let recording = try await database.getRecording(id: recordingId)
            guard let transcript = try await database.getTranscript(forRecording: recordingId) else {
                logger.warning("No transcript found for recording \(recordingId), skipping indexing")
                return
            }
            let segments = try await database.getSegments(forTranscriptId: transcriptId)

            try await AIService.shared.indexRecording(recording, transcript: transcript, segments: segments)
            logger.info("Auto-indexed transcript for recording \(recordingId)")
        } catch {
            logger.warning("Auto-indexing failed for recording \(recordingId): \(error.localizedDescription)")
        }
    }

    // MARK: - Missing Title Regeneration

    /// Regenerate titles for recordings that have summaries but still have generic titles.
    /// Called on startup after AI service is initialized.
    func regenerateMissingTitles() async {
        // Wait for AI service to be ready
        FileLogger.shared.debug("[TitleRegen] Waiting for AI service to be ready...")
        var waitCount = 0
        var aiReady = await AIService.shared.isReady
        while !aiReady && waitCount < 180 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waitCount += 1
            if waitCount % 30 == 0 {
                FileLogger.shared.debug("[TitleRegen] Still waiting for AI service... (\(waitCount)s)")
            }
            aiReady = await AIService.shared.isReady
        }

        guard aiReady else {
            FileLogger.shared.debug("[TitleRegen] AI service not ready after 180s, skipping title regeneration")
            return
        }
        FileLogger.shared.debug("[TitleRegen] AI service ready, starting title regeneration")

        do {
            let recordings = try await database.getAllRecordings()
            for recording in recordings {
                let isGenericTitle = recording.title.hasPrefix("Zoom_Meeting_") ||
                                     recording.title.hasPrefix("Zoom_Workplace_") ||
                                     recording.title.hasPrefix("Zoom Meeting")

                let hasSummary = recording.summary != nil &&
                                 !recording.summary!.isEmpty &&
                                 !recording.summary!.hasPrefix("[No")

                if isGenericTitle && hasSummary {
                    FileLogger.shared.debug("[TitleRegen] Recording \(recording.id) needs title regeneration")
                    await generateTitleFromSummary(recordingId: recording.id, summary: recording.summary!)
                }
            }
        } catch {
            logger.warning("Failed to check for missing titles: \(error.localizedDescription)")
        }
    }

    // MARK: - Content Analysis

    /// Check if transcript has meaningful content worth generating AI summary for.
    /// Returns false for empty transcripts or transcripts with only noise markers.
    func hasMeaningfulContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let cleanedText = trimmed
            .replacingOccurrences(of: #"\[\d+:\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(Unknown|Speaker\s*\d*|You):"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let noiseMarkers = [
            "[INAUDIBLE]", "[inaudible]",
            "[SILENCE]", "[silence]",
            "[NOISE]", "[noise]",
            "[MUSIC]", "[music]",
            "[BLANK_AUDIO]", "[blank_audio]",
            "[BACKGROUND_NOISE]", "[background_noise]"
        ]

        var textWithoutNoise = cleanedText
        for marker in noiseMarkers {
            textWithoutNoise = textWithoutNoise.replacingOccurrences(of: marker, with: "")
        }
        textWithoutNoise = textWithoutNoise.trimmingCharacters(in: .whitespacesAndNewlines)

        if textWithoutNoise.count < 20 {
            return false
        }

        let words = textWithoutNoise.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if words.count < 3 {
            return false
        }

        return true
    }
}
