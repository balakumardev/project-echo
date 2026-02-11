import Foundation
import SwiftUI
import Database
import Intelligence
import Combine

// MARK: - Library View Model

@MainActor
@available(macOS 14.0, *)
class LibraryViewModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var isLoading = false

    private var database: DatabaseManager?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // DatabaseManager will be initialized lazily in async context
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        // Observe recording saved notifications
        NotificationCenter.default.publisher(for: .recordingDidSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadRecordings()
                }
            }
            .store(in: &cancellables)

        // Observe recording deleted notifications
        NotificationCenter.default.publisher(for: .recordingDidDelete)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadRecordings()
                }
            }
            .store(in: &cancellables)

        // Observe recording content updates (transcript, summary, action items)
        // This updates the list to reflect new hasTranscript status or other metadata changes
        NotificationCenter.default.publisher(for: .recordingContentDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadRecordings()
                }
            }
            .store(in: &cancellables)
    }

    private func getDatabase() async throws -> DatabaseManager {
        if let db = database {
            return db
        }
        let db = try await DatabaseManager.shared()
        database = db
        return db
    }

    func loadRecordings() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let db = try await getDatabase()
            recordings = try await db.getAllRecordings()
        } catch {
            fileDebugLog("Failed to load recordings: \(error)")
        }
    }

    func search(query: String) async {
        guard !query.isEmpty else {
            await loadRecordings()
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let db = try await getDatabase()
            recordings = try await db.searchTranscripts(query: query)
        } catch {
            fileDebugLog("Search failed: \(error)")
        }
    }

    func deleteRecording(_ recording: Recording) async {
        do {
            let db = try await getDatabase()
            try await db.deleteRecording(id: recording.id)
            // Delete file
            try? FileManager.default.removeItem(at: recording.fileURL)
            await loadRecordings()
        } catch {
            fileDebugLog("Failed to delete recording: \(error)")
        }
    }

    func refresh() async {
        await loadRecordings()
    }

    func getTranscript(for recording: Recording) async -> Transcript? {
        guard let db = try? await getDatabase() else { return nil }
        return try? await db.getTranscript(forRecording: recording.id)
    }

    func toggleFavorite(for recording: Recording) async {
        do {
            let db = try await getDatabase()
            _ = try await db.toggleFavorite(id: recording.id)
            await loadRecordings()
        } catch {
            fileDebugLog("Failed to toggle favorite: \(error)")
        }
    }
}
