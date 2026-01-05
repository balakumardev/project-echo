import Foundation

/// Shared formatters for duration, time, and file size
public enum Formatters {
    /// Format duration as HH:MM:SS or MM:SS
    public static func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Format time as HH:MM:SS or M:SS (for player displays)
    public static func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite else { return "0:00" }
        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Format timestamp as MM:SS
    public static func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Format file size using ByteCountFormatter
    public static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Format duration using DateComponentsFormatter (abbreviated)
    public static func formatDurationAbbreviated(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: duration) ?? ""
    }

    // MARK: - Relative Date Formatting

    /// Format date as relative string (Today, Yesterday, X days ago, etc.)
    /// - Parameters:
    ///   - date: The date to format
    ///   - expanded: If true, includes time for recent dates (used on hover)
    /// - Returns: Formatted relative date string
    public static func formatRelativeDate(_ date: Date, expanded: Bool = false) -> String {
        let calendar = Calendar.current
        let now = Date()

        // Time formatter for expanded mode
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeString = timeFormatter.string(from: date)

        // Check if same day (today)
        if calendar.isDateInToday(date) {
            return expanded ? "Today at \(timeString)" : "Today"
        }

        // Check if yesterday
        if calendar.isDateInYesterday(date) {
            return expanded ? "Yesterday at \(timeString)" : "Yesterday"
        }

        // Calculate days difference
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.day, .year], from: startOfDate, to: startOfToday)
        let daysAgo = components.day ?? 0

        // 2-6 days ago
        if daysAgo >= 2 && daysAgo <= 6 {
            return "\(daysAgo) days ago"
        }

        // Last week (7-13 days)
        if daysAgo >= 7 && daysAgo <= 13 {
            return "Last week"
        }

        // Older dates - show month and day
        let dateFormatter = DateFormatter()

        // Check if different year
        let dateYear = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: now)

        if dateYear != currentYear {
            // Different year - include year
            dateFormatter.dateFormat = expanded ? "MMM d, yyyy 'at' h:mm a" : "MMM d, yyyy"
        } else {
            // Same year - just month and day
            dateFormatter.dateFormat = expanded ? "MMM d 'at' h:mm a" : "MMM d"
        }

        return dateFormatter.string(from: date)
    }
}
