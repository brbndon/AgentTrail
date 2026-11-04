@testable import AgentTrail
import Foundation
import XCTest

final class SessionSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSummaryUsesEventOrderAndDistinctPathsFromBothSources() {
        let session = makeSession()
        let request = step(0, .user, "Original request")
        let reply = step(2, .assistant, "First reply")
        let finalReply = step(5, .assistant, "Final result")
        let command = step(3, .shellCommand, "Failed command", hasError: true, path: "Sources/App.swift")
        command.fileChanges = [
            FileChangeRecord(path: "Sources/App.swift", changeType: "modified"),
            FileChangeRecord(path: "Tests/AppTests.swift", changeType: "added"),
            FileChangeRecord(path: "", changeType: "modified"),
        ]
        let steps = [finalReply, step(4, .user, "Follow-up"), command, reply, request]
        let summary = SessionSummary(session: session, steps: steps, now: now)

        XCTAssertEqual(summary.originalRequest, "Original request")
        XCTAssertEqual(summary.finalAssistantMessage, "Final result")
        XCTAssertEqual(summary.duration, 600)
        XCTAssertEqual(summary.stepCount, 5)
        XCTAssertEqual(summary.errorCount, 1)
        XCTAssertEqual(summary.filesTouched, ["Sources/App.swift", "Tests/AppTests.swift"])
        XCTAssertEqual(summary.outcome, .hasErrors(1))
    }

    func testEmptySession() {
        let session = makeSession()
        session.endDate = nil
        let summary = SessionSummary(session: session, steps: [], now: now)
        XCTAssertNil(summary.originalRequest)
        XCTAssertNil(summary.finalAssistantMessage)
        XCTAssertEqual(summary.duration, 0)
        XCTAssertEqual(summary.stepCount, 0)
        XCTAssertEqual(summary.errorCount, 0)
        XCTAssertTrue(summary.filesTouched.isEmpty)
        XCTAssertEqual(summary.outcome, .completed)
    }

    func testNoAssistantReplyAndMissingEndUseLastEventTime() {
        let session = makeSession()
        session.endDate = nil
        let summary = SessionSummary(session: session, steps: [step(0, .user, "Request"), step(3, .toolResult, "Output")], now: now)
        XCTAssertEqual(summary.originalRequest, "Request")
        XCTAssertNil(summary.finalAssistantMessage)
        XCTAssertEqual(summary.duration, 180)
        XCTAssertEqual(summary.outcome, .completed)
    }

    func testOnlyErrorsIncludesAnyKindFlaggedAsError() {
        let summary = SessionSummary(
            session: makeSession(),
            steps: [
                step(0, .error, "Error", hasError: true),
                step(1, .toolResult, "Tool failed", hasError: true),
            ], now: now)
        XCTAssertNil(summary.originalRequest)
        XCTAssertNil(summary.finalAssistantMessage)
        XCTAssertEqual(summary.errorCount, 2)
        XCTAssertEqual(summary.outcome, .hasErrors(2))
    }

    func testRunningUsesLivenessAndElapsedTimeDespiteEarlierErrors() {
        let session = makeSession()
        session.sourceModifiedAt = now.addingTimeInterval(-179)
        let steps = [step(0, .error, "Earlier error", hasError: true)]
        let summary = SessionSummary(session: session, steps: steps, now: now)
        XCTAssertEqual(summary.outcome, .running)
        XCTAssertEqual(summary.errorCount, 1)
        XCTAssertEqual(summary.duration, 1_000)

        let expired = SessionSummary(session: session, steps: steps, now: now.addingTimeInterval(1))
        XCTAssertEqual(expired.outcome, .hasErrors(1))
        XCTAssertEqual(expired.duration, 600)
    }

    func testRecentlyWrittenBranchIsCompleted() {
        let session = makeSession()
        session.sourceKey = "branch:summary"
        session.sourceModifiedAt = now
        XCTAssertEqual(SessionSummary(session: session, steps: [], now: now).outcome, .completed)
    }

    func testDurationNeverNegativeAndIncludesEventsBeyondEndMetadata() {
        let session = makeSession()
        session.endDate = session.startDate.addingTimeInterval(-10)
        XCTAssertEqual(SessionSummary(session: session, steps: [], now: now).duration, 0)
        XCTAssertEqual(SessionSummary(session: session, steps: [step(2, .system, "Event")], now: now).duration, 120)
    }

    func testEmptyMessageContentFallsBackToTitle() {
        let request = step(0, .user, "")
        request.title = "Request title"
        let reply = step(1, .assistant, "")
        reply.title = "Reply title"
        let summary = SessionSummary(session: makeSession(), steps: [request, reply], now: now)
        XCTAssertEqual(summary.originalRequest, "Request title")
        XCTAssertEqual(summary.finalAssistantMessage, "Reply title")
    }

    private func makeSession() -> SessionRecord {
        SessionRecord(
            sourceKey: "codex:summary", agentType: .codex, title: "Summary fixture",
            startDate: now.addingTimeInterval(-1_000), endDate: now.addingTimeInterval(-400),
            workingDirectory: "/tmp/AgentTrail", sourcePath: "/tmp/summary.jsonl",
            sourceModifiedAt: now.addingTimeInterval(-400)
        )
    }

    private func step(_ index: Int, _ kind: StepKind, _ content: String, hasError: Bool = false, path: String? = nil) -> StepRecord {
        StepRecord(
            stepIndex: index, kind: kind, timestamp: now.addingTimeInterval(-1_000 + Double(index) * 60),
            title: "Step \(index)", contentSummary: content, searchText: content,
            fullPayloadRef: nil, hasError: hasError, filePath: path
        )
    }
}
