import Foundation

/// A read-only snapshot of the full session, independent of timeline filters.
struct SessionSummary: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        case hasErrors(Int)
        case running
    }

    let originalRequest: String?
    let finalAssistantMessage: String?
    private(set) var duration: TimeInterval
    private let recordedDuration: TimeInterval
    let stepCount: Int
    let errorCount: Int
    let filesTouched: [String]
    private(set) var outcome: Outcome

    init(session: SessionRecord, steps: [StepRecord], now: Date) {
        var firstUser: StepRecord?
        var lastAssistant: StepRecord?
        var latestTimestamp = session.startDate
        var errors = 0
        var paths = Set<String>()

        for step in steps {
            if step.kind == .user, firstUser.map({ step.stepIndex < $0.stepIndex }) ?? true {
                firstUser = step
            }
            if step.kind == .assistant, lastAssistant.map({ step.stepIndex > $0.stepIndex }) ?? true {
                lastAssistant = step
            }
            latestTimestamp = max(latestTimestamp, step.timestamp)
            if step.hasError { errors += 1 }
            if let path = step.filePath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paths.insert(path)
            }
            for change in step.fileChanges where !change.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paths.insert(change.path)
            }
        }

        let isRunning = SessionLiveness.isRecentlyWriting(session, now: now)
        originalRequest = firstUser.map { $0.contentSummary.isEmpty ? $0.title : $0.contentSummary }
        finalAssistantMessage = lastAssistant.map { $0.contentSummary.isEmpty ? $0.title : $0.contentSummary }
        recordedDuration = max(0, max(session.endDate ?? latestTimestamp, latestTimestamp).timeIntervalSince(session.startDate))
        duration = isRunning ? max(0, now.timeIntervalSince(session.startDate)) : recordedDuration
        stepCount = steps.count
        errorCount = errors
        filesTouched = paths.sorted()
        // Recent writes take precedence even if earlier work recorded errors.
        outcome = isRunning ? .running : (errors > 0 ? .hasErrors(errors) : .completed)
    }

    /// Refresh the live badge and clock without rereading any step relationships.
    func updatingLiveness(session: SessionRecord, now: Date) -> SessionSummary {
        var updated = self
        let isRunning = SessionLiveness.isRecentlyWriting(session, now: now)
        updated.duration = isRunning ? max(0, now.timeIntervalSince(session.startDate)) : recordedDuration
        updated.outcome = isRunning ? .running : (errorCount > 0 ? .hasErrors(errorCount) : .completed)
        return updated
    }
}
