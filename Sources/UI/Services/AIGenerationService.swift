// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import Foundation
import Intelligence

/// Centralized AI generation service providing streaming responses for summaries,
/// action items, and titles. Used by both the App module (auto-generation) and
/// UI module (user-triggered generation in ViewModels).
@available(macOS 14.0, *)
public enum AIGenerationService {

    // MARK: - Summary

    /// Generate a comprehensive meeting summary for a recording.
    /// Returns an AsyncThrowingStream of tokens for streaming display.
    public static func generateSummary(for recordingId: Int64) async -> AsyncThrowingStream<String, Error> {
        await AIService.shared.agentChat(
            query: "Provide a comprehensive summary of this meeting including main topics, key decisions, and important points.",
            sessionId: "auto-summary-\(recordingId)",
            recordingFilter: recordingId
        )
    }

    // MARK: - Action Items

    /// Extract action items from a recording's transcript.
    /// Returns an AsyncThrowingStream of tokens for streaming display.
    public static func generateActionItems(for recordingId: Int64) async -> AsyncThrowingStream<String, Error> {
        await AIService.shared.agentChat(
            query: """
            Extract ONLY clear action items from this meeting. Be very strict - only include items you are at least 60% confident are real action items.

            WHAT IS an action item:
            - "I will send you the report by Friday" → Action item: Send report by Friday (Owner: speaker)
            - "Can you review the proposal?" → Action item: Review the proposal (Owner: listener)
            - "We need to schedule a follow-up meeting" → Action item: Schedule follow-up meeting

            WHAT IS NOT an action item:
            - General discussion or opinions
            - Questions without clear tasks
            - Past events or completed tasks
            - Vague statements like "we should think about..."

            OUTPUT FORMAT:
            - Simple bullet list only
            - One action per line
            - Include owner if explicitly mentioned
            - If NO clear action items exist, output NOTHING (empty response)
            - Do NOT add headers, notes, or explanations
            """,
            sessionId: "auto-actions-\(recordingId)",
            recordingFilter: recordingId
        )
    }

    // MARK: - Title

    /// Generate a concise title from a meeting transcript.
    /// Returns an AsyncThrowingStream of tokens for streaming display.
    public static func generateTitle(for recordingId: Int64) async -> AsyncThrowingStream<String, Error> {
        await AIService.shared.agentChat(
            query: """
            Generate a short, descriptive title for this meeting/recording based on its transcript.

            REQUIREMENTS:
            - Maximum 8 words
            - No quotes or special characters
            - Be specific about the topic discussed
            - Use title case (capitalize main words)
            - Do NOT include prefixes like "Meeting:", "Title:", etc.
            - Output ONLY the title, nothing else

            EXAMPLES OF GOOD TITLES:
            - Q4 Budget Review and Planning
            - Engineering Team Sprint Retrospective
            - Customer Onboarding Process Discussion
            - Product Launch Marketing Strategy
            """,
            sessionId: "title-\(recordingId)-\(Date().timeIntervalSince1970)",
            recordingFilter: recordingId
        )
    }

    /// Generate a concise title from a pre-existing summary string (no RAG lookup needed).
    /// Uses directGenerate for efficiency since we already have the summary text.
    public static func generateTitleFromSummary(_ summary: String) async -> AsyncThrowingStream<String, Error> {
        let titlePrompt = """
            Based on this meeting summary, generate a concise, descriptive title (5-8 words max).
            The title should capture the main topic or purpose of the meeting.
            Return ONLY the title, nothing else. No quotes, no explanation.

            Summary:
            \(summary.prefix(1500))
            """

        return await AIService.shared.directGenerate(
            prompt: titlePrompt,
            systemPrompt: "You are a helpful assistant that generates concise meeting titles. Return only the title, nothing else."
        )
    }
}
