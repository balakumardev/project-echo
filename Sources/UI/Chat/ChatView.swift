import SwiftUI
import Intelligence

/// Main chat view for the RAG feature
@available(macOS 14.0, *)
public struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var aiService = AIServiceObservable()

    /// Callback when a citation is tapped
    var onCitationTap: ((Citation) -> Void)?

    /// Scroll view proxy for auto-scrolling
    @Namespace private var bottomAnchor

    public init(
        viewModel: ChatViewModel,
        onCitationTap: ((Citation) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onCitationTap = onCitationTap
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Model status header with error display
            modelStatusHeader

            // Inline setup prompt when not configured AND no cached model
            // If model is cached, it will auto-load - show loading state instead
            if case .notConfigured = aiService.status,
               !aiService.isModelCached(aiService.selectedModelId) {
                inlineSetupPrompt
            } else if case .notConfigured = aiService.status {
                // Model is cached but still loading - show loading indicator
                loadingModelView
            } else if case .unloadedToSaveMemory = aiService.status {
                // Model was unloaded to save memory - show sleeping state
                modelSleepingView
            }

            // Messages area
            messagesScrollView

            // Input area
            // Allow input when ready OR when model is sleeping (will auto-reload)
            ChatInputField(
                text: $viewModel.inputText,
                isEnabled: aiService.canUseAI && !viewModel.isGenerating,
                isGenerating: viewModel.isGenerating,
                onSend: {
                    Task {
                        await viewModel.sendMessage()
                    }
                },
                onStop: {
                    viewModel.stopGeneration()
                }
            )
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Colors.background)
    }

    // MARK: - Inline Setup Prompt

    private var inlineSetupPrompt: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.Colors.primary)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Set up AI Chat")
                        .font(Theme.Typography.headline)
                        .foregroundColor(Theme.Colors.textPrimary)

                    Text("Download a local model to chat about your meetings")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textSecondary)
                }

                Spacer()
            }

            // Quick model selection
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Choose a model:")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)

                ForEach(ModelRegistry.availableModels.prefix(3)) { model in
                    inlineModelOption(model)
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.surface)
        .overlay(
            Rectangle()
                .fill(Theme.Colors.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Loading Model View

    private var loadingModelView: some View {
        HStack(spacing: Theme.Spacing.md) {
            ProgressView()
                .scaleEffect(0.8)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Loading AI Model...")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("This may take a moment")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textSecondary)
            }

            Spacer()
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.surface)
        .overlay(
            Rectangle()
                .fill(Theme.Colors.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Model Sleeping View (Auto-unloaded to save memory)

    private var modelSleepingView: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 24))
                .foregroundColor(Theme.Colors.primary)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("AI Model Sleeping")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("The model was unloaded to save memory. It will reload automatically when you send a message.")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textSecondary)
            }

            Spacer()
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.primaryMuted.opacity(0.3))
        .overlay(
            Rectangle()
                .fill(Theme.Colors.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func inlineModelOption(_ model: ModelRegistry.ModelInfo) -> some View {
        let isCached = aiService.isModelCached(model.id)

        return Button {
            aiService.setupModel(model.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(Theme.Typography.callout)
                            .foregroundColor(Theme.Colors.textPrimary)

                        if model.isDefault {
                            Text("Recommended")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.Colors.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.Colors.primaryMuted))
                        }

                        if isCached {
                            Text("Ready")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.Colors.success)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.Colors.successMuted))
                        }
                    }

                    Text("\(model.sizeString) - \(model.description)")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isCached ? "play.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.Colors.primary)
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.Colors.background)
            .cornerRadius(Theme.Radius.md)
        }
        .buttonStyle(.plain)
        .disabled(aiService.isLoading)
    }

    // MARK: - Model Status Header

    private var modelStatusHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                // Status indicator
                Circle()
                    .fill(aiService.statusColor)
                    .frame(width: 8, height: 8)

                // Status text
                Text(statusText)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textSecondary)

                Spacer()

                // Clear button
                if !viewModel.messages.isEmpty {
                    Button(action: {
                        viewModel.clearHistory()
                    }) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect()
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                }

                // Retry button on error
                if case .error = aiService.status {
                    Button(action: {
                        aiService.setupModel(aiService.selectedModelId)
                    }) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.primary)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect()
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)

            // Error banner
            if case .error(let message) = aiService.status {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.Colors.error)
                    Text(message)
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.error)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.errorMuted.opacity(0.3))
            }

            // Generation error banner
            if let error = viewModel.error {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.Colors.error)
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.error)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.error = nil
                    }
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.errorMuted.opacity(0.3))
            }
        }
        .background(Theme.Colors.surface)
        .overlay(
            Rectangle()
                .fill(Theme.Colors.borderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var statusText: String {
        switch aiService.status {
        case .notConfigured:
            return "No model configured - Select a model below"
        case .unloadedToSaveMemory(let name):
            return "\(name) sleeping - Will reload when you chat"
        case .downloading(let progress, let name):
            return "Downloading \(name)... \(Int(progress * 100))%"
        case .loading(let name):
            return "Loading \(name)..."
        case .ready:
            if viewModel.hasRecordingScope {
                return "Ready - Scoped to recording"
            }
            return "Ready - Global search"
        case .error:
            return "Error - Click Retry"
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.md) {
                    // Empty state
                    if viewModel.messages.isEmpty && !viewModel.isGenerating {
                        emptyState
                    }

                    // Messages
                    ForEach(viewModel.messages) { message in
                        MessageBubble(
                            message: message,
                            onCitationTap: onCitationTap
                        )
                        .id(message.id)
                    }

                    // Streaming response
                    if viewModel.isGenerating && !viewModel.streamingResponse.isEmpty {
                        streamingBubble
                    }

                    // Typing indicator
                    if viewModel.isGenerating && viewModel.streamingResponse.isEmpty {
                        typingIndicator
                    }

                    // Bottom anchor for scrolling
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(Theme.Spacing.lg)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(Theme.Animation.fast) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.streamingResponse) { _, _ in
                withAnimation(Theme.Animation.fast) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            // Branded icon
            ZStack {
                Circle()
                    .fill(Theme.Colors.primaryMuted)
                    .frame(width: 80, height: 80)

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.Colors.primary)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Text("Ask about your meetings")
                    .font(Theme.Typography.headline)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text(emptyStateSubtitle)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // Quick actions for recording-specific queries
            if viewModel.hasRecordingScope {
                VStack(spacing: Theme.Spacing.md) {
                    Text("Quick Actions")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textMuted)

                    HStack(spacing: Theme.Spacing.sm) {
                        quickActionButton(
                            title: "Summarize",
                            icon: "doc.text",
                            query: "Summarize this meeting"
                        )
                        quickActionButton(
                            title: "Action Items",
                            icon: "checklist",
                            query: "What are the action items from this meeting?"
                        )
                        quickActionButton(
                            title: "Topics",
                            icon: "list.bullet",
                            query: "What topics were discussed?"
                        )
                    }
                }
                .padding(.bottom, Theme.Spacing.md)
            }

            // Example questions
            VStack(spacing: Theme.Spacing.sm) {
                Text("Or try asking:")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textMuted)

                ForEach(exampleQuestions, id: \.self) { question in
                    Button(action: {
                        viewModel.inputText = question
                    }) {
                        Text(question)
                            .font(Theme.Typography.callout)
                            .foregroundColor(Theme.Colors.primary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(Theme.Colors.primaryMuted)
                            .cornerRadius(Theme.Radius.md)
                    }
                    .buttonStyle(.plain)
                    .disabled(!aiService.canUseAI)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxxl)
        .frame(maxWidth: .infinity)
    }

    /// Quick action button that sends a query immediately
    private func quickActionButton(title: String, icon: String, query: String) -> some View {
        Button(action: {
            viewModel.inputText = query
            Task {
                await viewModel.sendMessage()
            }
        }) {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(Theme.Typography.caption)
            }
            .foregroundColor(Theme.Colors.primary)
            .frame(width: 80, height: 60)
            .background(Theme.Colors.primaryMuted)
            .cornerRadius(Theme.Radius.md)
        }
        .buttonStyle(.plain)
        .disabled(!aiService.canUseAI || viewModel.isGenerating)
    }

    private var emptyStateSubtitle: String {
        if viewModel.hasRecordingScope {
            return "Ask questions about this recording"
        }
        return "Search across all your transcribed meetings"
    }

    private var exampleQuestions: [String] {
        if viewModel.hasRecordingScope {
            return [
                "What were the main action items?",
                "Summarize the key decisions",
                "What topics were discussed?"
            ]
        }
        return [
            "What meetings mentioned the project deadline?",
            "Find discussions about budget",
            "Who talked about the design changes?"
        ]
    }

    // MARK: - Streaming Bubble

    private var streamingBubble: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            // Assistant avatar
            Circle()
                .fill(Theme.Colors.surface)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.Colors.primary)
                )

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(markdownAttributedString(from: viewModel.streamingResponse))
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .textSelection(.enabled)

                // Cursor indicator
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.Colors.primary)
                    .frame(width: 2, height: 16)
                    .opacity(cursorOpacity)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.surface)
            .cornerRadius(Theme.Radius.lg)
            .cornerRadius(Theme.Radius.xs, corners: [.topLeft])

            Spacer(minLength: 60)
        }
        .id("streaming")
    }

    // MARK: - Markdown Parsing

    /// Parse markdown string into AttributedString for proper rendering
    private func markdownAttributedString(from text: String) -> AttributedString {
        do {
            let attributed = try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))
            return attributed
        } catch {
            return AttributedString(text)
        }
    }

    @State private var cursorOpacity: Double = 1.0

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            // Assistant avatar
            Circle()
                .fill(Theme.Colors.surface)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.Colors.primary)
                )

            HStack(spacing: Theme.Spacing.xs) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Theme.Colors.textMuted)
                        .frame(width: 6, height: 6)
                        .animation(
                            Theme.Animation.normal
                                .repeatForever()
                                .delay(Double(index) * 0.15),
                            value: viewModel.isGenerating
                        )
                }
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.surface)
            .cornerRadius(Theme.Radius.lg)

            Spacer(minLength: 60)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.Colors.error)

            Text(message)
                .font(Theme.Typography.callout)
                .foregroundColor(Theme.Colors.textPrimary)
                .lineLimit(2)

            Spacer()

            Button(action: {
                viewModel.error = nil
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.Colors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.errorMuted)
        .cornerRadius(Theme.Radius.md)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.sm)
    }
}

