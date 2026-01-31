// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import Foundation
import os.log

/// Gemini cloud transcription client
/// Sends audio to Google's Generative AI API for transcription with speaker diarization
@available(macOS 14.0, *)
public actor GeminiTranscriber {

    // MARK: - Types

    public enum GeminiError: Error, LocalizedError {
        case missingAPIKey
        case audioFileTooLarge(Int)
        case audioEncodingFailed
        case networkError(Error)
        case invalidResponse(String)
        case apiError(String)
        case parseError(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Gemini API key is not configured"
            case .audioFileTooLarge(let size):
                return "Audio file is too large (\(size / 1_000_000)MB). Maximum is 20MB for inline upload."
            case .audioEncodingFailed:
                return "Failed to encode audio file"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse(let details):
                return "Invalid API response: \(details)"
            case .apiError(let message):
                return "Gemini API error: \(message)"
            case .parseError(let details):
                return "Failed to parse transcription: \(details)"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "GeminiTranscriber")
    private let maxInlineFileSize = 20 * 1024 * 1024 // 20MB

    // API endpoint
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    /// Transcribe an audio file using Gemini API
    /// - Parameters:
    ///   - audioURL: URL to the audio file
    ///   - apiKey: Gemini API key
    ///   - model: Gemini model to use
    /// - Returns: Array of transcription segments with timestamps and speaker labels
    public func transcribe(
        audioURL: URL,
        apiKey: String,
        model: GeminiModel
    ) async throws -> [TranscriptionSegment] {
        guard !apiKey.isEmpty else {
            throw GeminiError.missingAPIKey
        }

        logger.info("Starting Gemini transcription with model: \(model.rawValue)")
        fileRagLog("[Gemini] Starting transcription: \(audioURL.lastPathComponent), model: \(model.rawValue)")

        // Read and encode audio file
        let audioData = try readAudioFile(url: audioURL)

        // Check file size
        guard audioData.count <= maxInlineFileSize else {
            throw GeminiError.audioFileTooLarge(audioData.count)
        }

        // Detect MIME type
        let mimeType = detectMimeType(for: audioURL)

        // Build and send request
        let request = try buildRequest(
            audioData: audioData,
            mimeType: mimeType,
            apiKey: apiKey,
            model: model
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        // Check HTTP status
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse("Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
            logger.error("Gemini API error: \(httpResponse.statusCode) - \(errorBody)")
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        // Parse response
        let segments = try parseResponse(data: data)
        logger.info("Gemini transcription complete: \(segments.count) segments")
        fileRagLog("[Gemini] Transcription complete: \(segments.count) segments")

        return segments
    }

    // MARK: - Private Helpers

    private func readAudioFile(url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw GeminiError.audioEncodingFailed
        }
    }

    private func detectMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3":
            return "audio/mp3"
        case "wav":
            return "audio/wav"
        case "m4a", "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        case "ogg":
            return "audio/ogg"
        case "mp4":
            return "audio/mp4"
        default:
            return "audio/mp4"
        }
    }

    private func buildRequest(
        audioData: Data,
        mimeType: String,
        apiKey: String,
        model: GeminiModel
    ) throws -> URLRequest {
        let endpoint = "\(baseURL)/\(model.rawValue):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw GeminiError.invalidResponse("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body with audio and transcription prompt
        let base64Audio = audioData.base64EncodedString()

        let prompt = """
        Transcribe this audio with timestamps and speaker identification.

        Format each segment exactly as:
        [MM:SS-MM:SS] Speaker X: "Transcribed text"

        Rules:
        - Use "You" for the person whose voice is clearest/loudest (typically the meeting host/local user)
        - Use "Speaker 1", "Speaker 2", etc. for other participants
        - Include timestamps in MM:SS format (minutes:seconds)
        - Keep segments short (1-3 sentences each)
        - Preserve natural speech patterns but clean up filler words
        - If speaker cannot be determined, use "Unknown"

        Output ONLY the formatted transcription, no other text.
        """

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": mimeType,
                                "data": base64Audio
                            ]
                        ],
                        [
                            "text": prompt
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 8192
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return request
    }

    private func parseResponse(data: Data) throws -> [TranscriptionSegment] {
        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw GeminiError.invalidResponse("Could not extract text from response")
        }

        fileRagLog("[Gemini] Raw response text:\n\(text)")

        // Parse the formatted transcription
        return parseTranscriptionText(text)
    }

    /// Parse transcription text in format: [MM:SS-MM:SS] Speaker X: "text"
    private func parseTranscriptionText(_ text: String) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []

        // Pattern: [MM:SS-MM:SS] Speaker: "text"
        // Also handles [M:SS-M:SS] and [HH:MM:SS-HH:MM:SS]
        let pattern = #"\[(\d{1,2}:\d{2}(?::\d{2})?)-(\d{1,2}:\d{2}(?::\d{2})?)\]\s*([^:]+):\s*["""]?(.+?)["""]?\s*$"#

        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
               let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) {

                let startTimeStr = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let endTimeStr = String(trimmed[Range(match.range(at: 2), in: trimmed)!])
                let speakerStr = String(trimmed[Range(match.range(at: 3), in: trimmed)!]).trimmingCharacters(in: .whitespaces)
                let textContent = String(trimmed[Range(match.range(at: 4), in: trimmed)!]).trimmingCharacters(in: .whitespaces)

                let startTime = parseTimestamp(startTimeStr)
                let endTime = parseTimestamp(endTimeStr)
                let speaker = parseSpeaker(speakerStr)

                // Skip empty segments
                guard !textContent.isEmpty else { continue }

                let segment = TranscriptionSegment(
                    start: startTime,
                    end: endTime,
                    text: textContent,
                    speaker: speaker
                )
                segments.append(segment)
            }
        }

        // If no segments parsed with the strict pattern, try a more lenient approach
        if segments.isEmpty {
            fileRagLog("[Gemini] Strict parsing failed, trying lenient parsing")
            return parseLenient(text)
        }

        return segments
    }

    /// More lenient parsing for when Gemini doesn't follow the exact format
    private func parseLenient(_ text: String) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        var currentTime: TimeInterval = 0
        let segmentDuration: TimeInterval = 5.0 // Estimate 5 seconds per segment

        // Look for speaker patterns like "Speaker 1:", "You:", "Speaker X:" followed by text
        let speakerPattern = #"(You|Speaker\s*\d+|Unknown)[:\s]+(.+?)(?=(?:You|Speaker\s*\d+|Unknown)[:\s]|$)"#

        if let regex = try? NSRegularExpression(pattern: speakerPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))

            for match in matches {
                let speakerStr = String(text[Range(match.range(at: 1), in: text)!])
                let content = String(text[Range(match.range(at: 2), in: text)!])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")

                guard !content.isEmpty else { continue }

                let speaker = parseSpeaker(speakerStr)
                let segment = TranscriptionSegment(
                    start: currentTime,
                    end: currentTime + segmentDuration,
                    text: content,
                    speaker: speaker
                )
                segments.append(segment)
                currentTime += segmentDuration
            }
        }

        // Fallback: if still no segments, create one segment with all text
        if segments.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(TranscriptionSegment(
                start: 0,
                end: 30,
                text: cleanText,
                speaker: .unknown
            ))
        }

        return segments
    }

    /// Parse timestamp string (MM:SS or HH:MM:SS) to TimeInterval
    private func parseTimestamp(_ str: String) -> TimeInterval {
        let components = str.split(separator: ":").compactMap { Double($0) }

        switch components.count {
        case 2: // MM:SS
            return components[0] * 60 + components[1]
        case 3: // HH:MM:SS
            return components[0] * 3600 + components[1] * 60 + components[2]
        default:
            return 0
        }
    }

    /// Parse speaker string to Speaker enum
    private func parseSpeaker(_ str: String) -> TranscriptionEngine.Speaker {
        let normalized = str.lowercased().trimmingCharacters(in: .whitespaces)

        if normalized == "you" || normalized == "me" || normalized == "host" {
            return .user
        } else if normalized == "unknown" {
            return .unknown
        } else if normalized.contains("speaker") {
            // Extract speaker number
            let digits = normalized.filter { $0.isNumber }
            if let num = Int(digits), num > 0 {
                return .remote(num - 1) // Convert to 0-indexed
            }
            return .remote(0)
        }

        return .unknown
    }
}

// MARK: - Internal Segment Type

/// Internal segment type for GeminiTranscriber that matches TranscriptionEngine.Segment
public struct TranscriptionSegment: Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let speaker: TranscriptionEngine.Speaker

    public init(start: TimeInterval, end: TimeInterval, text: String, speaker: TranscriptionEngine.Speaker) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }

    /// Convert to TranscriptionEngine.Segment
    public func toEngineSegment(confidence: Float = 0.9) -> TranscriptionEngine.Segment {
        TranscriptionEngine.Segment(
            start: start,
            end: end,
            text: text,
            speaker: speaker,
            confidence: confidence
        )
    }
}
