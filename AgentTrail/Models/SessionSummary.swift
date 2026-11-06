import Foundation

/// A read-only snapshot of the full session, independent of timeline filters.
struct SessionSummary: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        /// Stopped writing without an assistant reply or recorded errors, so success cannot be claimed.
        case ended
        case hasErrors(Int)
        case running

        var symbolName: String {
            switch self {
            case .completed: "checkmark.circle"
            case .ended: "stop.circle"
            case .hasErrors: "exclamationmark.triangle"
            case .running: "record.circle"
            }
        }

        static func resolve(isRunning: Bool, errorCount: Int, hasFinalReply: Bool) -> Outcome {
            // Recent writes take precedence even if earlier work recorded errors.
            if isRunning { return .running }
            if errorCount > 0 { return .hasErrors(errorCount) }
            return hasFinalReply ? .completed : .ended
        }
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
        outcome = .resolve(isRunning: isRunning, errorCount: errors, hasFinalReply: finalAssistantMessage != nil)
    }

    /// Refresh the live badge and clock without rereading any step relationships.
    func updatingLiveness(session: SessionRecord, now: Date) -> SessionSummary {
        var updated = self
        let isRunning = SessionLiveness.isRecentlyWriting(session, now: now)
        updated.duration = isRunning ? max(0, now.timeIntervalSince(session.startDate)) : recordedDuration
        updated.outcome = .resolve(isRunning: isRunning, errorCount: errorCount, hasFinalReply: finalAssistantMessage != nil)
        return updated
    }
}