// MARK: - Corner Radius Extension

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath()
        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX
        let maxY = rect.maxY

        // Start from top-left
        let topLeftRadius = corners.contains(.topLeft) ? radius : 0
        let topRightRadius = corners.contains(.topRight) ? radius : 0
        let bottomRightRadius = corners.contains(.bottomRight) ? radius : 0
        let bottomLeftRadius = corners.contains(.bottomLeft) ? radius : 0

        path.move(to: NSPoint(x: minX + topLeftRadius, y: minY))

        // Top edge and top-right corner
        path.line(to: NSPoint(x: maxX - topRightRadius, y: minY))
        if topRightRadius > 0 {
            path.appendArc(
                withCenter: NSPoint(x: maxX - topRightRadius, y: minY + topRightRadius),
                radius: topRightRadius,
                startAngle: -90,
                endAngle: 0,
                clockwise: false
            )
        }

        // Right edge and bottom-right corner
        path.line(to: NSPoint(x: maxX, y: maxY - bottomRightRadius))
        if bottomRightRadius > 0 {
            path.appendArc(
                withCenter: NSPoint(x: maxX - bottomRightRadius, y: maxY - bottomRightRadius),
                radius: bottomRightRadius,
                startAngle: 0,
                endAngle: 90,
                clockwise: false
            )
        }

        // Bottom edge and bottom-left corner
        path.line(to: NSPoint(x: minX + bottomLeftRadius, y: maxY))
        if bottomLeftRadius > 0 {
            path.appendArc(
                withCenter: NSPoint(x: minX + bottomLeftRadius, y: maxY - bottomLeftRadius),
                radius: bottomLeftRadius,
                startAngle: 90,
                endAngle: 180,
                clockwise: false
            )
        }

        // Left edge and top-left corner
        path.line(to: NSPoint(x: minX, y: minY + topLeftRadius))
        if topLeftRadius > 0 {
            path.appendArc(
                withCenter: NSPoint(x: minX + topLeftRadius, y: minY + topLeftRadius),
                radius: topLeftRadius,
                startAngle: 180,
                endAngle: 270,
                clockwise: false
            )
        }

        path.close()
        return Path(path.cgPath)
    }
}

