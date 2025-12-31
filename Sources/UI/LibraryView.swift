import SwiftUI

/// Main library view showing all recordings
@available(macOS 14.0, *)
public struct LibraryView: View {
    
    @StateObject private var viewModel = LibraryViewModel()
    @State private var selectedRecording: Recording?
    @State private var searchText = ""
    @State private var showingTranscript = false
    
    public init() {}
    
    public var body: some View {
        NavigationSplitView {
            // Sidebar - Recording List
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search recordings...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onChange(of: searchText) { _, newValue in
                            Task {
                                await viewModel.search(query: newValue)
                            }
                        }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
                
                // Recording list
                List(selection: $selectedRecording) {
                    ForEach(viewModel.recordings) { recording in
                        RecordingRow(recording: recording)
                            .tag(recording)
                            .contextMenu {
                                Button("Export Audio...") {
                                    exportRecording(recording)
                                }
                                Button("Export Transcript...") {
                                    exportTranscript(recording)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    Task {
                                        await viewModel.deleteRecording(recording)
                                    }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 280)
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            await viewModel.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        } detail: {
            // Detail view
            if let recording = selectedRecording {
                RecordingDetailView(recording: recording)
            } else {
                Text("Select a recording")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await viewModel.loadRecordings()
        }
        .frame(minWidth: 800, minHeight: 500)
    }
    
    private func exportRecording(_ recording: Recording) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.audio, .movie]
        let ext = recording.fileURL.pathExtension
        panel.nameFieldStringValue = recording.title + "." + (ext.isEmpty ? "m4a" : ext)
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? FileManager.default.copyItem(at: recording.fileURL, to: url)
            }
        }
    }
    
    private func exportTranscript(_ recording: Recording) {
        Task {
            if let transcript = await viewModel.getTranscript(for: recording) {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.nameFieldStringValue = recording.title + ".txt"
                
                panel.begin { response in
                    if response == .OK, let url = panel.url {
                        try? transcript.fullText.write(to: url, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
    }
}

// MARK: - Recording Row

struct RecordingRow: View {
    let recording: Recording
    
    var body: some View {
        HStack(spacing: 12) {
            // App icon
            Image(systemName: appIcon(for: recording.appName))
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.headline)
                
                HStack {
                    Text(recording.date, style: .date)
                    Text("•")
                    Text(formatDuration(recording.duration))
                    
                    if recording.hasTranscript {
                        Text("•")
                        Image(systemName: "text.quote")
                            .foregroundColor(.green)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(formatFileSize(recording.fileSize))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private func appIcon(for appName: String?) -> String {
        switch appName?.lowercased() {
        case "zoom": return "video.fill"
        case "microsoft teams": return "person.2.fill"
        case "google meet": return "person.3.fill"
        default: return "waveform"
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Recording Detail View

@available(macOS 14.0, *)
struct RecordingDetailView: View {
    let recording: Recording
    @StateObject private var viewModel = RecordingDetailViewModel()
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(recording.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    HStack {
                        Label(recording.date.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                        Label(formatDuration(recording.duration), systemImage: "clock")
                        if let app = recording.appName {
                            Label(app, systemImage: "app.fill")
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Audio player
                if let player = viewModel.audioPlayer {
                    AudioPlayerView(player: player)
                }
                
                Divider()
                
                // Transcript
                if viewModel.isLoadingTranscript {
                    ProgressView("Loading transcript...")
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let transcript = viewModel.transcript {
                    TranscriptView(transcript: transcript, segments: viewModel.segments)
                } else if recording.hasTranscript {
                    Button("Load Transcript") {
                        Task {
                            await viewModel.loadTranscript(for: recording)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("No transcript available")
                            .foregroundColor(.secondary)
                        
                        Button("Generate Transcript") {
                            Task {
                                await viewModel.generateTranscript(for: recording)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(24)
        }
        .task {
            let vm = viewModel
            await vm.setupAudioPlayer(for: recording)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: duration) ?? ""
    }
}

// MARK: - Audio Player View

struct AudioPlayerView: View {
    let player: AVAudioPlayer
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var timer: Timer?
    
    var body: some View {
        VStack(spacing: 12) {
            // Progress bar
            Slider(value: $currentTime, in: 0...player.duration) { editing in
                if !editing {
                    player.currentTime = currentTime
                }
            }
            
            HStack {
                Text(formatTime(currentTime))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Controls
                Button {
                    player.currentTime = max(0, player.currentTime - 10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                }
                
                Button {
                    player.currentTime = min(player.duration, player.currentTime + 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
                
                Spacer()
                
                Text(formatTime(player.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
        .onAppear {
            startTimer()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            Task { @MainActor in
                currentTime = player.currentTime
                if player.currentTime >= player.duration {
                    isPlaying = false
                }
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Transcript View

struct TranscriptView: View {
    let transcript: Transcript
    let segments: [TranscriptSegment]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcript")
                .font(.title2)
                .fontWeight(.semibold)
            
            if segments.isEmpty {
                Text(transcript.fullText)
                    .textSelection(.enabled)
            } else {
                ForEach(segments, id: \.id) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        // Speaker avatar
                        Text(segment.speaker.prefix(1))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(width: 32, height: 32)
                            .background(speakerColor(for: segment.speaker))
                            .foregroundColor(.white)
                            .cornerRadius(16)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(segment.speaker)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                
                                Text(formatTimestamp(segment.startTime))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(segment.text)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }
            }
        }
    }
    
    private func speakerColor(for speaker: String) -> Color {
        // Simple hash-based color
        let hash = speaker.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.8)
    }
    
    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Supporting Types

import Database
import AVFoundation

// Type aliases are defined in ViewModels.swift
