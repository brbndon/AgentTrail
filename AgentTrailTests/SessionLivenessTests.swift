import Foundation
import XCTest
@testable import AgentTrail

final class SessionLivenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testZeroAnd179SecondsAreLive() {
        XCTAssertTrue(isLive(age: 0))
        XCTAssertTrue(isLive(age: 179))
    }

    func test180And181SecondsAreNotLive() {
        XCTAssertFalse(isLive(age: 180))
        XCTAssertFalse(isLive(age: 181))
    }

    func testFutureModificationIsNotLive() {
        XCTAssertFalse(
            SessionLiveness.isRecentlyWriting(
                sourceModifiedAt: now.addingTimeInterval(1),
                isBranch: false,
                agentType: .codex,
                sourceState: .scanned,
                now: now
            )
        )
    }

    func testBranchIsNotLiveEvenIfJustWritten() {
        let session = SessionRecord(
            sourceKey: "branch:\(UUID().uuidString.lowercased())",
            agentType: .codex,
            title: "Fork",
            startDate: now,
            endDate: nil,
            workingDirectory: "/tmp",
            sourcePath: "/tmp/session.jsonl",
            sourceModifiedAt: now,
            status: .recording
        )
        XCTAssertTrue(session.isBranch)
        XCTAssertFalse(SessionLiveness.isRecentlyWriting(session, now: now))
    }

    func testNonCodexAgentIsNotLive() {
        XCTAssertFalse(
            SessionLiveness.isRecentlyWriting(
                sourceModifiedAt: now,
                isBranch: false,
                agentType: .cursor,
                sourceState: .scanned,
                now: now
            )
        )
    }

    func testUnavailableSourceIsNotLive() {
        XCTAssertFalse(
            SessionLiveness.isRecentlyWriting(
                sourceModifiedAt: now,
                isBranch: false,
                agentType: .codex,
                sourceState: .unavailable,
                now: now
            )
        )
    }

    func testDegradedRecentlyWrittenSessionIsLive() {
        XCTAssertTrue(
            SessionLiveness.isRecentlyWriting(
                sourceModifiedAt: now.addingTimeInterval(-30),
                isBranch: false,
                agentType: .codex,
                sourceState: .degraded,
                now: now
            )
        )
    }

    func testRecordingStatusWithStaleMtimeIsNotLive() {
        let session = SessionRecord(
            sourceKey: "codex:stale-recording",
            agentType: .codex,
            title: "Stale",
            startDate: now.addingTimeInterval(-1_000),
            endDate: nil,
            workingDirectory: "/tmp",
            sourcePath: "/tmp/stale.jsonl",
            sourceModifiedAt: now.addingTimeInterval(-1_000),
            status: .recording
        )
        XCTAssertEqual(session.status, .recording)
        XCTAssertFalse(SessionLiveness.isRecentlyWriting(session, now: now))
    }

    func testSliceSortsNewestFirstAndCapsAt20() {
        let sessions = (0..<21).map { index in
            SessionRecord(
                sourceKey: "codex:live-\(index)",
                agentType: .codex,
                title: "Thread \(index)",
                startDate: now,
                endDate: nil,
                workingDirectory: "/tmp",
                sourcePath: "/tmp/\(index).jsonl",
                sourceModifiedAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let slice = SessionLiveness.slice(from: sessions, now: now.addingTimeInterval(21))
        XCTAssertEqual(slice.sessions.count, 20)
        XCTAssertEqual(slice.overflowCount, 1)
        XCTAssertEqual(slice.sessions.first?.title, "Thread 20")
        XCTAssertEqual(slice.sessions.last?.title, "Thread 1")
    }

    func testStatusItemCopy() {
        XCTAssertEqual(SessionLiveness.extraSymbolName(liveCount: 0), "circle.dashed")
        XCTAssertEqual(SessionLiveness.extraSymbolName(liveCount: 2), "record.circle")
        XCTAssertEqual(SessionLiveness.extraAccessibilityLabel(liveCount: 0), "No live Codex sessions")
        XCTAssertEqual(SessionLiveness.extraAccessibilityLabel(liveCount: 1), "1 live Codex session")
        XCTAssertEqual(SessionLiveness.extraAccessibilityLabel(liveCount: 3), "3 live Codex sessions")
    }

    func testLibraryAccessIssueMenuExplanationMatchesWindowCopy() {
        let owned = LibraryAccessIssue.ownedByAnotherProcess(nil)
        XCTAssertEqual(
            owned.menuExplanation,
            "Another AgentTrail copy is using this library. Only one copy can import or edit it at a time."
        )
        let unavailable = LibraryAccessIssue.unavailable("The AgentTrail folder in Application Support is not usable.")
        XCTAssertEqual(unavailable.menuExplanation, "The AgentTrail folder in Application Support is not usable.")
    }

    func testMenuItemTitleOmitsPathsAndUsesProjectAndCount() {
        let project = ProjectRecord(identity: "path:/tmp/Demo", path: "/tmp/Demo", name: "Demo")
        let session = SessionRecord(
            sourceKey: "codex:title",
            agentType: .codex,
            title: "Repair ingestion",
            startDate: now,
            endDate: nil,
            workingDirectory: "/tmp/Demo",
            sourcePath: "/tmp/Demo/session.jsonl",
            sourceModifiedAt: now,
            project: project
        )
        let title = LiveSessionsMenu.itemTitle(for: session, now: now)
        XCTAssertEqual(title, "Repair ingestion — Demo · 0 events")
        XCTAssertFalse(title.contains("/tmp"))
        XCTAssertFalse(title.contains("session.jsonl"))
    }

    @MainActor
    func testOpenSessionFromMenuBarSetsSelectionWithoutRefreshing() {
        let appStore = AppStore()
        let id = UUID()
        XCTAssertNil(appStore.selectedSessionID)
        appStore.openSessionFromMenuBar(id)
        XCTAssertEqual(appStore.selectedSessionID, id)
        XCTAssertFalse(appStore.isLoading)
    }

    @MainActor
    func testAppStoreTracksLiveCountFromLoadedSessions() {
        let appStore = AppStore()
        let session = SessionRecord(
            sourceKey: "codex:live-count",
            agentType: .codex,
            title: "Live",
            startDate: now,
            endDate: nil,
            workingDirectory: "/tmp",
            sourcePath: "/tmp/live.jsonl",
            sourceModifiedAt: now
        )

        appStore.updateLiveSessionCount(from: [session], now: now)
        XCTAssertEqual(appStore.liveSessionCount, 1)

        appStore.updateLiveSessionCount(from: [session], now: now.addingTimeInterval(SessionLiveness.recency))
        XCTAssertEqual(appStore.liveSessionCount, 0)
    }

    private func isLive(age: TimeInterval) -> Bool {
        SessionLiveness.isRecentlyWriting(
            sourceModifiedAt: now.addingTimeInterval(-age),
            isBranch: false,
            agentType: .codex,
            sourceState: .scanned,
            now: now
        )
    }
}