/// UIRectCorner equivalent for macOS
public struct UIRectCorner: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let topLeft = UIRectCorner(rawValue: 1 << 0)
    public static let topRight = UIRectCorner(rawValue: 1 << 1)
    public static let bottomLeft = UIRectCorner(rawValue: 1 << 2)
    public static let bottomRight = UIRectCorner(rawValue: 1 << 3)
    public static let allCorners: UIRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
struct ChatView_Previews: PreviewProvider {
    static var previews: some View {
        ChatView(viewModel: ChatViewModel(ragPipeline: MockRAGPipeline()))
            .frame(width: 600, height: 800)
    }
}

/// Mock RAG pipeline for previews
@available(macOS 14.0, *)
final class MockRAGPipeline: RAGPipelineProtocol, @unchecked Sendable {
    var isModelReady: Bool { true }
    var indexedRecordingsCount: Int { 5 }

    func totalIndexableRecordings() async -> Int { 5 }

    func query(
        _ query: String,
        recordingId: Int64?,
        conversationHistory: [(role: String, content: String)]
    ) -> AsyncThrowingStream<RAGResponse, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let response = "This is a mock response to: \(query)"
                for char in response {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    continuation.yield(RAGResponse(token: String(char)))
                }
                continuation.yield(RAGResponse(isComplete: true))
                continuation.finish()
            }
        }
    }

    func loadModels() async throws {}
    func unloadModels() async {}
}
#endif
