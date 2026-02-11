import Foundation
import SwiftUI
import Combine

// MARK: - Processing Status Types

/// Types of background processing that can occur
public enum ProcessingType: String {
    case transcription = "transcription"
    case summary = "summary"
    case actionItems = "actionItems"
    case indexing = "indexing"

    public var displayName: String {
        switch self {
        case .transcription: return "Transcribing"
        case .summary: return "Summarizing"
        case .actionItems: return "Extracting actions"
        case .indexing: return "Indexing"
        }
    }
}

// MARK: - Processing Tracker (Shared State)

/// Singleton that tracks which recordings have active processing.
/// Observed by both sidebar rows and detail views for a single source of truth.
@MainActor
@available(macOS 14.0, *)
public class ProcessingTracker: ObservableObject {
    public static let shared = ProcessingTracker()

    public struct ProcessingEntry: Hashable {
        public let recordingId: Int64
        public let type: ProcessingType
    }

    @Published public private(set) var activeProcessing: Set<ProcessingEntry> = []

    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: .processingDidStart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let recordingId = notification.userInfo?["recordingId"] as? Int64,
                      let typeStr = notification.userInfo?["type"] as? String,
                      let type = ProcessingType(rawValue: typeStr) else { return }
                self.activeProcessing.insert(ProcessingEntry(recordingId: recordingId, type: type))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .processingDidComplete)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let recordingId = notification.userInfo?["recordingId"] as? Int64,
                      let typeStr = notification.userInfo?["type"] as? String,
                      let type = ProcessingType(rawValue: typeStr) else { return }
                self.activeProcessing.remove(ProcessingEntry(recordingId: recordingId, type: type))
            }
            .store(in: &cancellables)
    }

    public func isProcessing(_ recordingId: Int64) -> Bool {
        activeProcessing.contains { $0.recordingId == recordingId }
    }

    public func isProcessing(_ recordingId: Int64, type: ProcessingType) -> Bool {
        activeProcessing.contains(ProcessingEntry(recordingId: recordingId, type: type))
    }

    public func processingTypes(for recordingId: Int64) -> Set<ProcessingType> {
        Set(activeProcessing.filter { $0.recordingId == recordingId }.map { $0.type })
    }
}
