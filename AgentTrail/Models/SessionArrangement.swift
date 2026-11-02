import Foundation

/// Pure filtering, ordering, and grouping for the sidebar and dashboard so both
/// present the same loaded sessions in the same order.
enum SessionArrangement {
    static func filtered(_ sessions: [SessionRecord], query: String, agent: AgentType?) -> [SessionRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter {
            guard agent == nil || $0.agentType == agent else { return false }
            return TraceSearch.matches(query, fields: [
                $0.title,
                $0.agentType.displayName,
                $0.project?.name ?? "",
                $0.workingDirectory,
                $0.sourcePath,
                $0.status.rawValue,
                $0.sourceState.rawValue
            ])
        }
    }

    /// Ties always fall back to newest-updated, then id, so order is deterministic.
    static func sorted(
        _ sessions: [SessionRecord],
        by field: SessionSortField,
        direction: SessionSortDirection
    ) -> [SessionRecord] {
        sessions.sorted { lhs, rhs in
            let order = compare(lhs, rhs, by: field)
            if order != .orderedSame {
                return direction == .ascending ? order == .orderedAscending : order == .orderedDescending
            }
            if lhs.sourceModifiedAt != rhs.sourceModifiedAt { return lhs.sourceModifiedAt > rhs.sourceModifiedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Project sections appear in the order of their best-ranked session.
    static func groups(
        sessions: [SessionRecord],
        sort field: SessionSortField,
        direction: SessionSortDirection,
        grouping: SessionGrouping,
        totalCounts: [String: Int]
    ) -> [ProjectSessionGroup] {
        let ordered = sorted(sessions, by: field, direction: direction)
        guard !ordered.isEmpty else { return [] }
        switch grouping {
        case .flat:
            return [ProjectSessionGroup(
                id: "all-sessions",
                name: "All sessions",
                totalCount: ordered.count,
                sessions: ordered,
                showsHeader: false
            )]
        case .project:
            return SessionProjectGrouping.groups(sessions: ordered, totalCounts: totalCounts)
        }
    }

    /// Keep an open session while it is still loaded. Nothing is auto-selected,
    /// so the app opens on the dashboard rather than inside a session.
    static func reconciledSelection(current: UUID?, loadedIDs: some Sequence<UUID>) -> UUID? {
        guard let current else { return nil }
        return loadedIDs.contains(current) ? current : nil
    }

    private static func compare(_ lhs: SessionRecord, _ rhs: SessionRecord, by field: SessionSortField) -> ComparisonResult {
        switch field {
        case .lastUpdated: compare(lhs.sourceModifiedAt, rhs.sourceModifiedAt)
        case .started: compare(lhs.startDate, rhs.startDate)
        case .title: lhs.title.localizedStandardCompare(rhs.title)
        case .eventCount: compare(lhs.stepCount, rhs.stepCount)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }
}
