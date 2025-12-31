import AppKit

class SimpleMenuApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.title = "🎙️"
        }
        
        // Create menu
        let menu = NSMenu()
        
        let item1 = NSMenuItem(title: "Test Item 1", action: #selector(testAction), keyEquivalent: "")
        item1.target = self
        menu.addItem(item1)
        
        let item2 = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(item2)
        
        statusItem?.menu = menu
        
        print("Menu created with \(menu.items.count) items")
        for (index, item) in menu.items.enumerated() {
            print("Item \(index): '\(item.title)' - enabled: \(item.isEnabled), target: \(String(describing: item.target)), action: \(String(describing: item.action))")
        }
    }
    
    @objc func testAction() {
        print("Test action called!")
        let alert = NSAlert()
        alert.messageText = "It works!"
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = SimpleMenuApp()
app.delegate = delegate
app.run()

