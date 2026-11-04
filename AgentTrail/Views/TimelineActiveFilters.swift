import SwiftUI

struct TimelineActiveFilters: View {
    @Binding var filter: TimelineFilter

    var body: some View {
        if filter.isActive {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if !filter.query.isEmpty { chip("Search: \(filter.query)") { filter.query = "" } }
                    if filter.preset != .all { chip(filter.preset.title) { filter.preset = .all } }
                    if let kind = filter.kind { chip(kind.displayName) { filter.kindRawValue = "all" } }
                    if filter.errorsOnly { chip("Errors only") { filter.errorsOnly = false } }
                    if !filter.filePathQuery.isEmpty { chip("File: \(filter.filePathQuery)") { filter.filePathQuery = "" } }
                    if filter.dateRange != .all { chip(filter.dateRange.title) { filter.dateRange = .all } }
                    Button("Clear all") { filter.reset() }
                        .buttonStyle(.link)
                        .accessibilityLabel("Clear all timeline filters")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { Label(title, systemImage: "xmark.circle.fill").lineLimit(1) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Remove filter: \(title)")
    }
}
