import SwiftUI
import AppKit
import AVFoundation
import AVKit
import Database

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
    @State private var selectedRecording: Recording?
    @State private var searchText = ""
    @State private var selectedFilter: RecordingFilter = .all
    @State private var selectedSort: RecordingSort = .dateDesc

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            SidebarView(
                viewModel: viewModel,
                selectedRecording: $selectedRecording,
                searchText: $searchText,
                selectedFilter: $selectedFilter,
                selectedSort: $selectedSort
            )
            .frame(width: 340)

            // Divider
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(width: 1)

            // Detail view
            DetailView(recording: selectedRecording)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        .frame(minWidth: 900, minHeight: 600)
    }
}
