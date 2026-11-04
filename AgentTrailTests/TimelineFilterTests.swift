@testable import AgentTrail
import Foundation
import XCTest

final class TimelineFilterTests: XCTestCase {
    func testPresetKindSetsAndErrorFlags() {
        for kind in StepKind.allCases {
            let step = makeStep(kind)
            XCTAssertTrue(TimelineFilter(preset: .all).matches(step))
            XCTAssertEqual(TimelineFilter(preset: .messages).matches(step), [.user, .assistant].contains(kind))
            XCTAssertEqual(TimelineFilter(preset: .actions).matches(step), [.toolCall, .toolResult, .fileChange, .shellCommand].contains(kind))
            XCTAssertFalse(TimelineFilter(preset: .errors).matches(step))
            step.hasError = true
            XCTAssertTrue(TimelineFilter(preset: .errors).matches(step))
        }
    }

    func testPresetsComposeWithOtherFiltersAndReset() {
        let step = makeStep(.shellCommand)
        step.filePath = "Sources/App.swift"
        var filter = TimelineFilter(preset: .actions, query: "command", filePathQuery: "Sources")
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(step))
        filter.query = "missing"
        XCTAssertFalse(filter.matches(step))
        filter.reset()
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.preset, .all)
    }

    func testErrorNavigationIgnoresCategoryPreset() {
        let step = makeStep(.shellCommand)
        step.hasError = true
        let index = TimelineErrorIndex(orderedSteps: [step], filter: TimelineFilter(preset: .messages))
        XCTAssertEqual(index.errorIDs, [step.id])
    }

    func testElapsedTimeFormatting() {
        let start = Date(timeIntervalSince1970: 0)
        for (seconds, expected) in [(-1, "+0s"), (0, "+0s"), (59, "+59s"), (134, "+2m 14s"), (3_661, "+1h 1m 1s")] {
            XCTAssertEqual(TimelineElapsedTime.label(timestamp: start.addingTimeInterval(Double(seconds)), sessionStart: start), expected)
        }
    }

    private func makeStep(_ kind: StepKind) -> StepRecord {
        StepRecord(
            stepIndex: 0, kind: kind, timestamp: .now, title: "Command", contentSummary: "Output", searchText: "command",
            fullPayloadRef: nil, hasError: false)
    }
}
