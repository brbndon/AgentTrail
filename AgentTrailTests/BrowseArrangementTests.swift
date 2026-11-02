import Foundation
import XCTest
@testable import AgentTrail

@MainActor
final class BrowseArrangementTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSession(
        _ title: String,
        project: String = "alpha",
        updated: TimeInterval,
        started: TimeInterval = 0,
        steps: Int = 0,
        agent: AgentType = .codex
    ) -> SessionRecord {
        let projectRecord = ProjectRecord(identity: "project:\(project)", path: "/tmp/\(project)", name: project)
        let session = SessionRecord(
            sourceKey: "codex:/tmp/\(title)-\(UUID().uuidString).jsonl",
            agentType: agent,
            title: title,
            startDate: base.addingTimeInterval(started),
            endDate: nil,
            workingDirectory: "/tmp/\(project)",
            sourcePath: "/tmp/\(title).jsonl",
            sourceModifiedAt: base.addingTimeInterval(updated),
            project: projectRecord
        )
        session.steps = (0..<steps).map { index in
            StepRecord(
                stepIndex: index,
                kind: .user,
                timestamp: base,
                title: "s",
                contentSummary: "s",
                searchText: "s",
                fullPayloadRef: nil,
                hasError: false
            )
        }
        return session
    }

    private func titles(_ sessions: [SessionRecord]) -> [String] { sessions.map(\.title) }

    func testSortsByEachFieldAndDirection() {
        let a = makeSession("Alpha", updated: 30, started: 10, steps: 1)
        let b = makeSession("beta", updated: 10, started: 30, steps: 3)
        let c = makeSession("Gamma", updated: 20, started: 20, steps: 2)
        let all = [a, b, c]

        XCTAssertEqual(titles(SessionArrangement.sorted(all, by: .lastUpdated, direction: .descending)), ["Alpha", "Gamma", "beta"])
        XCTAssertEqual(titles(SessionArrangement.sorted(all, by: .lastUpdated, direction: .ascending)), ["beta", "Gamma", "Alpha"])
        XCTAssertEqual(titles(SessionArrangement.sorted(all, by: .started, direction: .descending)), ["beta", "Gamma", "Alpha"])
        XCTAssertEqual(titles(SessionArrangement.sorted(all, by: .title, direction: .ascending)), ["Alpha", "beta", "Gamma"])
        XCTAssertEqual(titles(SessionArrangement.sorted(all, by: .title, direction: .descending)), ["Gamma", "beta", "Alpha"])
        XCTAssertEqual(titles(SessionArrangement.sorted(all, by: .eventCount, direction: .descending)), ["beta", "Gamma", "Alpha"])
        XCTAssertEqual(titles(SessionArrangement.sorted(all, by: .eventCount, direction: .ascending)), ["Alpha", "Gamma", "beta"])
    }

    func testTiesFallBackToNewestUpdatedThenAreDeterministic() {
        let older = makeSession("Same", updated: 10, steps: 2)
        let newer = makeSession("Same", updated: 20, steps: 2)
        XCTAssertEqual(
            SessionArrangement.sorted([older, newer], by: .title, direction: .ascending).map(\.sourceModifiedAt),
            [newer.sourceModifiedAt, older.sourceModifiedAt]
        )
        XCTAssertEqual(
            SessionArrangement.sorted([older, newer], by: .eventCount, direction: .ascending).map(\.id),
            SessionArrangement.sorted([newer, older], by: .eventCount, direction: .ascending).map(\.id)
        )
    }

    func testFlatGroupingProducesOneHeaderlessGroup() throws {
        let sessions = [makeSession("A", project: "one", updated: 1), makeSession("B", project: "two", updated: 2)]
        let groups = SessionArrangement.groups(
            sessions: sessions, sort: .lastUpdated, direction: .descending, grouping: .flat, totalCounts: [:]
        )
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertFalse(group.showsHeader)
        XCTAssertEqual(titles(group.sessions), ["B", "A"])
    }

    func testProjectGroupingFollowsSortOrderAndUsesTotalCounts() {
        let sessions = [
            makeSession("A1", project: "one", updated: 10),
            makeSession("B1", project: "two", updated: 30),
            makeSession("A2", project: "one", updated: 20)
        ]
        let groups = SessionArrangement.groups(
            sessions: sessions, sort: .lastUpdated, direction: .descending, grouping: .project,
            totalCounts: ["project:one": 9]
        )
        XCTAssertEqual(groups.map(\.name), ["two", "one"])
        XCTAssertTrue(groups.allSatisfy(\.showsHeader))
        XCTAssertEqual(titles(groups[1].sessions), ["A2", "A1"])
        XCTAssertEqual(groups[1].totalCount, 9)

        let oldestFirst = SessionArrangement.groups(
            sessions: sessions, sort: .lastUpdated, direction: .ascending, grouping: .project, totalCounts: [:]
        )
        XCTAssertEqual(oldestFirst.map(\.name), ["one", "two"])
    }

    func testEmptyInputHasNoGroups() {
        XCTAssertTrue(SessionArrangement.groups(
            sessions: [], sort: .title, direction: .ascending, grouping: .flat, totalCounts: [:]
        ).isEmpty)
    }

    func testFilteringByQueryAndAgent() {
        let codex = makeSession("Fix login", updated: 1)
        let grok = makeSession("Fix cart", updated: 2, agent: .grokBuild)
        XCTAssertEqual(titles(SessionArrangement.filtered([codex, grok], query: "fix", agent: nil)).sorted(), ["Fix cart", "Fix login"])
        XCTAssertEqual(titles(SessionArrangement.filtered([codex, grok], query: "fix", agent: .grokBuild)), ["Fix cart"])
        XCTAssertEqual(titles(SessionArrangement.filtered([codex, grok], query: "login", agent: nil)), ["Fix login"])
        XCTAssertTrue(SessionArrangement.filtered([codex, grok], query: "zzz", agent: nil).isEmpty)
    }

    func testSelectionIsNeverAutoChosenAndClearsWhenSessionIsNoLongerLoaded() {
        let loaded = UUID()
        XCTAssertNil(SessionArrangement.reconciledSelection(current: nil, loadedIDs: [loaded]))
        XCTAssertEqual(SessionArrangement.reconciledSelection(current: loaded, loadedIDs: [loaded]), loaded)
        XCTAssertNil(SessionArrangement.reconciledSelection(current: UUID(), loadedIDs: [loaded]))
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "BrowseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testPreferencesDefaultToTodaysBehavior() {
        let preferences = BrowsePreferences(defaults: isolatedDefaults())
        XCTAssertEqual(preferences.sortField, .lastUpdated)
        XCTAssertEqual(preferences.sortDirection, .descending)
        XCTAssertEqual(preferences.grouping, .project)
        XCTAssertEqual(preferences.layout, .classic)
        XCTAssertEqual(preferences.sortSummary, "Last updated · Newest first")
    }

    func testPreferencesPersistAndSelectingFieldResetsDirection() {
        let defaults = isolatedDefaults()
        let preferences = BrowsePreferences(defaults: defaults)
        preferences.select(sortField: .title)
        XCTAssertEqual(preferences.sortDirection, .ascending)
        XCTAssertEqual(preferences.sortSummary, "Title · A to Z")
        preferences.sortDirection = .descending
        preferences.grouping = .flat
        preferences.layout = .dashboard

        let reloaded = BrowsePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.sortField, .title)
        XCTAssertEqual(reloaded.sortDirection, .descending)
        XCTAssertEqual(reloaded.grouping, .flat)
        XCTAssertEqual(reloaded.layout, .dashboard)

        reloaded.select(sortField: .eventCount)
        XCTAssertEqual(reloaded.sortDirection, .descending)
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        let defaults = isolatedDefaults()
        defaults.set("bogus", forKey: "BrowseSortField")
        defaults.set("bogus", forKey: "BrowseGrouping")
        defaults.set("bogus", forKey: "AppLayoutStyle")
        let preferences = BrowsePreferences(defaults: defaults)
        XCTAssertEqual(preferences.sortField, .lastUpdated)
        XCTAssertEqual(preferences.grouping, .project)
        XCTAssertEqual(preferences.layout, .classic)
    }
}
