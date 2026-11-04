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
