// Engram - Privacy-first meeting recorder with local AI
// Copyright © 2024-2026 Bala Kumar. All rights reserved.
// https://balakumar.dev

import AVFoundation
import Foundation
import os.log

/// Gemini cloud transcription client
/// Sends audio to Google's Generative AI API for transcription with speaker diarization
/// Supports both inline upload (< 20MB) and File API upload (up to 2GB) for large recordings
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
        case fileProcessingFailed
        case fileProcessingTimeout

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Gemini API key is not configured"
            case .audioFileTooLarge(let size):
                return "Audio file is too large (\(size / 1_000_000)MB). Maximum is 2GB via File API."
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
            case .fileProcessingFailed:
                return "Gemini failed to process the uploaded file"
            case .fileProcessingTimeout:
                return "Gemini file processing timed out"
            }
        }
    }

    private struct UploadedFile {
        let name: String
        let uri: String
        let mimeType: String
        let state: String
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "dev.balakumar.engram", category: "GeminiTranscriber")
    private let maxInlineFileSize = 20 * 1024 * 1024 // 20MB

    // API endpoints
    private let apiBase = "https://generativelanguage.googleapis.com"
    private let modelsPath = "/v1beta/models"
    private let uploadPath = "/upload/v1beta/files"
    private let filesPath = "/v1beta/files"

    // URLSession configured with SOCKS5 proxy to bypass corporate firewall
    private let session: URLSession

    private let transcriptionPrompt = """
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

    // MARK: - Initialization

    public init() {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable: true,
            kCFNetworkProxiesSOCKSProxy: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort: 11111
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Transcribe an audio/video file using Gemini API
    /// Automatically extracts audio from video files and routes to inline or File API based on size
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

        // Extract audio from video files to reduce upload size
        let (fileToUpload, needsCleanup) = try await prepareAudioFile(from: audioURL)
        defer {
            if needsCleanup {
                try? FileManager.default.removeItem(at: fileToUpload)
            }
        }

        let fileSize = try FileManager.default.attributesOfItem(atPath: fileToUpload.path)[.size] as? Int ?? 0
        let mimeType = detectMimeType(for: fileToUpload)
        fileRagLog("[Gemini] File ready: \(fileToUpload.lastPathComponent), \(fileSize / 1_048_576)MB, \(mimeType)")

        if fileSize <= maxInlineFileSize {
            return try await transcribeInline(fileURL: fileToUpload, mimeType: mimeType, apiKey: apiKey, model: model)
        } else {
            return try await transcribeViaFileAPI(fileURL: fileToUpload, mimeType: mimeType, apiKey: apiKey, model: model)
        }
    }

    // MARK: - Audio Preparation

    /// Extract the first audio track (microphone) from the .mov container as .m4a
    /// The .mov files have two tracks: track 0 = mic (mono), track 1 = system audio (stereo, usually silent).
    /// Gemini picks the wrong track when given the raw .mov, so we extract the mic track.
    private func prepareAudioFile(from url: URL) async throws -> (URL, Bool) {
        let asset = AVAsset(url: url)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            // No audio tracks — just send the file as-is and let Gemini handle it
            return (url, false)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram_mic_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outputURL)

        // Use AVAssetExportSession with only the first audio track (microphone)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            fileRagLog("[Gemini] Failed to create export session, sending raw file")
            return (url, false)
        }

        exportSession.outputFileType = .m4a
        exportSession.outputURL = outputURL

        // Only include the first audio track (microphone)
        let micTrack = audioTracks[0]
        let timeRange = try await asset.load(.duration)
        let composition = AVMutableComposition()
        if let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: timeRange), of: micTrack, at: .zero)
        }

        let compExport = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)!
        compExport.outputFileType = .m4a
        compExport.outputURL = outputURL

        await compExport.export()

        guard compExport.status == .completed else {
            let errorMsg = compExport.error?.localizedDescription ?? "Unknown"
            fileRagLog("[Gemini] Mic extraction failed: \(errorMsg), sending raw file")
            return (url, false)
        }

        let inputSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let outputSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        fileRagLog("[Gemini] Extracted mic track: \(inputSize / 1024)KB -> \(outputSize / 1024)KB m4a")

        return (outputURL, true)
    }

    // MARK: - Inline Upload (< 20MB)

    private func transcribeInline(
        fileURL: URL,
        mimeType: String,
        apiKey: String,
        model: GeminiModel
    ) async throws -> [TranscriptionSegment] {
        fileRagLog("[Gemini] Using inline upload")
        let audioData = try readAudioFile(url: fileURL)

        let request = try buildInlineRequest(
            audioData: audioData,
            mimeType: mimeType,
            apiKey: apiKey,
            model: model
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse("Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
            logger.error("Gemini API error: \(httpResponse.statusCode) - \(errorBody)")
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        let segments = try parseResponse(data: data)
        fileRagLog("[Gemini] Inline transcription complete: \(segments.count) segments")
        return segments
    }

    // MARK: - File API Upload (> 20MB, up to 2GB)

    private func transcribeViaFileAPI(
        fileURL: URL,
        mimeType: String,
        apiKey: String,
        model: GeminiModel
    ) async throws -> [TranscriptionSegment] {
        fileRagLog("[Gemini] Using File API upload (file too large for inline)")

        // Step 1: Upload file
        let uploaded = try await uploadFile(fileURL: fileURL, mimeType: mimeType, apiKey: apiKey)
        fileRagLog("[Gemini] File uploaded: \(uploaded.name), state: \(uploaded.state)")

        // Step 2: Wait for processing
        let activeFile = try await waitForProcessing(fileName: uploaded.name, apiKey: apiKey)

        // Step 3: Generate transcription
        let segments: [TranscriptionSegment]
        do {
            segments = try await generateFromFileURI(
                fileURI: activeFile.uri,
                mimeType: activeFile.mimeType,
                apiKey: apiKey,
                model: model
            )
        } catch {
            try? await deleteFile(name: activeFile.name, apiKey: apiKey)
            throw error
        }

        // Step 4: Cleanup
        try? await deleteFile(name: activeFile.name, apiKey: apiKey)

        fileRagLog("[Gemini] File API transcription complete: \(segments.count) segments")
        return segments
    }

    /// Resumable upload to Gemini File API
    private func uploadFile(fileURL: URL, mimeType: String, apiKey: String) async throws -> UploadedFile {
        let fileData = try Data(contentsOf: fileURL)

        // Step 1a: Initiate resumable upload
        var initiateRequest = URLRequest(url: URL(string: "\(apiBase)\(uploadPath)")!)
        initiateRequest.httpMethod = "POST"
        initiateRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        initiateRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        initiateRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        initiateRequest.setValue("\(fileData.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        initiateRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        initiateRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initiateRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "file": ["display_name": fileURL.lastPathComponent]
        ])

        let (_, initiateResponse) = try await session.data(for: initiateRequest)

        guard let httpResponse = initiateResponse as? HTTPURLResponse,
              let uploadURLString = httpResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL") ??
                                    httpResponse.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: uploadURLString) else {
            throw GeminiError.invalidResponse("Failed to get upload URL from initiate response")
        }

        // Step 1b: Upload file bytes
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("\(fileData.count)", forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.httpBody = fileData
        uploadRequest.timeoutInterval = 600

        let (uploadData, uploadResponse) = try await session.data(for: uploadRequest)

        guard let uploadHTTP = uploadResponse as? HTTPURLResponse, uploadHTTP.statusCode == 200 else {
            let errorBody = String(data: uploadData, encoding: .utf8) ?? "Unknown"
            throw GeminiError.apiError("File upload failed: \(errorBody)")
        }

        return try parseFileResponse(data: uploadData)
    }

    /// Poll until file state is ACTIVE
    private func waitForProcessing(fileName: String, apiKey: String) async throws -> UploadedFile {
        let fileId = fileName.hasPrefix("files/") ? String(fileName.dropFirst(6)) : fileName
        let getURL = URL(string: "\(apiBase)\(filesPath)/\(fileId)")!

        let startTime = Date()
        let maxWait: TimeInterval = 300

        while true {
            var request = URLRequest(url: getURL)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            let (data, _) = try await session.data(for: request)
            let file = try parseFileMetadata(data: data)

            switch file.state {
            case "ACTIVE":
                return file
            case "FAILED":
                throw GeminiError.fileProcessingFailed
            default:
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > maxWait {
                    throw GeminiError.fileProcessingTimeout
                }
                fileRagLog("[Gemini] File still processing... (\(Int(elapsed))s)")
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Call generateContent with an uploaded file URI
    private func generateFromFileURI(
        fileURI: String,
        mimeType: String,
        apiKey: String,
        model: GeminiModel
    ) async throws -> [TranscriptionSegment] {
        let endpoint = "\(apiBase)\(modelsPath)/\(model.rawValue):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw GeminiError.invalidResponse("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "file_data": [
                                "mime_type": mimeType,
                                "file_uri": fileURI
                            ]
                        ],
                        ["text": transcriptionPrompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 8192
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No details"
            throw GeminiError.apiError("generateContent failed: \(errorBody)")
        }

        return try parseResponse(data: data)
    }

    /// Delete an uploaded file
    private func deleteFile(name: String, apiKey: String) async throws {
        let fileId = name.hasPrefix("files/") ? String(name.dropFirst(6)) : name
        let deleteURL = URL(string: "\(apiBase)\(filesPath)/\(fileId)")!

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        _ = try await session.data(for: request)
        fileRagLog("[Gemini] Deleted uploaded file: \(name)")
    }

    // MARK: - File Response Parsing

    private func parseFileResponse(data: Data) throws -> UploadedFile {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileObj = json["file"] as? [String: Any] else {
            throw GeminiError.invalidResponse("Could not parse upload response")
        }
        return try extractFileInfo(from: fileObj)
    }

    private func parseFileMetadata(data: Data) throws -> UploadedFile {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.invalidResponse("Could not parse file metadata")
        }
        return try extractFileInfo(from: json)
    }

    private func extractFileInfo(from dict: [String: Any]) throws -> UploadedFile {
        guard let name = dict["name"] as? String,
              let uri = dict["uri"] as? String else {
            throw GeminiError.invalidResponse("Missing name or uri in file response")
        }
        return UploadedFile(
            name: name,
            uri: uri,
            mimeType: dict["mimeType"] as? String ?? "application/octet-stream",
            state: dict["state"] as? String ?? "ACTIVE"
        )
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
        case "mov":
            return "audio/mp4" // Engram's .mov files are audio-only containers
        default:
            return "audio/mp4"
        }
    }

    private func buildInlineRequest(
        audioData: Data,
        mimeType: String,
        apiKey: String,
        model: GeminiModel
    ) throws -> URLRequest {
        let endpoint = "\(apiBase)\(modelsPath)/\(model.rawValue):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw GeminiError.invalidResponse("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let base64Audio = audioData.base64EncodedString()

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
                        ["text": transcriptionPrompt]
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
        return parseTranscriptionText(text)
    }

    /// Parse transcription text in format: [MM:SS-MM:SS] Speaker X: "text"
    private func parseTranscriptionText(_ text: String) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []

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

                guard !textContent.isEmpty else { continue }

                segments.append(TranscriptionSegment(
                    start: startTime,
                    end: endTime,
                    text: textContent,
                    speaker: speaker
                ))
            }
        }

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
        let segmentDuration: TimeInterval = 5.0

        let speakerPattern = #"(You|Speaker\s*\d+|Unknown)[:\s]+(.+?)(?=(?:You|Speaker\s*\d+|Unknown)[:\s]|$)"#

        if let regex = try? NSRegularExpression(pattern: speakerPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))

            for match in matches {
                let speakerStr = String(text[Range(match.range(at: 1), in: text)!])
                let content = String(text[Range(match.range(at: 2), in: text)!])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")

                guard !content.isEmpty else { continue }

                segments.append(TranscriptionSegment(
                    start: currentTime,
                    end: currentTime + segmentDuration,
                    text: content,
                    speaker: parseSpeaker(speakerStr)
                ))
                currentTime += segmentDuration
            }
        }

        if segments.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(TranscriptionSegment(
                start: 0,
                end: 30,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: .unknown
            ))
        }

        return segments
    }

    private func parseTimestamp(_ str: String) -> TimeInterval {
        let components = str.split(separator: ":").compactMap { Double($0) }
        switch components.count {
        case 2: return components[0] * 60 + components[1]
        case 3: return components[0] * 3600 + components[1] * 60 + components[2]
        default: return 0
        }
    }

    private func parseSpeaker(_ str: String) -> TranscriptionEngine.Speaker {
        let normalized = str.lowercased().trimmingCharacters(in: .whitespaces)

        if normalized == "you" || normalized == "me" || normalized == "host" {
            return .user
        } else if normalized == "unknown" {
            return .unknown
        } else if normalized.contains("speaker") {
            let digits = normalized.filter { $0.isNumber }
            if let num = Int(digits), num > 0 {
                return .remote(num - 1)
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
