import SwiftUI

/// Text input field with send/stop button for the chat interface
@available(macOS 14.0, *)
public struct ChatInputField: View {
    /// The input text binding
    @Binding var text: String

    /// Whether the input is enabled
    var isEnabled: Bool

    /// Whether generation is in progress
    var isGenerating: Bool

    /// Callback when send is triggered
    var onSend: () -> Void

    /// Callback when stop is triggered
    var onStop: () -> Void

    /// Focus state for the text field
    @FocusState private var isFocused: Bool

    /// Hover state for the send button
    @State private var isButtonHovered: Bool = false

    /// Placeholder text
    private let placeholder = "Ask about your meetings..."

    public init(
        text: Binding<String>,
        isEnabled: Bool,
        isGenerating: Bool,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self._text = text
        self.isEnabled = isEnabled
        self.isGenerating = isGenerating
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            // Text input area
            inputArea

            // Send/Stop button
            actionButton
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Colors.surface)
        .cornerRadius(Theme.Radius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(
                    isFocused ? Theme.Colors.primary.opacity(0.5) : Theme.Colors.border,
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .animation(Theme.Animation.fast, value: isFocused)
    }

    // MARK: - Input Area

    private var inputArea: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder
            if text.isEmpty {
                Text(placeholder)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textMuted)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.sm)
                    .allowsHitTesting(false)
            }

            // Text editor for multi-line input
            TextEditor(text: $text)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .focused($isFocused)
                .disabled(!isEnabled)
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    // Shift+Enter inserts a newline, Enter alone sends the message
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored  // Let the TextEditor handle Shift+Enter for newlines
                    }
                    handleSubmit()
                    return .handled
                }
                .onChange(of: text) { _, newValue in
                    // Auto-resize based on content
                }
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button(action: {
            if isGenerating {
                onStop()
            } else {
                handleSubmit()
            }
        }) {
            ZStack {
                // Background
                Circle()
                    .fill(buttonBackgroundColor)
                    .frame(width: 36, height: 36)

                // Icon
                Image(systemName: buttonIconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(buttonIconColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(shouldDisableButton)
        .onHover { hovering in
            withAnimation(Theme.Animation.fast) {
                isButtonHovered = hovering
            }
        }
        .help(buttonHelpText)
    }

    // MARK: - Button Styling

    private var buttonBackgroundColor: Color {
        if isGenerating {
            return isButtonHovered ? Theme.Colors.error : Theme.Colors.errorMuted
        }

        if shouldDisableButton {
            return Theme.Colors.surfaceHover
        }

        return isButtonHovered ? Theme.Colors.primaryHover : Theme.Colors.primary
    }

    private var buttonIconColor: Color {
        if isGenerating {
            return Theme.Colors.error
        }

        if shouldDisableButton {
            return Theme.Colors.textMuted
        }

        return .white
    }

    private var buttonIconName: String {
        if isGenerating {
            return "stop.fill"
        }
        return "paperplane.fill"
    }

    private var shouldDisableButton: Bool {
        if isGenerating {
            return false  // Stop button is always enabled during generation
        }
        return !isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var buttonHelpText: String {
        if isGenerating {
            return "Stop generating (Esc)"
        }
        if !isEnabled {
            return "Model not ready"
        }
        return "Send message (Enter)"
    }

    // MARK: - Actions

    private func handleSubmit() {
        guard !shouldDisableButton else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend()
    }
}

// MARK: - Keyboard Shortcuts

@available(macOS 14.0, *)
extension ChatInputField {
    /// Handles keyboard shortcuts for the chat input
    func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        // Cmd+Enter to send
        if event.modifierFlags.contains(.command) && event.keyCode == 36 {
            handleSubmit()
            return true
        }

        // Escape to stop generation
        if event.keyCode == 53 && isGenerating {
            onStop()
            return true
        }

        return false
    }
}

// MARK: - Expandable Text Editor

/// A text editor that expands based on content
@available(macOS 14.0, *)
struct ExpandingTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let maxHeight: CGFloat
    var onSubmit: () -> Void

    @State private var textHeight: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hidden text to calculate height
            Text(text.isEmpty ? " " : text)
                .font(Theme.Typography.body)
                .foregroundColor(.clear)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.sm)
                .background(GeometryReader { geometry in
                    Color.clear.preference(
                        key: TextHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                })

            // Placeholder
            if text.isEmpty {
                Text(placeholder)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textMuted)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.sm)
            }

            // Actual text editor
            TextEditor(text: $text)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(height: min(textHeight, maxHeight))
        }
        .onPreferenceChange(TextHeightPreferenceKey.self) { height in
            textHeight = height
        }
    }
}

struct TextHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 36

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
struct ChatInputField_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State var text: String = ""
        @State var isGenerating: Bool = false

        var body: some View {
            VStack(spacing: Theme.Spacing.lg) {
                // Normal state
                ChatInputField(
                    text: $text,
                    isEnabled: true,
                    isGenerating: false,
                    onSend: { print("Send: \(text)") },
                    onStop: {}
                )

                // With text
                ChatInputField(
                    text: .constant("What were the action items?"),
                    isEnabled: true,
                    isGenerating: false,
                    onSend: {},
                    onStop: {}
                )

                // Generating state
                ChatInputField(
                    text: .constant(""),
                    isEnabled: true,
                    isGenerating: true,
                    onSend: {},
                    onStop: { print("Stop") }
                )

                // Disabled state
                ChatInputField(
                    text: .constant(""),
                    isEnabled: false,
                    isGenerating: false,
                    onSend: {},
                    onStop: {}
                )
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Colors.background)
            .frame(width: 500)
        }
    }

    static var previews: some View {
        PreviewWrapper()
    }
}
#endif
