import Foundation

/// Navigates errors in event order while retaining search, path, and date filters.
struct TimelineErrorIndex {
    enum Direction {
        case previous
        case next
    }

    private let orderedStepIDs: [UUID]
    let errorIDs: [UUID]

    init(orderedSteps: [StepRecord], filter: TimelineFilter) {
        var navigationFilter = filter
        navigationFilter.preset = .all
        navigationFilter.kindRawValue = "all"
        orderedStepIDs = orderedSteps.map(\.id)
        errorIDs = orderedSteps.filter { $0.hasError && navigationFilter.matches($0) }.map(\.id)
    }

    /// Wraps at either end; a non-error selection starts at the nearest error.
    func destination(from selection: UUID?, direction: Direction) -> UUID? {
        guard let first = errorIDs.first, let last = errorIDs.last else { return nil }
        guard let selection, let selectedIndex = orderedStepIDs.firstIndex(of: selection) else {
            return direction == .next ? first : last
        }
        let errorSet = Set(errorIDs)
        switch direction {
        case .next:
            return orderedStepIDs.dropFirst(selectedIndex + 1).first(where: errorSet.contains) ?? first
        case .previous:
            return orderedStepIDs.prefix(selectedIndex).last(where: errorSet.contains) ?? last
        }
    }
}
