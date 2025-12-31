import SwiftUI

/// Filter options for recordings
public enum RecordingFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case today = "Today"
    case thisWeek = "This Week"
    case hasTranscript = "Transcribed"
    case favorites = "Favorites"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .today: return "calendar"
        case .thisWeek: return "calendar.badge.clock"
        case .hasTranscript: return "text.quote"
        case .favorites: return "star"
        }
    }
}

/// Horizontal scrolling filter chips
@available(macOS 14.0, *)
public struct FilterChips: View {
    @Binding var selectedFilter: RecordingFilter

    public init(selectedFilter: Binding<RecordingFilter>) {
        self._selectedFilter = selectedFilter
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(RecordingFilter.allCases) { filter in
                    FilterChip(
                        title: filter.rawValue,
                        icon: filter.icon,
                        isSelected: selectedFilter == filter
                    ) {
                        withAnimation(Theme.Animation.spring) {
                            selectedFilter = filter
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }
}

/// Individual filter chip
@available(macOS 14.0, *)
public struct FilterChip: View {
    let title: String
    let icon: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    public init(
        title: String,
        icon: String? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(Theme.Typography.footnote)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs + 2)
            .foregroundColor(foregroundColor)
            .background(background)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
            .animation(Theme.Animation.fast, value: isSelected)
            .animation(Theme.Animation.fast, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var foregroundColor: Color {
        if isSelected {
            return Theme.Colors.textInverse
        }
        return isHovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
    }

    private var background: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Theme.Colors.primary)
        }
        return AnyShapeStyle(isHovered ? Theme.Colors.surfaceHover : Color.clear)
    }

    private var borderColor: Color {
        if isSelected {
            return .clear
        }
        return isHovered ? Theme.Colors.border : Theme.Colors.borderSubtle
    }
}

/// Sort options
public enum RecordingSort: String, CaseIterable, Identifiable {
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case durationDesc = "Longest First"
    case durationAsc = "Shortest First"
    case title = "Title A-Z"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .dateDesc: return "arrow.down.circle"
        case .dateAsc: return "arrow.up.circle"
        case .durationDesc: return "clock.arrow.circlepath"
        case .durationAsc: return "clock"
        case .title: return "textformat.abc"
        }
    }
}

/// Sort dropdown menu
@available(macOS 14.0, *)
public struct SortMenu: View {
    @Binding var selectedSort: RecordingSort

    @State private var isHovered = false

    public init(selectedSort: Binding<RecordingSort>) {
        self._selectedSort = selectedSort
    }

    public var body: some View {
        Menu {
            ForEach(RecordingSort.allCases) { sort in
                Button {
                    selectedSort = sort
                } label: {
                    HStack {
                        Image(systemName: sort.icon)
                        Text(sort.rawValue)
                        if selectedSort == sort {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                Text("Sort")
                    .font(Theme.Typography.footnote)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs + 2)
            .foregroundColor(isHovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
            .background(
                Capsule()
                    .fill(isHovered ? Theme.Colors.surfaceHover : .clear)
            )
            .overlay(
                Capsule()
                    .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

