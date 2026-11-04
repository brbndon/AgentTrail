@testable import AgentTrail
import Foundation
import XCTest

@MainActor
final class SessionSummaryCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRepeatedLookupsAndLiveTicksDoNotRescanSteps() async throws {
        var scans = 0
        let cache = SessionSummaryCache { session in
            scans += 1
            return SessionSummary(session: session, steps: session.steps, now: .distantFuture)
        }
        let session = makeSession(0)
        session.sourceModifiedAt = now
        session.steps[0].hasError = true
        await cache.prepare([session])
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(cache.summary(for: session, now: now)?.outcome, .running)
        XCTAssertEqual(cache.summary(for: session, now: now)?.duration, 1_000)
        for _ in 0..<100 {
            await cache.prepare([session])
            XCTAssertNotNil(cache.summary(for: session, now: now.addingTimeInterval(179)))
        }
        XCTAssertEqual(scans, 1)
        let expired = try XCTUnwrap(cache.summary(for: session, now: now.addingTimeInterval(180)))
        XCTAssertEqual(expired.outcome, .hasErrors(1))
        XCTAssertEqual(expired.duration, 600)
        XCTAssertEqual(cache.needsAttention(in: [session]), 1)
    }

    func testInvalidationCoversSameTimestampReconciliationAndMetadataUpdates() async {
        var scans = 0
        let cache = SessionSummaryCache { session in
            scans += 1
            return SessionSummary(session: session, steps: session.steps, now: .distantFuture)
        }
        let session = makeSession(0)
        await cache.prepare([session])
        let before = cache.request(for: [session])
        session.steps[0].hasError = true
        cache.invalidate(session.id)
        XCTAssertNotEqual(cache.request(for: [session]), before)
        XCTAssertNil(cache.summary(for: session, now: now))
        await cache.prepare([session])
        XCTAssertEqual(cache.summary(for: session, now: now)?.errorCount, 1)
        session.sourceModifiedAt = now.addingTimeInterval(-300)
        XCTAssertNil(cache.summary(for: session, now: now))
        await cache.prepare([session])
        XCTAssertEqual(scans, 3)
        await cache.prepare([])
        XCTAssertNil(cache.summary(for: session, now: now))
    }

    func testDefaultPageCostAndWarmCacheReuse() async {
        let sessions = (0..<AppStore.sessionPageSize).map { makeSession($0, eventCount: 500) }
        var scans = 0
        let cache = SessionSummaryCache { session in
            scans += 1
            return SessionSummary(session: session, steps: session.steps, now: .distantFuture)
        }
        let clock = ContinuousClock()
        let start = clock.now
        await cache.prepare(sessions)
        let cold = start.duration(to: clock.now)
        let warmStart = clock.now
        for _ in 0..<100 {
            for session in sessions { _ = cache.summary(for: session, now: now) }
        }
        await cache.prepare(sessions)
        let warm = warmStart.duration(to: clock.now)
        XCTAssertEqual(scans, AppStore.sessionPageSize)
        XCTAssertEqual(cache.needsAttention(in: sessions), 0)
        print("Summary cache: 30 sessions × 500 events, cold \(cold), 3,000 warm reads \(warm), \(scans) full scans total")
    }

    private func makeSession(_ index: Int, eventCount: Int = 1) -> SessionRecord {
        let session = SessionRecord(
            sourceKey: "test:cache:\(index)", agentType: .codex, title: "Session \(index)",
            startDate: now.addingTimeInterval(-1_000), endDate: now.addingTimeInterval(-400),
            workingDirectory: "/tmp/AgentTrail", sourcePath: "/tmp/cache-\(index).jsonl",
            sourceModifiedAt: now.addingTimeInterval(-400))
        session.steps = (0..<eventCount).map { offset in
            StepRecord(
                stepIndex: offset, kind: .assistant, timestamp: session.startDate, title: "Reply", contentSummary: "Completed work",
                searchText: "", fullPayloadRef: nil, hasError: false)
        }
        return session
    }
}
