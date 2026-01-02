import SwiftUI
import AppKit
import AudioEngine

/// A popup window that lets users select which window to record
@available(macOS 14.0, *)
public struct WindowSelectorView: View {
    let windows: [ScreenRecorder.CandidateWindow]
    let appName: String
    let onSelect: (ScreenRecorder.CandidateWindow) -> Void
    let onCancel: () -> Void

    @State private var selectedWindowId: UInt32?
    @State private var hoveredWindowId: UInt32?

    public init(
        windows: [ScreenRecorder.CandidateWindow],
        appName: String,
        onSelect: @escaping (ScreenRecorder.CandidateWindow) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.windows = windows
        self.appName = appName
        self.onSelect = onSelect
        self.onCancel = onCancel
        // Pre-select the first window (most likely to be the meeting)
        self._selectedWindowId = State(initialValue: windows.first?.id)
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Select Window to Record")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 4)

            Text("Multiple windows found for \(appName). Select the window you want to record:")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Window grid
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 280, maximum: 320), spacing: 12)
                ], spacing: 12) {
                    ForEach(windows) { window in
                        WindowThumbnailCard(
                            window: window,
                            isSelected: selectedWindowId == window.id,
                            isHovered: hoveredWindowId == window.id
                        )
                        .onTapGesture {
                            selectedWindowId = window.id
                        }
                        .onHover { hovering in
                            hoveredWindowId = hovering ? window.id : nil
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 400)

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Start Recording") {
                    if let selectedId = selectedWindowId,
                       let window = windows.first(where: { $0.id == selectedId }) {
                        onSelect(window)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedWindowId == nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 500, maxWidth: 700, minHeight: 300)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

@available(macOS 14.0, *)
struct WindowThumbnailCard: View {
    let window: ScreenRecorder.CandidateWindow
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            ZStack {
                if let cgImage = window.thumbnail {
                    Image(decorative: cgImage, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 140)
                        .cornerRadius(6)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 140)
                        .cornerRadius(6)
                        .overlay(
                            Image(systemName: "rectangle.dashed")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        )
                }

                // Selection checkmark
                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.green)
                                .background(Circle().fill(.white).padding(2))
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }

            // Window info
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text("\(window.width) x \(window.height)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Color.accentColor : (isHovered ? Color.gray.opacity(0.5) : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Window Controller

@available(macOS 14.0, *)
public class WindowSelectorController: NSObject {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<WindowSelectorView>?

    /// Show the window selector and return the selected window
    /// Returns nil if user cancels
    @MainActor
    public func showSelector(
        windows: [ScreenRecorder.CandidateWindow],
        appName: String
    ) async -> ScreenRecorder.CandidateWindow? {
        return await withCheckedContinuation { continuation in
            let view = WindowSelectorView(
                windows: windows,
                appName: appName,
                onSelect: { [weak self] window in
                    self?.dismissPanel()
                    continuation.resume(returning: window)
                },
                onCancel: { [weak self] in
                    self?.dismissPanel()
                    continuation.resume(returning: nil)
                }
            )

            let hostingView = NSHostingView(rootView: view)
            self.hostingView = hostingView

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "Select Window to Record"
            panel.contentView = hostingView
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = .floating
            panel.center()

            self.panel = panel
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func dismissPanel() {
        panel?.close()
        panel = nil
        hostingView = nil
    }
}
