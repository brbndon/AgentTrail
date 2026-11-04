import Foundation
import Observation

enum SessionSortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending
    case descending

    var id: String { rawValue }
}

enum SessionSortField: String, CaseIterable, Identifiable, Sendable {
    case lastUpdated
    case started
    case title
    case eventCount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lastUpdated: "Last updated"
        case .started: "Date started"
        case .title: "Title"
        case .eventCount: "Event count"
        }
    }

    /// The direction users expect first: newest/most first, but A to Z for titles.
    var defaultDirection: SessionSortDirection {
        self == .title ? .ascending : .descending
    }

    func directionLabel(_ direction: SessionSortDirection) -> String {
        switch (self, direction) {
        case (.lastUpdated, .descending), (.started, .descending): "Newest first"
        case (.lastUpdated, .ascending), (.started, .ascending): "Oldest first"
        case (.title, .ascending): "A to Z"
        case (.title, .descending): "Z to A"
        case (.eventCount, .descending): "Most events first"
        case (.eventCount, .ascending): "Fewest events first"
        }
    }
}

enum SessionGrouping: String, CaseIterable, Identifiable, Sendable {
    case flat
    case project

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat: "Flat"
        case .project: "Projects"
        }
    }
}

enum AppLayoutStyle: String, CaseIterable, Identifiable, Sendable {
    case classic
    case dashboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .dashboard: "Dashboard"
        }
    }

    var explanation: String {
        switch self {
        case .classic: "A session list on the left and the selected timeline on the right. The dashboard grid appears when no session is selected."
        case .dashboard: "A full-window grid of sessions. Open one to see its timeline, then return with the Dashboard button."
        }
    }
}

/// User-configurable browsing options shared by the sidebar, dashboard, and
/// Settings. Values persist in `UserDefaults`; unknown stored values fall back
/// to the defaults so a future rename can never break launch.
@MainActor
@Observable
final class BrowsePreferences {
    private enum Key {
        static let sortField = "BrowseSortField"
        static let sortDirection = "BrowseSortDirection"
        static let grouping = "BrowseGrouping"
        static let layout = "AppLayoutStyle"
        static let viewMode = "BrowseViewMode"
    }

    private let defaults: UserDefaults

    var sortField: SessionSortField {
        didSet { defaults.set(sortField.rawValue, forKey: Key.sortField) }
    }

    var sortDirection: SessionSortDirection {
        didSet { defaults.set(sortDirection.rawValue, forKey: Key.sortDirection) }
    }

    var grouping: SessionGrouping {
        didSet { defaults.set(grouping.rawValue, forKey: Key.grouping) }
    }

    var layout: AppLayoutStyle {
        didSet { defaults.set(layout.rawValue, forKey: Key.layout) }
    }

    var viewMode: BrowseViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let field = defaults.string(forKey: Key.sortField).flatMap(SessionSortField.init(rawValue:)) ?? .lastUpdated
        sortField = field
        sortDirection =
            defaults.string(forKey: Key.sortDirection).flatMap(SessionSortDirection.init(rawValue:))
            ?? field.defaultDirection
        grouping = defaults.string(forKey: Key.grouping).flatMap(SessionGrouping.init(rawValue:)) ?? .project
        layout = defaults.string(forKey: Key.layout).flatMap(AppLayoutStyle.init(rawValue:)) ?? .classic
        viewMode = defaults.string(forKey: Key.viewMode).flatMap(BrowseViewMode.init(rawValue:)) ?? .simple
    }

    /// Switching fields resets to that field's natural direction.
    func select(sortField field: SessionSortField) {
        guard field != sortField else { return }
        sortField = field
        sortDirection = field.defaultDirection
    }

    var sortSummary: String {
        "\(sortField.displayName) · \(sortField.directionLabel(sortDirection))"
    }
}

enum BrowseViewMode: String, CaseIterable, Identifiable, Sendable {
    case simple, technical
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
