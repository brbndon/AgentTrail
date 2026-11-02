import SwiftUI

/// Always-visible sort and grouping controls shared by the sidebar and dashboard.
/// The sort menu's title states the current order so it never has to be guessed.
struct SessionBrowseControls: View {
    @Bindable var preferences: BrowsePreferences

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                sortMenu
                Spacer(minLength: 0)
                groupingPicker
            }
            VStack(alignment: .leading, spacing: 6) {
                sortMenu
                groupingPicker
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: sortFieldBinding) {
                ForEach(SessionSortField.allCases) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Order", selection: $preferences.sortDirection) {
                ForEach(SessionSortDirection.allCases) { direction in
                    Text(preferences.sortField.directionLabel(direction)).tag(direction)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(preferences.sortSummary, systemImage: "arrow.up.arrow.down")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Choose how sessions are sorted")
        .accessibilityLabel("Sort sessions")
        .accessibilityValue(preferences.sortSummary)
    }

    private var groupingPicker: some View {
        Picker("Group by", selection: $preferences.grouping) {
            ForEach(SessionGrouping.allCases) { grouping in
                Text(grouping.displayName).tag(grouping)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show sessions in one flat list or grouped by project directory")
        .accessibilityLabel("Group sessions")
    }

    private var sortFieldBinding: Binding<SessionSortField> {
        Binding(
            get: { preferences.sortField },
            set: { preferences.select(sortField: $0) }
        )
    }
}
