import SwiftUI
import AppKit

/// Menu bar controller for quick recording access
@MainActor
public class MenuBarController: NSObject {
    
    // MARK: - Properties
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var isRecording = false
    
    public weak var delegate: MenuBarDelegate?
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
        setupMenuBar()
    }
    
    // MARK: - Setup
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Project Echo")
            button.image?.isTemplate = true
        }

        menu = NSMenu()
        menu?.delegate = self
        constructMenu()
        statusItem?.menu = menu
    }
    
    private func constructMenu() {
        guard let menu = menu else {
            print("DEBUG: menu is nil!")
            return
        }
        menu.removeAllItems()

        print("DEBUG: Constructing menu, isRecording=\(isRecording)")

        // Header
        let headerItem = NSMenuItem(title: "Project Echo", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Recording control
        if isRecording {
            let stopItem = NSMenuItem(title: "⏹ Stop Recording", action: #selector(stopRecording), keyEquivalent: "s")
            stopItem.target = self
            stopItem.isEnabled = true
            menu.addItem(stopItem)
            print("DEBUG: Added Stop Recording - target=\(String(describing: stopItem.target)), enabled=\(stopItem.isEnabled)")

            let markerItem = NSMenuItem(title: "🔖 Mark Moment", action: #selector(insertMarker), keyEquivalent: "m")
            markerItem.target = self
            markerItem.isEnabled = true
            menu.addItem(markerItem)
        } else {
            let startItem = NSMenuItem(title: "⏺ Start Recording", action: #selector(startRecording), keyEquivalent: "r")
            startItem.target = self
            startItem.isEnabled = true
            menu.addItem(startItem)
            print("DEBUG: Added Start Recording - target=\(String(describing: startItem.target)), enabled=\(startItem.isEnabled)")
        }

        menu.addItem(NSMenuItem.separator())

        // Library
        let libraryItem = NSMenuItem(title: "📚 Open Library", action: #selector(openLibrary), keyEquivalent: "l")
        libraryItem.target = self
        libraryItem.isEnabled = true
        menu.addItem(libraryItem)
        print("DEBUG: Added Open Library - target=\(String(describing: libraryItem.target)), enabled=\(libraryItem.isEnabled)")

        let settingsItem = NSMenuItem(title: "⚙️ Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Project Echo", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        print("DEBUG: Menu constructed with \(menu.items.count) items")
    }
    
    // MARK: - Actions
    
    @objc func startRecording() {
        print("DEBUG: startRecording called")
        delegate?.menuBarDidRequestStartRecording()
        setRecording(true)
    }

    @objc func stopRecording() {
        print("DEBUG: stopRecording called")
        delegate?.menuBarDidRequestStopRecording()
        setRecording(false)
    }

    @objc func insertMarker() {
        print("DEBUG: insertMarker called")
        delegate?.menuBarDidRequestInsertMarker()
    }

    @objc func openLibrary() {
        print("DEBUG: openLibrary called")
        delegate?.menuBarDidRequestOpenLibrary()
    }

    @objc func openSettings() {
        print("DEBUG: openSettings called")
        delegate?.menuBarDidRequestOpenSettings()
    }

    @objc func quit() {
        print("DEBUG: quit called")
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - State Management

    public func setRecording(_ recording: Bool) {
        isRecording = recording
        constructMenu()

        // Update status bar icon
        if let button = statusItem?.button {
            let iconName = recording ? "waveform.circle.fill" : "waveform.circle"
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Project Echo")
            button.image?.isTemplate = true
        }
    }
}

// MARK: - Menu Delegate

extension MenuBarController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        print("DEBUG: menuNeedsUpdate called with \(menu.items.count) items")
        // Menu is about to be displayed, ensure items are enabled
        for (index, item) in menu.items.enumerated() {
            print("DEBUG: Item \(index): '\(item.title)' - enabled before: \(item.isEnabled), target: \(String(describing: item.target))")
            if item.action != nil && item.target != nil {
                item.isEnabled = true
            }
            print("DEBUG: Item \(index): '\(item.title)' - enabled after: \(item.isEnabled)")
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
}
