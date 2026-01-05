import SwiftUI

/// A popover view for selecting a custom date range
/// Used with the "Custom" filter chip in FilterChips
@available(macOS 14.0, *)
struct DateRangePickerPopover: View {
    @Binding var startDate: Date?
    @Binding var endDate: Date?
    @Binding var isPresented: Bool
    let onApply: () -> Void

    // Internal editing state (not applied until user clicks Apply)
    @State private var editingStartDate: Date
    @State private var editingEndDate: Date

    init(
        startDate: Binding<Date?>,
        endDate: Binding<Date?>,
        isPresented: Binding<Bool>,
        onApply: @escaping () -> Void
    ) {
        self._startDate = startDate
        self._endDate = endDate
        self._isPresented = isPresented
        self.onApply = onApply

        // Initialize editing state from bindings or defaults
        let defaultStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let defaultEnd = Date()

        _editingStartDate = State(initialValue: startDate.wrappedValue ?? defaultStart)
        _editingEndDate = State(initialValue: endDate.wrappedValue ?? defaultEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Header
            Text("Date Range")
                .font(Theme.Typography.headline)
                .foregroundColor(Theme.Colors.textPrimary)

            // Date pickers
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // From date
                HStack {
                    Text("From:")
                        .font(Theme.Typography.body)
                        .foregroundColor(Theme.Colors.textSecondary)
                        .frame(width: 50, alignment: .leading)

                    DatePicker(
                        "",
                        selection: $editingStartDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)
                }

                // To date
                HStack {
                    Text("To:")
                        .font(Theme.Typography.body)
                        .foregroundColor(Theme.Colors.textSecondary)
                        .frame(width: 50, alignment: .leading)

                    DatePicker(
                        "",
                        selection: $editingEndDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)
                }
            }

            // Validation message
            if editingStartDate > editingEndDate {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Start date must be before end date")
                }
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.error)
            }

            Divider()

            // Quick presets
            HStack(spacing: Theme.Spacing.sm) {
                QuickPresetButton(title: "Last 7 days") {
                    editingStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                    editingEndDate = Date()
                }

                QuickPresetButton(title: "Last 30 days") {
                    editingStartDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
                    editingEndDate = Date()
                }

                QuickPresetButton(title: "This month") {
                    let now = Date()
                    let calendar = Calendar.current
                    editingStartDate = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
                    editingEndDate = now
                }
            }

            Divider()

            // Action buttons
            HStack {
                Button("Clear") {
                    startDate = nil
                    endDate = nil
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.Colors.textSecondary)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.Colors.textSecondary)

                Button("Apply") {
                    applyDateRange()
                }
                .buttonStyle(.borderedProminent)
                .disabled(editingStartDate > editingEndDate)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 300)
    }

    private func applyDateRange() {
        // Set start to beginning of day
        startDate = Calendar.current.startOfDay(for: editingStartDate)

        // Set end to end of day (start of next day)
        let endOfDay = Calendar.current.startOfDay(for: editingEndDate)
        endDate = Calendar.current.date(byAdding: .day, value: 1, to: endOfDay)

        onApply()
        isPresented = false
    }
}

// MARK: - Quick Preset Button

@available(macOS 14.0, *)
private struct QuickPresetButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundColor(isHovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(isHovered ? Theme.Colors.surfaceHover : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
#Preview {
    DateRangePickerPopover(
        startDate: .constant(nil),
        endDate: .constant(nil),
        isPresented: .constant(true),
        onApply: {}
    )
    .background(Theme.Colors.surface)
}
#endif
