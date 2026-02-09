import SwiftUI
import AppKit

/// Menu bar controller for quick recording access
@MainActor
public class MenuBarController: NSObject {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var isRecording = false
    private var isMonitoring = false
    private var monitoredAppName: String?
    private var recordingStartTime: Date?
    private var recordingTimer: Timer?

    // Processing status tracking
    private var activeProcessing: Set<String> = []  // e.g., "transcription", "summary", "actionItems"
    private var queuedTranscriptions: Int = 0
    private var queuedAIGenerations: Int = 0

    public weak var delegate: MenuBarDelegate?

    // MARK: - Initialization

    public override init() {
        super.init()
        setupMenuBar()
        setupProcessingObservers()
    }

    private func setupProcessingObservers() {
        // Listen for processing start notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProcessingDidStart(_:)),
            name: .processingDidStart,
            object: nil
        )

        // Listen for processing complete notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProcessingDidComplete(_:)),
            name: .processingDidComplete,
            object: nil
        )

        // Listen for queue status changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleQueueDidChange(_:)),
            name: .processingQueueDidChange,
            object: nil
        )
    }

    @objc private func handleQueueDidChange(_ notification: Notification) {
        if let transcriptionCount = notification.userInfo?["transcriptionQueue"] as? Int {
            queuedTranscriptions = transcriptionCount
        }
        if let aiCount = notification.userInfo?["aiGenerationQueue"] as? Int {
            queuedAIGenerations = aiCount
        }
        constructMenu()
        updateStatusBarIcon()
    }

    @objc private func handleProcessingDidStart(_ notification: Notification) {
        guard let type = notification.userInfo?["type"] as? String else { return }
        activeProcessing.insert(type)
        constructMenu()
        updateStatusBarIcon()
    }

    @objc private func handleProcessingDidComplete(_ notification: Notification) {
        guard let type = notification.userInfo?["type"] as? String else { return }
        activeProcessing.remove(type)
        constructMenu()
        updateStatusBarIcon()
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Engram")
            button.image?.isTemplate = true
        }

        menu = NSMenu()
        menu?.delegate = self
        constructMenu()
        statusItem?.menu = menu
    }

    private func constructMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()

        // Header with status
        let headerView = createHeaderView()
        let headerItem = NSMenuItem()
        headerItem.view = headerView
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Recording control
        if isRecording {
            let stopItem = createMenuItem(
                title: "Stop Recording",
                icon: "stop.circle.fill",
                action: #selector(stopRecording),
                keyEquivalent: "s"
            )
            menu.addItem(stopItem)

            let markerItem = createMenuItem(
                title: "Mark Moment",
                icon: "bookmark.fill",
                action: #selector(insertMarker),
                keyEquivalent: "m"
            )
            menu.addItem(markerItem)
        } else {
            let startItem = createMenuItem(
                title: "Start Recording",
                icon: "record.circle",
                action: #selector(startRecording),
                keyEquivalent: "r"
            )
            menu.addItem(startItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Navigation
        let libraryItem = createMenuItem(
            title: "Open Library",
            icon: "rectangle.stack.fill",
            action: #selector(openLibrary),
            keyEquivalent: "l"
        )
        menu.addItem(libraryItem)

        menu.addItem(NSMenuItem.separator())

        let aiChatItem = NSMenuItem(
            title: "AI Chat",
            action: #selector(toggleAIChat),
            keyEquivalent: ""
        )
        aiChatItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI Chat")
        aiChatItem.target = self
        aiChatItem.isEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true
        menu.addItem(aiChatItem)

        let settingsItem = createMenuItem(
            title: "Settings",
            icon: "gearshape.fill",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = createMenuItem(
            title: "Quit Engram",
            icon: "power",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        // Attribution footer
        menu.addItem(NSMenuItem.separator())
        let footerView = createFooterView()
        let footerItem = NSMenuItem()
        footerItem.view = footerView
        menu.addItem(footerItem)
    }

    private func createMenuItem(title: String, icon: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = true

        // Create attributed title with icon
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            image.isTemplate = true
            item.image = image
        }

        return item
    }

    private func createHeaderView() -> NSView {
        // Expand height if we have processing status to show
        let hasProcessing = !activeProcessing.isEmpty
        let viewHeight: CGFloat = hasProcessing ? 62 : 44

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: viewHeight))

        // App name label
        let titleLabel = NSTextField(labelWithString: "Engram")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 14, y: viewHeight - 22, width: 120, height: 18)

        // Status label with contextual text
        let statusText: String
        let statusColor: NSColor

        if isRecording {
            statusText = "Recording..."
            statusColor = .systemRed
        } else if isMonitoring, let appName = monitoredAppName {
            statusText = "Monitoring \(appName)"
            statusColor = .systemOrange
        } else if isMonitoring {
            statusText = "Monitoring..."
            statusColor = .systemOrange
        } else {
            statusText = "Ready"
            statusColor = .secondaryLabelColor
        }

        let statusLabel = NSTextField(labelWithString: statusText)
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = statusColor
        statusLabel.frame = NSRect(x: 14, y: viewHeight - 38, width: 160, height: 14)

        // Duration label (when recording)
        if isRecording, let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            let durationLabel = NSTextField(labelWithString: formatDuration(duration))
            durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            durationLabel.textColor = .systemRed
            durationLabel.frame = NSRect(x: 180, y: viewHeight - 30, width: 50, height: 16)
            durationLabel.alignment = .right
            containerView.addSubview(durationLabel)
        }

        containerView.addSubview(titleLabel)
        containerView.addSubview(statusLabel)

        // Processing status (if any active)
        if hasProcessing {
            let processingText = formatProcessingStatus()
            let processingLabel = NSTextField(labelWithString: processingText)
            processingLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            processingLabel.textColor = .systemBlue
            processingLabel.frame = NSRect(x: 14, y: 6, width: 220, height: 14)

            // Add a small spinner/activity indicator icon
            let spinnerIcon = NSTextField(labelWithString: "⟳")
            spinnerIcon.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            spinnerIcon.textColor = .systemBlue
            spinnerIcon.frame = NSRect(x: 14, y: 6, width: 14, height: 14)

            processingLabel.frame = NSRect(x: 26, y: 6, width: 208, height: 14)

            containerView.addSubview(spinnerIcon)
            containerView.addSubview(processingLabel)
        }

        return containerView
    }

    private func formatProcessingStatus() -> String {
        var parts: [String] = []

        if activeProcessing.contains(ProcessingType.transcription.rawValue) {
            parts.append("Transcribing")
        }
        if activeProcessing.contains(ProcessingType.summary.rawValue) {
            parts.append("Summarizing")
        }
        if activeProcessing.contains(ProcessingType.actionItems.rawValue) {
            parts.append("Extracting actions")
        }
        if activeProcessing.contains(ProcessingType.indexing.rawValue) {
            parts.append("Indexing")
        }

        if parts.isEmpty {
            return ""
        } else if parts.count == 1 {
            return "\(parts[0])..."
        } else {
            return parts.joined(separator: ", ") + "..."
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func createFooterView() -> NSView {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))

        // Attribution label with subtle styling
        let attributionLabel = NSTextField(labelWithString: "by Bala Kumar")
        attributionLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        attributionLabel.textColor = .tertiaryLabelColor
        attributionLabel.alignment = .center
        attributionLabel.frame = NSRect(x: 0, y: 4, width: 240, height: 16)

        containerView.addSubview(attributionLabel)

        return containerView
    }
    
    // MARK: - Actions
    
    @objc func startRecording() {
        delegate?.menuBarDidRequestStartRecording()
        setRecording(true)
    }

    @objc func stopRecording() {
        delegate?.menuBarDidRequestStopRecording()
        setRecording(false)
    }

    @objc func insertMarker() {
        delegate?.menuBarDidRequestInsertMarker()
    }

    @objc func openLibrary() {
        delegate?.menuBarDidRequestOpenLibrary()
    }

    @objc func openSettings() {
        delegate?.menuBarDidRequestOpenSettings()
    }

    @objc func toggleAIChat() {
        delegate?.menuBarDidRequestOpenAIChat()
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - State Management

    public func setRecording(_ recording: Bool) {
        isRecording = recording

        if recording {
            recordingStartTime = Date()
            isMonitoring = false  // Stop monitoring when recording starts
            monitoredAppName = nil
            startRecordingTimer()
        } else {
            recordingStartTime = nil
            stopRecordingTimer()
        }

        constructMenu()
        updateStatusBarIcon()
    }

    public func setMonitoring(_ monitoring: Bool, app: String?) {
        isMonitoring = monitoring
        monitoredAppName = app

        constructMenu()
        updateStatusBarIcon()
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }

        let iconName: String
        let iconColor: NSColor?
        let hasProcessing = !activeProcessing.isEmpty

        if isRecording {
            iconName = "waveform.circle.fill"
            iconColor = .systemRed
        } else if hasProcessing {
            // Show processing indicator (gear icon with activity)
            iconName = "gearshape.circle.fill"
            iconColor = .systemBlue
        } else if isMonitoring {
            iconName = "waveform.badge.magnifyingglass"
            iconColor = .systemOrange
        } else {
            iconName = "waveform.circle"
            iconColor = nil
        }

        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Engram") {
            if let color = iconColor {
                // Create a colored version of the icon
                let coloredImage = image.copy() as! NSImage
                coloredImage.lockFocus()
                color.set()
                let imageRect = NSRect(origin: .zero, size: coloredImage.size)
                imageRect.fill(using: .sourceAtop)
                coloredImage.unlockFocus()
                button.image = coloredImage
                button.image?.isTemplate = false
            } else {
                button.image = image
                button.image?.isTemplate = true
            }
        }
    }

    private func startRecordingTimer() {
        // Update less frequently (every 5 seconds) to reduce main thread work
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.constructMenu()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}

// MARK: - Menu Delegate

extension MenuBarController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        // Menu is about to be displayed, ensure items are enabled
        for item in menu.items {
            if item.action != nil && item.target != nil {
                item.isEnabled = true
            }
        }
    }
}

// MARK: - Delegate Protocol

@MainActor
public protocol MenuBarDelegate: AnyObject {
    func menuBarDidRequestStartRecording()
    func menuBarDidRequestStopRecording()
    func menuBarDidRequestInsertMarker()
    func menuBarDidRequestOpenLibrary()
    func menuBarDidRequestOpenSettings()
    func menuBarDidRequestOpenAIChat()
}
