import Foundation
import AppKit
import os.log

/// Monitors running applications to trigger auto-recording
public actor AppMonitor {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.projectecho.app", category: "AppMonitor")
    private var monitoredApps: Set<String> = []
    private var isMonitoring = false
    private var checkTimer: Task<Void, Never>?
    
    // Default apps to monitor test
    public static let defaultMonitoredApps = [
        "zoom.us",
        "Microsoft Teams", 
        "Google Meet", // Browser based, harder to detect by process name usually
        "Slack",
        "Discord",
        "Webex",
        "Skype"
    ]
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Control
    
    /// Start monitoring for specific apps
    public func startMonitoring(apps: [String]) {
        self.monitoredApps = Set(apps)
        
        guard !isMonitoring else {
            logger.info("Updated monitored apps list: \(apps)")
            return
        }
        
        isMonitoring = true
        logger.info("Started app monitoring for: \(apps)")
        
        // Start polling loop
        // KVO on NSWorkspace.runningApplications is better, but polling is simpler for this actor
        // Actually, we can use NSWorkspace notifications if we were on the main thread.
        // Since we are an actor, let's use a polling task or notification observer bridge.
    }
    
    public func stopMonitoring() {
        isMonitoring = false
        checkTimer?.cancel()
        checkTimer = nil
        logger.info("Stopped app monitoring")
    }
    
    /// Check if any monitored app is currently active (frontmost)
    /// Returns: The name of the detected app, or nil
    public func checkForActiveMeetingApp() -> String? {
        // This must be main thread safe, NSWorkspace is mostly main thread.
        // But runningApplications is thread safe.
        
        let ws = NSWorkspace.shared
        let runningApps = ws.runningApplications
        
        for app in runningApps {
            guard let name = app.localizedName else { continue }
            
            // Check if app is in our monitored list
            // We do a partial match or exact match
            if monitoredApps.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                // Determine if it's "active" (e.g. not hidden, maybe frontmost?)
                // For auto-recording, we usually care if it's running and maybe active.
                // But preventing false positives (just open in background) is hard without more logic.
                // For now, let's return it if it is running.
                
                // Optimization: Maybe only if it has an active audio stream? 
                // We can't easily check that without CoreAudio hacks.
                
                return name
            }
        }
        
        return nil
    }
}
