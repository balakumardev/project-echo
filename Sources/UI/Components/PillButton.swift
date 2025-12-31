import SwiftUI

/// Button style variants
public enum PillButtonStyle {
    case primary
    case secondary
    case ghost
    case danger
}

/// A pill-shaped button with various styles
@available(macOS 14.0, *)
public struct PillButton: View {
    let title: String
    let icon: String?
    let style: PillButtonStyle
    let isCompact: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    public init(
        _ title: String,
        icon: String? = nil,
        style: PillButtonStyle = .primary,
        isCompact: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.isCompact = isCompact
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: isCompact ? 11 : 13, weight: .medium))
                }
                Text(title)
                    .font(isCompact ? Theme.Typography.footnote : Theme.Typography.callout)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, isCompact ? Theme.Spacing.md : Theme.Spacing.lg)
            .padding(.vertical, isCompact ? Theme.Spacing.xs : Theme.Spacing.sm)
            .foregroundColor(foregroundColor)
            .background(background)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(Theme.Animation.fast, value: isPressed)
            .animation(Theme.Animation.fast, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .pressEvents {
            isPressed = true
        } onRelease: {
            isPressed = false
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return Theme.Colors.textInverse
        case .secondary:
            return Theme.Colors.primary
        case .ghost:
            return isHovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
        case .danger:
            return Theme.Colors.textInverse
        }
    }

    private var background: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(isHovered ? Theme.Colors.primaryHover : Theme.Colors.primary)
        case .secondary:
            return AnyShapeStyle(isHovered ? Theme.Colors.primaryMuted : Theme.Colors.primaryMuted.opacity(0.5))
        case .ghost:
            return AnyShapeStyle(isHovered ? Theme.Colors.surfaceHover : Color.clear)
        case .danger:
            return AnyShapeStyle(isHovered ? Theme.Colors.error.opacity(0.9) : Theme.Colors.error)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return .clear
        case .secondary:
            return Theme.Colors.primary.opacity(0.3)
        case .ghost:
            return isHovered ? Theme.Colors.border : .clear
        case .danger:
            return .clear
        }
    }
}

/// Icon-only button
@available(macOS 14.0, *)
public struct IconButton: View {
    let icon: String
    let size: CGFloat
    let style: PillButtonStyle
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    public init(
        icon: String,
        size: CGFloat = 32,
        style: PillButtonStyle = .ghost,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.size = size
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size)
                .background(background)
                .clipShape(Circle())
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .animation(Theme.Animation.fast, value: isPressed)
                .animation(Theme.Animation.fast, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .pressEvents {
            isPressed = true
        } onRelease: {
            isPressed = false
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return Theme.Colors.textInverse
        case .secondary, .ghost:
            return isHovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
        case .danger:
            return isHovered ? Theme.Colors.error : Theme.Colors.textSecondary
        }
    }

    private var background: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(isHovered ? Theme.Colors.primaryHover : Theme.Colors.primary)
        case .secondary:
            return AnyShapeStyle(isHovered ? Theme.Colors.primaryMuted : Theme.Colors.primaryMuted.opacity(0.5))
        case .ghost:
            return AnyShapeStyle(isHovered ? Theme.Colors.surfaceHover : Color.clear)
        case .danger:
            return AnyShapeStyle(isHovered ? Theme.Colors.errorMuted : Color.clear)
        }
    }
}

// MARK: - Press Events Modifier

extension View {
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        self.modifier(PressEventsModifier(onPress: onPress, onRelease: onRelease))
    }
}

struct PressEventsModifier: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}

