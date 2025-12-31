import SwiftUI

/// A glassmorphism-styled card container
@available(macOS 14.0, *)
public struct GlassCard<Content: View>: View {
    let content: Content
    let cornerRadius: CGFloat
    let padding: CGFloat
    let showBorder: Bool

    public init(
        cornerRadius: CGFloat = Theme.Radius.lg,
        padding: CGFloat = Theme.Spacing.lg,
        showBorder: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.showBorder = showBorder
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    // Base layer
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Theme.Colors.surface.opacity(0.85))

                    // Glass effect
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial.opacity(0.3))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        showBorder ? Theme.Colors.border.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
            )
            .themeShadow(Theme.Shadows.md)
    }
}

/// A surface card without glass effect
@available(macOS 14.0, *)
public struct SurfaceCard<Content: View>: View {
    let content: Content
    let cornerRadius: CGFloat
    let padding: CGFloat
    let showBorder: Bool

    public init(
        cornerRadius: CGFloat = Theme.Radius.lg,
        padding: CGFloat = Theme.Spacing.lg,
        showBorder: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.showBorder = showBorder
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Theme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        showBorder ? Theme.Colors.borderSubtle : .clear,
                        lineWidth: 1
                    )
            )
    }
}

/// Elevated card with subtle shadow
@available(macOS 14.0, *)
public struct ElevatedCard<Content: View>: View {
    let content: Content
    let cornerRadius: CGFloat
    let padding: CGFloat

    public init(
        cornerRadius: CGFloat = Theme.Radius.lg,
        padding: CGFloat = Theme.Spacing.lg,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.padding = padding
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Theme.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
            .themeShadow(Theme.Shadows.lg)
    }
}

