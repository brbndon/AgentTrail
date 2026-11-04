@testable import AgentTrail
import Foundation
import XCTest

final class TimelineErrorIndexTests: XCTestCase {
    func testEmptyAndErrorFreeIndexesHaveNoDestination() {
        for steps in [[], [step(0)]] {
            let index = TimelineErrorIndex(orderedSteps: steps, filter: TimelineFilter())
            XCTAssertTrue(index.errorIDs.isEmpty)
            XCTAssertNil(index.destination(from: nil, direction: .next))
            XCTAssertNil(index.destination(from: nil, direction: .previous))
        }
    }

    func testNavigatesInEventOrderFromErrorsAndNonErrorsAndWraps() {
        let steps = [step(0), step(1, error: true), step(2), step(3, error: true), step(4)]
        let index = TimelineErrorIndex(orderedSteps: steps, filter: TimelineFilter())
        XCTAssertEqual(index.errorIDs, [steps[1].id, steps[3].id])
        XCTAssertEqual(index.destination(from: steps[1].id, direction: .next), steps[3].id)
        XCTAssertEqual(index.destination(from: steps[3].id, direction: .previous), steps[1].id)
        XCTAssertEqual(index.destination(from: steps[2].id, direction: .next), steps[3].id)
        XCTAssertEqual(index.destination(from: steps[2].id, direction: .previous), steps[1].id)
        XCTAssertEqual(index.destination(from: steps[4].id, direction: .next), steps[1].id)
        XCTAssertEqual(index.destination(from: steps[0].id, direction: .previous), steps[3].id)
        XCTAssertEqual(index.destination(from: steps[3].id, direction: .next), steps[1].id)
        XCTAssertEqual(index.destination(from: steps[1].id, direction: .previous), steps[3].id)
    }

    func testMissingSelectionAndSingleError() {
        let error = step(0, error: true)
        let index = TimelineErrorIndex(orderedSteps: [error], filter: TimelineFilter())
        XCTAssertEqual(index.destination(from: nil, direction: .next), error.id)
        XCTAssertEqual(index.destination(from: UUID(), direction: .previous), error.id)
        XCTAssertEqual(index.destination(from: error.id, direction: .next), error.id)
        XCTAssertEqual(index.destination(from: error.id, direction: .previous), error.id)
    }

    func testIgnoresKindWhileRetainingSearchPathAndDateFilters() {
        let matching = step(0, error: true)
        matching.filePath = "Sources/App.swift"
        let otherPath = step(1, error: true)
        otherPath.filePath = "Tests/AppTests.swift"
        let otherQuery = step(2, error: true)
        otherQuery.filePath = matching.filePath
        otherQuery.searchText = "unrelated"
        let old = step(3, error: true)
        old.filePath = matching.filePath
        old.timestamp = .distantPast
        let filter = TimelineFilter(
            query: "failure", kindRawValue: StepKind.user.rawValue,
            filePathQuery: "Sources/", dateRange: .today)
        let index = TimelineErrorIndex(orderedSteps: [matching, otherPath, otherQuery, old], filter: filter)
        XCTAssertEqual(index.errorIDs, [matching.id])
        XCTAssertFalse(filter.matches(matching))
        var revealedFilter = filter
        revealedFilter.kindRawValue = "all"
        XCTAssertTrue(revealedFilter.matches(matching))
    }

    func testFilePathFilterFindsPathsStoredOnlyInFileChanges() {
        let changed = step(0, error: true)
        changed.fileChanges = [FileChangeRecord(path: "Sources/Feature.swift", changeType: "modified")]
        let filter = TimelineFilter(filePathQuery: "sources/feature.swift")
        XCTAssertTrue(filter.matches(changed))
        XCTAssertEqual(TimelineErrorIndex(orderedSteps: [changed], filter: filter).errorIDs, [changed.id])
        XCTAssertFalse(TimelineFilter(filePathQuery: "Missing.swift").matches(changed))
    }

    private func step(_ index: Int, error: Bool = false) -> StepRecord {
        StepRecord(
            stepIndex: index, kind: .shellCommand, timestamp: .now, title: "Command",
            contentSummary: "Output", searchText: "failure", fullPayloadRef: nil, hasError: error)
    }
}
