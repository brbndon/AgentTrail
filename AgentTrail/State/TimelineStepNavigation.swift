import Foundation

struct TimelineStepNavigation {
    let previous: UUID?
    let next: UUID?

    init(orderedIDs: [UUID], selection: UUID?) {
        guard let selection, let index = orderedIDs.firstIndex(of: selection) else {
            previous = nil
            next = nil
            return
        }
        previous = index > 0 ? orderedIDs[index - 1] : nil
        next = index + 1 < orderedIDs.count ? orderedIDs[index + 1] : nil
    }
}

enum TimelineSelection {
    /// Keeps a still-visible selection, otherwise falls back to the first visible event (nil when none remain).
    static func reconciled(current: UUID?, matchingIDs: [UUID]) -> UUID? {
        guard let first = matchingIDs.first else { return nil }
        if let current, matchingIDs.contains(current) { return current }
        return first
    }
}
