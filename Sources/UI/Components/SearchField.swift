import SwiftUI

/// A styled search field with icon and clear button
@available(macOS 14.0, *)
public struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: (() -> Void)?
    let showAIButton: Bool
    let onAISearch: ((String) -> Void)?

    @State private var isFocused = false
    @FocusState private var fieldFocus: Bool

    public init(
        text: Binding<String>,
        placeholder: String = "Search...",
        showAIButton: Bool = false,
        onAISearch: ((String) -> Void)? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.showAIButton = showAIButton
        self.onAISearch = onAISearch
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Search icon
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isFocused ? Theme.Colors.primary : Theme.Colors.textMuted)
                .animation(Theme.Animation.fast, value: isFocused)

            // Text field
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Colors.textPrimary)
                .focused($fieldFocus)
                .onSubmit {
                    onSubmit?()
                }

            // Clear button
            if !text.isEmpty {
                Button {
                    withAnimation(Theme.Animation.fast) {
                        text = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            // AI search button
            if showAIButton {
                Button {
                    onAISearch?(text)
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Colors.primary)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Theme.Colors.primaryMuted)
                        )
                }
                .buttonStyle(.plain)
                .help("Ask AI")
            }

            // Keyboard shortcut hint
            if text.isEmpty && !isFocused {
                Text("\u{2318}F")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.Colors.surfaceHover)
                    )
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm + 2)
        .background(
            Capsule()
                .fill(Theme.Colors.surface)
        )
        .overlay(
            Capsule()
                .stroke(
                    isFocused ? Theme.Colors.primary.opacity(0.5) : Theme.Colors.borderSubtle,
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .animation(Theme.Animation.fast, value: isFocused)
        .onChange(of: fieldFocus) { _, newValue in
            isFocused = newValue
        }
    }
}

/// Inline search for compact spaces
@available(macOS 14.0, *)
public struct InlineSearch: View {
    @Binding var text: String
    let placeholder: String

    @State private var isExpanded = false
    @FocusState private var fieldFocus: Bool

    public init(text: Binding<String>, placeholder: String = "Search") {
        self._text = text
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if isExpanded {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.callout)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .focused($fieldFocus)
                    .frame(width: 150)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }

            Button {
                withAnimation(Theme.Animation.spring) {
                    isExpanded.toggle()
                    if isExpanded {
                        fieldFocus = true
                    } else {
                        text = ""
                    }
                }
            } label: {
                Image(systemName: isExpanded ? "xmark" : "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isExpanded ? Theme.Colors.surfaceHover : .clear)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, isExpanded ? Theme.Spacing.sm : 0)
        .padding(.vertical, isExpanded ? Theme.Spacing.xs : 0)
        .background(
            Capsule()
                .fill(isExpanded ? Theme.Colors.surface : .clear)
                .overlay(
                    Capsule()
                        .stroke(isExpanded ? Theme.Colors.borderSubtle : .clear, lineWidth: 1)
                )
        )
        .animation(Theme.Animation.spring, value: isExpanded)
    }
}

