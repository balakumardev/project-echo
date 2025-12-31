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
        constructMenu()
        statusItem?.menu = menu
    }
    
    private func constructMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()
        
        // Header
        let headerItem = NSMenuItem(title: "Project Echo", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())
        
        // Recording control
        if isRecording {
            menu.addItem(withTitle: "⏹ Stop Recording", action: #selector(stopRecording), keyEquivalent: "s")
            menu.addItem(withTitle: "🔖 Mark Moment", action: #selector(insertMarker), keyEquivalent: "m")
        } else {
            menu.addItem(withTitle: "⏺ Start Recording", action: #selector(startRecording), keyEquivalent: "r")
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Library
        menu.addItem(withTitle: "📚 Open Library", action: #selector(openLibrary), keyEquivalent: "l")
        menu.addItem(withTitle: "⚙️ Settings", action: #selector(openSettings), keyEquivalent: ",")
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        menu.addItem(withTitle: "Quit Project Echo", action: #selector(quit), keyEquivalent: "q")
    }
    
    // MARK: - Actions
    
    @objc private func startRecording() {
        delegate?.menuBarDidRequestStartRecording()
        setRecording(true)
    }
    
    @objc private func stopRecording() {
        delegate?.menuBarDidRequestStopRecording()
        setRecording(false)
    }
    
    @objc private func insertMarker() {
        delegate?.menuBarDidRequestInsertMarker()
    }
    
    @objc private func openLibrary() {
        delegate?.menuBarDidRequestOpenLibrary()
    }
    
    @objc private func openSettings() {
        delegate?.menuBarDidRequestOpenSettings()
    }
    
    @objc private func quit() {
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

// MARK: - Delegate Protocol

public protocol MenuBarDelegate: AnyObject {
    func menuBarDidRequestStartRecording()
    func menuBarDidRequestStopRecording()
    func menuBarDidRequestInsertMarker()
    func menuBarDidRequestOpenLibrary()
    func menuBarDidRequestOpenSettings()
}
