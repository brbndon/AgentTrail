@testable import AgentTrail
import Foundation
import XCTest

final class TimelineTurnTests: XCTestCase {
    func testEmptyAndWorkBeforeFirstUser() {
        XCTAssertTrue(TimelineTurn.group(orderedSteps: []).isEmpty)
        let setup = step(0, .system)
        let request = step(1, .user)
        let turns = TimelineTurn.group(orderedSteps: [setup, request])
        XCTAssertEqual(turns.map(\.id), [setup.id, request.id])
        XCTAssertFalse(turns[0].blocks[0].isMessage)
        XCTAssertTrue(turns[1].blocks[0].isMessage)
    }

    func testConsecutiveUsersStartSeparateTurnsAndTrailingWorkNeedsNoReply() {
        let first = step(0, .user)
        let second = step(1, .user)
        let command = step(2, .shellCommand)
        let turns = TimelineTurn.group(orderedSteps: [first, second, command])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].blocks.count, 1)
        XCTAssertEqual(turns[1].blocks.count, 2)
        XCTAssertEqual(turns[1].blocks.last?.steps.map(\.id), [command.id])
    }

    func testMessagesStayInOrderAndWorkFoldsIntoContiguousBlocksWithErrors() {
        let events = [step(0, .user), step(1, .thought), step(2, .shellCommand), step(3, .assistant), step(4, .toolResult)]
        events[2].hasError = true
        events[2].filePath = "Sources/App.swift"
        events[2].fileChanges = [FileChangeRecord(path: "Sources/App.swift", changeType: "modified")]
        let blocks = TimelineTurn.group(orderedSteps: events)[0].blocks
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.flatMap(\.steps).map(\.id), events.map(\.id))
        XCTAssertTrue(blocks[1].hasError)
        XCTAssertTrue(blocks[1].summary.contains("Ran 1 command"))
        XCTAssertTrue(blocks[1].summary.contains("1 file"))
        XCTAssertTrue(blocks[1].summary.contains("1 error"))
    }

    func testFilteringPreservesTurnBoundariesAndFindsSelectionInHiddenWork() {
        let events = [step(0, .user), step(1, .shellCommand), step(2, .user), step(3, .toolResult)]
        let turns = TimelineTurn.group(orderedSteps: events)
        let visible = Set([events[1].id, events[3].id])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].blocks.flatMap { $0.matchingSteps(visible) }.map(\.id), [events[1].id])
        XCTAssertEqual(TimelineTurn.workBlockID(containing: events[3].id, in: turns, visibleIDs: visible), events[3].id)
        XCTAssertNil(TimelineTurn.workBlockID(containing: events[0].id, in: turns, visibleIDs: visible))
        XCTAssertNil(TimelineTurn.workBlockID(containing: events[3].id, in: turns, visibleIDs: []))
    }

    func testSelectionKeepsVisibleStepOtherwiseFallsBackToFirstVisible() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(TimelineSelection.reconciled(current: ids[1], matchingIDs: ids), ids[1])
        XCTAssertEqual(TimelineSelection.reconciled(current: ids[0], matchingIDs: [ids[1], ids[2]]), ids[1])
        XCTAssertEqual(TimelineSelection.reconciled(current: nil, matchingIDs: ids), ids[0])
        XCTAssertNil(TimelineSelection.reconciled(current: ids[0], matchingIDs: []))
    }

    func testFilteredSelectionStillMapsToItsWorkBlockForAutoExpansion() {
        let events = [step(0, .user), step(1, .shellCommand), step(2, .shellCommand), step(3, .assistant), step(4, .shellCommand)]
        events[2].hasError = true
        let turns = TimelineTurn.group(orderedSteps: events)
        let visible = Set(events.filter { $0.hasError }.map(\.id))
        let blockID = TimelineTurn.workBlockID(containing: events[2].id, in: turns, visibleIDs: visible)
        XCTAssertEqual(blockID, events[1].id, "The folded block is keyed by its first step even when that step is filtered out")
        let block = turns.flatMap(\.blocks).first { $0.id == blockID }
        XCTAssertEqual(block?.matchingSteps(visible).map(\.id), [events[2].id])
        XCTAssertEqual(block?.hasError, true)
        XCTAssertNil(TimelineTurn.workBlockID(containing: events[4].id, in: turns, visibleIDs: visible))
    }

    private func step(_ index: Int, _ kind: StepKind) -> StepRecord {
        StepRecord(
            stepIndex: index, kind: kind, timestamp: .now, title: kind.displayName, contentSummary: "Message", searchText: "",
            fullPayloadRef: nil, hasError: false)
    }
}
