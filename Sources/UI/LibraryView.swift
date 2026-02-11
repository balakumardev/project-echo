import SwiftUI
import AppKit
import AVFoundation
import AVKit
import Database
import Intelligence

// MARK: - Recording Video URL Helper

extension Recording {
    /// Derive the video file URL from the audio recording URL
    /// Audio: Echo_2026-01-02T10-30-00-0800.mov
    /// Video: Echo_2026-01-02T10-30-00-0800_video.mov
    var videoURL: URL? {
        let audioFileName = fileURL.deletingPathExtension().lastPathComponent
        let videoFileName = audioFileName + "_video.mov"
        let videoURL = fileURL.deletingLastPathComponent().appendingPathComponent(videoFileName)

        // Check if video file exists
        if FileManager.default.fileExists(atPath: videoURL.path) {
            return videoURL
        }
        return nil
    }

    var hasVideo: Bool {
        videoURL != nil
    }
}

// MARK: - Main Library View

/// Main library view showing all recordings with modern dark theme
@available(macOS 14.0, *)
public struct LibraryView: View {

    @StateObject private var viewModel = LibraryViewModel()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var aiService = AIServiceObservable()
    @State private var selectedRecording: Recording?
    @State private var searchText = ""
    @State private var selectedFilter: RecordingFilter = .all
    @State private var selectedSort: RecordingSort = .dateDesc
    @State private var customStartDate: Date? = nil
    @State private var customEndDate: Date? = nil
    @State private var pendingSeekTimestamp: TimeInterval? = nil
    @AppStorage("showChatPanel_v2") private var showChatPanel = false
    @AppStorage("aiEnabled") private var aiEnabled = true

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            SidebarView(
                viewModel: viewModel,
                selectedRecording: $selectedRecording,
                searchText: $searchText,
                selectedFilter: $selectedFilter,
                selectedSort: $selectedSort,
                customStartDate: $customStartDate,
                customEndDate: $customEndDate,
                onAISearch: aiEnabled ? handleAISearch : nil
            )
            .frame(width: 380)

            // Divider
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 1)

            // Detail view
            DetailView(recording: selectedRecording, seekToTimestamp: $pendingSeekTimestamp)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Chat panel
            if showChatPanel && aiEnabled {
                Rectangle()
                    .fill(Theme.Colors.border)
                    .frame(width: 1)

                UnifiedChatPanel(
                    chatViewModel: chatViewModel,
                    selectedRecording: selectedRecording,
                    recordings: viewModel.recordings,
                    onCitationTap: handleCitationTap
                )
                .frame(width: 350)
                .transition(.move(edge: .trailing))
            }
        }
        .environmentObject(aiService)
        .animation(.easeInOut(duration: 0.2), value: showChatPanel)
        .background(Theme.Colors.background)
        .task {
            await viewModel.loadRecordings()
        }
        .onChange(of: viewModel.recordings) { _, newRecordings in
            // Sync selectedRecording when recordings list updates (e.g., after refresh)
            // This ensures the selected recording has the latest hasTranscript flag
            if let selected = selectedRecording,
               let updated = newRecordings.first(where: { $0.id == selected.id }) {
                selectedRecording = updated
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRecordingAtTimestamp)) { notification in
            guard let userInfo = notification.userInfo,
                  let recordingId = userInfo["recordingId"] as? Int64,
                  let timestamp = userInfo["timestamp"] as? TimeInterval else { return }

            // Find and select the recording
            if let recording = viewModel.recordings.first(where: { $0.id == recordingId }) {
                selectedRecording = recording
                pendingSeekTimestamp = timestamp

                // Bring library window to front
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: - AI Search

    private func handleAISearch(_ query: String) {
        // AI search from the sidebar search field should always search across all recordings
        chatViewModel.recordingFilter = nil
        showChatPanel = true
        if !query.isEmpty {
            chatViewModel.inputText = query
            Task {
                await chatViewModel.sendMessage()
            }
        }
    }

    // MARK: - Citation Tap

    private func handleCitationTap(_ citation: Citation) {
        // Navigate to the cited recording at the specific timestamp
        if let recording = viewModel.recordings.first(where: { $0.id == citation.recordingId }) {
            selectedRecording = recording
            pendingSeekTimestamp = citation.timestamp
        }
    }
}
