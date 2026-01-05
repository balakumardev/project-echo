import SwiftUI

// MARK: - Design System

/// Engram Design System
/// Copyright © 2024-2026 Bala Kumar. All rights reserved.
/// https://balakumar.dev
/// A modern dark theme with vibrant accents
@available(macOS 14.0, *)
public enum Theme {

    // MARK: - Colors

    public enum Colors {
        // Background hierarchy
        public static let background = Color(hex: "0D0D0F")
        public static let surface = Color(hex: "16161A")
        public static let surfaceHover = Color(hex: "1C1C21")
        public static let surfaceElevated = Color(hex: "1E1E24")
        public static let border = Color(hex: "2A2A30")
        public static let borderSubtle = Color(hex: "222228")

        // Accent colors
        public static let primary = Color(hex: "7C3AED")
        public static let primaryHover = Color(hex: "8B5CF6")
        public static let primaryMuted = Color(hex: "7C3AED").opacity(0.15)
        public static let secondary = Color(hex: "06B6D4")
        public static let secondaryMuted = Color(hex: "06B6D4").opacity(0.15)

        // Semantic colors
        public static let success = Color(hex: "10B981")
        public static let successMuted = Color(hex: "10B981").opacity(0.15)
        public static let warning = Color(hex: "F59E0B")
        public static let warningMuted = Color(hex: "F59E0B").opacity(0.15)
        public static let error = Color(hex: "EF4444")
        public static let errorMuted = Color(hex: "EF4444").opacity(0.15)
        public static let recording = Color(hex: "EF4444")

        // Text hierarchy
        public static let textPrimary = Color(hex: "F4F4F5")
        public static let textSecondary = Color(hex: "A1A1AA")
        public static let textMuted = Color(hex: "71717A")
        public static let textInverse = Color(hex: "0D0D0F")

        // Waveform colors
        public static let waveformPlayed = Color(hex: "7C3AED")
        public static let waveformUnplayed = Color(hex: "3F3F46")
        public static let waveformBackground = Color(hex: "18181B")

