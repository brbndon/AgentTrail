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
    let duration: TimeInterval
    let stepCount: Int
    let errorCount: Int
    let filesTouched: [String]
    let outcome: Outcome

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
        duration = max(
            0,
            (isRunning ? now : max(session.endDate ?? latestTimestamp, latestTimestamp))
                .timeIntervalSince(session.startDate))
        stepCount = steps.count
        errorCount = errors
        filesTouched = paths.sorted()
        // Recent writes take precedence even if earlier work recorded errors.
        outcome = isRunning ? .running : (errors > 0 ? .hasErrors(errors) : .completed)
    }
}
