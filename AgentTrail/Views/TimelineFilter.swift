import Foundation

enum TraceSearch {
    static func terms(_ query: String) -> [String] {
        query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func matches(_ query: String, fields: [String?]) -> Bool {
        let terms = terms(query)
        guard !terms.isEmpty else { return true }
        let corpus = fields.compactMap { $0 }.joined(separator: " ")
        return terms.allSatisfy { corpus.localizedCaseInsensitiveContains($0) }
    }
}

/// The lightweight, in-memory filters applied to a selected trace.
struct TimelineFilter: Equatable, Sendable {
    var preset: TimelineFilterPreset = .all
    var query = ""
    var kindRawValue = "all"
    var errorsOnly = false
    var filePathQuery = ""
    var dateRange: TimelineDateRange = .all

    var kind: StepKind? {
        StepKind(rawValue: kindRawValue)
    }

    var isActive: Bool {
        preset != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != nil || errorsOnly
            || !filePathQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dateRange != .all
    }

    /// Returns whether a normalized step satisfies every active filter.
    func matches(_ step: StepRecord) -> Bool {
        if !preset.matches(step) { return false }
        if let kind, step.kind != kind { return false }
        if errorsOnly, !step.hasError { return false }

        let pathQuery = filePathQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pathQuery.isEmpty {
            let matchesPath =
                (step.filePath ?? "").localizedCaseInsensitiveContains(pathQuery)
                || step.fileChanges.contains { $0.path.localizedCaseInsensitiveContains(pathQuery) }
            if !matchesPath { return false }
        }

        if let startDate = dateRange.startDate, step.timestamp < startDate {
            return false
        }

        if !TraceSearch.matches(
            query,
            fields: [
                step.title,
                step.contentSummary,
                step.searchText,
                step.kind.displayName,
                step.filePath,
                step.commandText,
            ])
        {
            return false
        }

        return true
    }

    mutating func reset() {
        self = TimelineFilter()
    }
}

enum TimelineFilterPreset: String, CaseIterable, Identifiable, Sendable {
    case all, messages, actions, errors

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var kinds: Set<StepKind> {
        switch self {
        case .all, .errors: Set(StepKind.allCases)
        case .messages: [.user, .assistant]
        case .actions: [.toolCall, .toolResult, .fileChange, .shellCommand]
        }
    }

    func matches(_ step: StepRecord) -> Bool {
        kinds.contains(step.kind) && (self != .errors || step.hasError)
    }
}

/// Date presets that keep filtering keyboard-friendly and easy to scan.
enum TimelineDateRange: String, CaseIterable, Equatable, Identifiable, Sendable {
    case all
    case today
    case lastSevenDays
    case lastThirtyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All time"
        case .today: "Today"
        case .lastSevenDays: "Last 7 days"
        case .lastThirtyDays: "Last 30 days"
        }
    }

    var startDate: Date? {
        switch self {
        case .all:
            nil
        case .today:
            Calendar.current.startOfDay(for: .now)
        case .lastSevenDays:
            Calendar.current.date(byAdding: .day, value: -7, to: .now)
        case .lastThirtyDays:
            Calendar.current.date(byAdding: .day, value: -30, to: .now)
        }
    }
}