        // App-specific gradients
        public static let zoomGradient = LinearGradient(
            colors: [Color(hex: "2D8CFF"), Color(hex: "0B5CFF")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let teamsGradient = LinearGradient(
            colors: [Color(hex: "5B5FC7"), Color(hex: "4B4EB8")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let meetGradient = LinearGradient(
            colors: [Color(hex: "00AC47"), Color(hex: "00832D")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let slackGradient = LinearGradient(
            colors: [Color(hex: "E01E5A"), Color(hex: "36C5F0")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let discordGradient = LinearGradient(
            colors: [Color(hex: "5865F2"), Color(hex: "4752C4")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        public static let defaultAppGradient = LinearGradient(
            colors: [Color(hex: "7C3AED"), Color(hex: "5B21B6")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // Speaker gradient colors (10 distinct colors for speakers)
        public static let speakerColors: [Color] = [
            Color(hex: "7C3AED"), // Purple
            Color(hex: "06B6D4"), // Cyan
            Color(hex: "F59E0B"), // Amber
            Color(hex: "10B981"), // Emerald
            Color(hex: "EC4899"), // Pink
            Color(hex: "3B82F6"), // Blue
            Color(hex: "EF4444"), // Red
            Color(hex: "8B5CF6"), // Violet
            Color(hex: "14B8A6"), // Teal
            Color(hex: "F97316"), // Orange
        ]

        public static func speakerColor(for name: String) -> Color {
            // Give "You" a distinct, consistent color
            if name == "You" {
                return Color(hex: "3B82F6")  // Blue - stands out as the user
            }
            let hash = abs(name.hashValue)
            return speakerColors[hash % speakerColors.count]
        }

        public static func speakerGradient(for name: String) -> LinearGradient {
            let baseColor = speakerColor(for: name)
            return LinearGradient(
                colors: [baseColor, baseColor.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        public static func appGradient(for appName: String?) -> LinearGradient {
            guard let app = appName?.lowercased() else { return defaultAppGradient }

            if app.contains("zoom") { return zoomGradient }
            if app.contains("teams") { return teamsGradient }
            if app.contains("meet") || app.contains("chrome") { return meetGradient }
            if app.contains("slack") { return slackGradient }
            if app.contains("discord") { return discordGradient }
            return defaultAppGradient
        }
    }

    // MARK: - Typography

    public enum Typography {
        // Display
        public static let largeTitle = Font.system(size: 28, weight: .bold, design: .default)
        public static let title1 = Font.system(size: 24, weight: .semibold, design: .default)
        public static let title2 = Font.system(size: 20, weight: .semibold, design: .default)
        public static let title3 = Font.system(size: 18, weight: .semibold, design: .default)

        // Body
        public static let headline = Font.system(size: 15, weight: .semibold, design: .default)
        public static let body = Font.system(size: 14, weight: .regular, design: .default)
        public static let bodyMedium = Font.system(size: 14, weight: .medium, design: .default)
        public static let callout = Font.system(size: 13, weight: .regular, design: .default)

        // Supporting
        public static let subheadline = Font.system(size: 12, weight: .regular, design: .default)
        public static let footnote = Font.system(size: 11, weight: .regular, design: .default)
        public static let caption = Font.system(size: 10, weight: .regular, design: .default)

        // Monospace
        public static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
        public static let monoBody = Font.system(size: 13, weight: .regular, design: .monospaced)
    }

    // MARK: - Spacing

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let xxxl: CGFloat = 48
    }

    // MARK: - Radius

    public enum Radius {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let full: CGFloat = 9999
    }

    // MARK: - Shadows

    public enum Shadows {
        public static let sm = ShadowStyle(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        public static let md = ShadowStyle(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        public static let lg = ShadowStyle(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
        public static let glow = ShadowStyle(color: Colors.primary.opacity(0.4), radius: 12, x: 0, y: 0)
    }

    // MARK: - Animation

    public enum Animation {
        public static let fast = SwiftUI.Animation.easeOut(duration: 0.15)
        public static let normal = SwiftUI.Animation.easeInOut(duration: 0.25)
        public static let slow = SwiftUI.Animation.easeInOut(duration: 0.4)
        public static let spring = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.7)
        public static let bouncy = SwiftUI.Animation.spring(response: 0.4, dampingFraction: 0.6)
    }
}

// MARK: - Shadow Style

public struct ShadowStyle: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - View Extensions

@available(macOS 14.0, *)
extension View {

    /// Apply theme shadow
    public func themeShadow(_ style: ShadowStyle) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    /// Glass card background
    public func glassBackground(
        cornerRadius: CGFloat = Theme.Radius.lg,
        border: Bool = true
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(Theme.Colors.surface.opacity(0.8))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(border ? Theme.Colors.border : .clear, lineWidth: 1)
            )
    }

    /// Surface card background
    public func surfaceBackground(
        cornerRadius: CGFloat = Theme.Radius.lg,
        border: Bool = true
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(border ? Theme.Colors.borderSubtle : .clear, lineWidth: 1)
            )
    }

    /// Hover effect modifier
    public func hoverEffect(
        cornerRadius: CGFloat = Theme.Radius.md,
        scale: CGFloat = 1.0
    ) -> some View {
        self.modifier(HoverEffectModifier(cornerRadius: cornerRadius, scale: scale))
    }
}

// MARK: - Hover Effect Modifier

@available(macOS 14.0, *)
struct HoverEffectModifier: ViewModifier {
    let cornerRadius: CGFloat
    let scale: CGFloat

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isHovered ? Theme.Colors.surfaceHover : .clear)
            )
            .scaleEffect(isHovered ? scale : 1.0)
            .animation(Theme.Animation.fast, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Icon Helpers

@available(macOS 14.0, *)
public enum AppIcons {
    public static func icon(for appName: String?) -> String {
        guard let app = appName?.lowercased() else { return "waveform" }

        if app.contains("zoom") { return "video.fill" }
        if app.contains("teams") { return "person.2.fill" }
        if app.contains("meet") || app.contains("chrome") { return "video.badge.checkmark" }
        if app.contains("slack") { return "bubble.left.and.bubble.right.fill" }
        if app.contains("discord") { return "headphones" }
        if app.contains("facetime") { return "video.fill" }
        if app.contains("webex") { return "video.circle.fill" }
        return "waveform"
    }
}
