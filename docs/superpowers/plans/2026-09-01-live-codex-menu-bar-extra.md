# Live Codex Menu Bar Extra Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a companion SwiftUI `MenuBarExtra` that lists Codex sessions whose JSONL files were written in the last 3 minutes and jumps the main AgentTrail window to the chosen session.

**Architecture:** Liveness is a pure derived helper (`SessionLiveness`) over imported `SessionRecord.sourceModifiedAt`, not a stored status. The extra and the sidebar Live badge both call that helper. Clicking a row sets `AppStore.selectedSessionID` and fronts the existing `WindowGroup`. The extra is omitted in the XCTest host.

**Tech Stack:** Swift 6, SwiftUI `MenuBarExtra` (`.menu` style), SwiftData `@Query`, `TimelineView`, XCTest, XcodeGen-generated `AgentTrail.xcodeproj`.

## Global Constraints

- macOS 15.0+, Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`
- Companion extra only: no `LSUIElement`, no accessory activation policy, closing the main window still quits
- Liveness: Codex, non-branch, `sourceState != .unavailable`, `sourceModifiedAt <= now`, age `< 180` seconds
- Do not change `JSONLineSupport.sessionStatus` or Codex fixtures
- No new SwiftData fields, settings toggle, notifications, or second filesystem watcher
- Extra omitted when `AgentTrailRuntime.isTestHost == true`
- Privacy: menu shows title, project name, relative time, event count only
- New files under `AgentTrail/` / `AgentTrailTests/` require `xcodegen generate` because the checked-in pbxproj lists files explicitly
- Do not stage, revert, or edit the pre-existing dirty files (`CodexCheckpointStore.swift`, `CodexSessionParser.swift`, `TracePayload.swift`, `ApplicationSupportLease.swift`, `ParserTests.swift`)
- Spec: `docs/superpowers/specs/2026-09-01-live-codex-menu-bar-extra-design.md`

## File structure

- Create: `AgentTrail/Models/SessionLiveness.swift` — pure liveness + menu slice + status-item copy
- Create: `AgentTrail/Views/LiveSessionsMenu.swift` — extra menu, unavailable menu, status-item label
- Create: `AgentTrailTests/SessionLivenessTests.swift` — frozen-date unit tests
- Modify: `AgentTrail/State/AppStore.swift` — `openSessionFromMenuBar`, `bringMainWindowForward`
- Modify: `AgentTrail/Views/SessionsListView.swift` — Live badge uses `SessionLiveness`
- Modify: `AgentTrail/AgentTrailApp.swift` — `MenuBarExtra` scene
- Modify: `AgentTrail/Views/LibraryUnavailableView.swift` — `LibraryAccessIssue.menuExplanation` lives here so the extra and the window share copy without editing the lease file
- Modify: `README.md` — one Current experience bullet
- Regenerate: `AgentTrail.xcodeproj` via `xcodegen generate`
- Do not modify `ParserTests.swift` or `ApplicationSupportLease.swift` for this feature (both may already have unrelated local changes)

---

### Task 1: SessionLiveness helper

**Files:**
- Create: `AgentTrailTests/SessionLivenessTests.swift`
- Create: `AgentTrail/Models/SessionLiveness.swift`
- Regenerate: `AgentTrail.xcodeproj` (XcodeGen)

**Interfaces:**
- Consumes: `AgentType`, `SessionSourceState`, `SessionStatus`, `SessionRecord`
- Produces:
  - `enum SessionLiveness`
  - `static let recency: TimeInterval = 180`
  - `static let tickInterval: TimeInterval = 15`
  - `static let menuLimit = 20`
  - `static func isRecentlyWriting(sourceModifiedAt: Date, isBranch: Bool, agentType: AgentType, sourceState: SessionSourceState, now: Date) -> Bool`
  - `static func isRecentlyWriting(_ session: SessionRecord, now: Date) -> Bool`
  - `static func slice(from sessions: [SessionRecord], now: Date) -> (sessions: [SessionRecord], overflowCount: Int)`
  - `static func extraSymbolName(liveCount: Int) -> String`
  - `static func extraAccessibilityLabel(liveCount: Int) -> String`

- [ ] **Step 1: Write the failing tests**

Create `AgentTrailTests/SessionLivenessTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

From the repo root:

```bash
xcodegen generate
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests/SessionLivenessTests
```

Expected: FAIL / compile error `cannot find 'SessionLiveness' in scope`.

- [ ] **Step 3: Write the helper**

Create `AgentTrail/Models/SessionLiveness.swift`:

```swift
import Foundation

enum SessionLiveness {
    static let recency: TimeInterval = 180
    static let tickInterval: TimeInterval = 15
    static let menuLimit = 20

    static func isRecentlyWriting(
        sourceModifiedAt: Date,
        isBranch: Bool,
        agentType: AgentType,
        sourceState: SessionSourceState,
        now: Date
    ) -> Bool {
        guard agentType == .codex, !isBranch, sourceState != .unavailable else { return false }
        let age = now.timeIntervalSince(sourceModifiedAt)
        return age >= 0 && age < recency
    }

    static func isRecentlyWriting(_ session: SessionRecord, now: Date) -> Bool {
        isRecentlyWriting(
            sourceModifiedAt: session.sourceModifiedAt,
            isBranch: session.isBranch,
            agentType: session.agentType,
            sourceState: session.sourceState,
            now: now
        )
    }

    static func slice(from sessions: [SessionRecord], now: Date) -> (sessions: [SessionRecord], overflowCount: Int) {
        let live = sessions
            .filter { isRecentlyWriting($0, now: now) }
            .sorted { lhs, rhs in
                if lhs.sourceModifiedAt != rhs.sourceModifiedAt {
                    return lhs.sourceModifiedAt > rhs.sourceModifiedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        if live.count <= menuLimit {
            return (live, 0)
        }
        return (Array(live.prefix(menuLimit)), live.count - menuLimit)
    }

    static func extraSymbolName(liveCount: Int) -> String {
        liveCount == 0 ? "circle.dashed" : "record.circle"
    }

    static func extraAccessibilityLabel(liveCount: Int) -> String {
        switch liveCount {
        case 0: "No live Codex sessions"
        case 1: "1 live Codex session"
        default: "\(liveCount) live Codex sessions"
        }
    }
}
```

- [ ] **Step 4: Regenerate the Xcode project and run tests**

```bash
xcodegen generate
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests/SessionLivenessTests
```

Expected: PASS, all `SessionLivenessTests` green.

- [ ] **Step 5: Commit**

```bash
git add AgentTrail/Models/SessionLiveness.swift AgentTrailTests/SessionLivenessTests.swift AgentTrail.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(menu-bar): add derived Codex session liveness

- Treat sessions as live when Codex JSONL mtime is under 180s
EOF
)"
```

---

### Task 2: Open session from the menu bar

**Files:**
- Modify: `AgentTrail/State/AppStore.swift`
- Modify: `AgentTrailTests/SessionLivenessTests.swift`

**Interfaces:**
- Consumes: `AppStore.selectedSessionID`, `AgentTrailRuntime.isTestHost`
- Produces:
  - `func openSessionFromMenuBar(_ id: UUID)`
  - `func bringMainWindowForward()`
  - `bringMainWindowForward()` is a no-op when `AgentTrailRuntime.isTestHost` is true so unit tests never touch `NSStatusItem` / do not assert `NSApp` activation

- [ ] **Step 1: Write the failing test**

In `AgentTrailTests/SessionLivenessTests.swift`, add:

```swift
    @MainActor
    func testOpenSessionFromMenuBarSetsSelectionWithoutRefreshing() {
        let appStore = AppStore()
        let id = UUID()
        XCTAssertNil(appStore.selectedSessionID)
        appStore.openSessionFromMenuBar(id)
        XCTAssertEqual(appStore.selectedSessionID, id)
        XCTAssertFalse(appStore.isLoading)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests/SessionLivenessTests/testOpenSessionFromMenuBarSetsSelectionWithoutRefreshing
```

Expected: FAIL with `Value of type 'AppStore' has no member 'openSessionFromMenuBar'`.

- [ ] **Step 3: Implement AppStore methods**

Add `import AppKit` at the top of `AgentTrail/State/AppStore.swift` (keep existing `Foundation`, `Observation`, `SwiftData`, `os` imports).

Add these methods on `AppStore` immediately after `func loadMoreSessions()`:

```swift
    func openSessionFromMenuBar(_ id: UUID) {
        selectedSessionID = id
        bringMainWindowForward()
    }

    func bringMainWindowForward() {
        guard !AgentTrailRuntime.isTestHost else { return }
        NSApp.activate()
        let window = NSApp.windows.first(where: \.isMiniaturized)
            ?? NSApp.windows.first(where: { $0.canBecomeMain })
            ?? NSApp.windows.first
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
```

Do not call `refresh()` from these methods. Do not open a second window.

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests/SessionLivenessTests/testOpenSessionFromMenuBarSetsSelectionWithoutRefreshing
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add AgentTrail/State/AppStore.swift AgentTrailTests/SessionLivenessTests.swift
git commit -m "$(cat <<'EOF'
feat(menu-bar): select a session from the extra

- openSessionFromMenuBar sets selection and fronts the main window
EOF
)"
```

---

### Task 3: Sidebar Live badge uses SessionLiveness

**Files:**
- Modify: `AgentTrail/Views/SessionsListView.swift` (`SessionRowView` around the current `session.status == .recording` block, and `SessionsListView.body`)

**Interfaces:**
- Consumes: `SessionLiveness.isRecentlyWriting(_:now:)`, `SessionLiveness.tickInterval`
- Produces: sidebar “Live” badge and accessibility string derived from liveness, not `SessionStatus.recording`. Degraded still renders first.

- [ ] **Step 1: Wrap the session list in a 15s TimelineView and pass `now`**

In `SessionsListView.body`, replace the `List(selection: $selection) { ... }` with:

```swift
Replace the `List` through `.onChange(of: sessions.map(\.id))` chain with:

```swift
        TimelineView(.periodic(from: .now, by: SessionLiveness.tickInterval)) { context in
            List(selection: $selection) {
                ForEach(projectGroups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            SessionRowView(session: session, now: context.date)
                                .tag(session.id)
                        }
                    } header: {
                        ProjectSectionHeader(name: group.name, sessionCount: group.totalCount)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .searchable(text: $appStore.sidebarSearch, placement: .sidebar, prompt: "Search sessions")
        .safeAreaInset(edge: .top) {
            Picker("Agent", selection: $appStore.agentFilter) {
                Text("All agents").tag(AgentType?.none)
                ForEach(AgentType.allCases) { agentType in
                    Text(agentType.displayName).tag(AgentType?.some(agentType))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            DiscoveryStatusBar(
                message: appStore.statusMessage,
                isLoading: appStore.isLoading,
                progress: appStore.ingestionProgress,
                visibleCount: sessions.count,
                totalCount: appStore.totalAvailableSessionCount,
                hasMoreSessions: appStore.hasMoreSessions,
                loadMore: appStore.loadMoreSessions
            )
        }
        .navigationTitle("Sessions")
        .onAppear { reconcileSelection() }
        .onChange(of: appStore.sidebarSearch) { _, _ in reconcileSelection() }
        .onChange(of: appStore.agentFilter) { _, _ in reconcileSelection() }
        .onChange(of: sessions.map(\.id)) { _, _ in reconcileSelection() }
```

Leave the `@Bindable var appStore = appStore` line above this chain. Do not move `.searchable` inside `SessionRowView`.

- [ ] **Step 2: Update `SessionRowView` to take `now` and use liveness**

Replace `private struct SessionRowView` with:

```swift
private struct SessionRowView: View {
    let session: SessionRecord
    let now: Date

    private var isLive: Bool {
        SessionLiveness.isRecentlyWriting(session, now: now)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.agentType.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text("Updated \(session.sourceModifiedAt, style: .relative)")
                    Text("·")
                    Text("\(session.stepCount) events")
                    if session.sourceState == .degraded {
                        Text("·")
                        Label("Degraded", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if isLive {
                        Text("·")
                        Label("Live", systemImage: "record.circle")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                session.agentType.displayName,
                session.project?.name ?? "Unknown project",
                session.title,
                "\(session.stepCount) events",
                session.sourceState == .degraded ? "Degraded" : nil,
                session.sourceState != .degraded && isLive ? "Live" : nil,
                session.isPinned ? "Pinned" : nil
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }
}
```

Do not show Live and Degraded at the same time. Do not use `session.status == .recording`.

- [ ] **Step 3: Run liveness tests plus project-grouping test**

```bash
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests/SessionLivenessTests
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add AgentTrail/Views/SessionsListView.swift
git commit -m "$(cat <<'EOF'
fix(sessions): show Live from recent writes

- Sidebar badge uses SessionLiveness instead of the 10s recording flag
EOF
)"
```

---

### Task 4: Menu extra views

**Files:**
- Create: `AgentTrail/Views/LiveSessionsMenu.swift`
- Modify: `AgentTrail/Views/LibraryUnavailableView.swift` (`LibraryAccessIssue.menuExplanation` extension + `message`)
- Modify: `AgentTrailTests/SessionLivenessTests.swift`
- Regenerate: `AgentTrail.xcodeproj`

**Interfaces:**
- Consumes: `SessionLiveness.slice`, `SessionLiveness.extraSymbolName`, `SessionLiveness.extraAccessibilityLabel`, `AppStore.openSessionFromMenuBar`, `AppStore.bringMainWindowForward`, `AppStore.refresh`, `AppStore.loadedSessionLimit`
- Produces:
  - `struct LiveSessionsMenu: View` — `init(limit: Int)`
  - `struct LiveSessionsStatusLabel: View` — `init(limit: Int)`
  - `struct LiveSessionsUnavailableMenu: View` — `init(explanation: String, onOpen: @escaping () -> Void)`
  - `LibraryAccessIssue.menuExplanation: String` — same strings `LibraryUnavailableView` currently uses for `message`

- [ ] **Step 1: Add `menuExplanation` and a failing assertion**

In `AgentTrailTests/SessionLivenessTests.swift`, add:

```swift
    func testLibraryAccessIssueMenuExplanationMatchesWindowCopy() {
        let owned = LibraryAccessIssue.ownedByAnotherProcess(nil)
        XCTAssertEqual(
            owned.menuExplanation,
            "Another AgentTrail copy is using this library. Only one copy can import or edit it at a time."
        )
        let unavailable = LibraryAccessIssue.unavailable("The AgentTrail folder in Application Support is not usable.")
        XCTAssertEqual(unavailable.menuExplanation, "The AgentTrail folder in Application Support is not usable.")
    }
```

- [ ] **Step 2: Run the new test to verify it fails**

```bash
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests/SessionLivenessTests/testLibraryAccessIssueMenuExplanationMatchesWindowCopy
```

Expected: FAIL with `Value of type 'LibraryAccessIssue' has no member 'menuExplanation'`.

- [ ] **Step 3: Add `menuExplanation` on `LibraryAccessIssue` next to the window copy**

In `AgentTrail/Views/LibraryUnavailableView.swift`, replace the `message` computed property with:

```swift
    private var message: String { issue.menuExplanation }
```

Append this extension at the bottom of the same file:

```swift
extension LibraryAccessIssue {
    var menuExplanation: String {
        switch self {
        case .ownedByAnotherProcess(let owner):
            if let owner {
                "Another AgentTrail \(owner.copyDescription) is using this library. Only one copy can import or edit it at a time."
            } else {
                "Another AgentTrail copy is using this library. Only one copy can import or edit it at a time."
            }
        case .unavailable(let message):
            message
        }
    }
}
```

- [ ] **Step 4: Create the extra views**

Create `AgentTrail/Views/LiveSessionsMenu.swift`:

```swift
import SwiftData
import SwiftUI

struct LiveSessionsMenu: View {
    @Environment(AppStore.self) private var appStore
    @Query private var sessions: [SessionRecord]

    init(limit: Int) {
        var descriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\SessionRecord.sourceModifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit, 1)
        _sessions = Query(descriptor)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: SessionLiveness.tickInterval)) { context in
            let slice = SessionLiveness.slice(from: sessions, now: context.date)
            if slice.sessions.isEmpty {
                Text("No live Codex sessions")
            } else {
                ForEach(slice.sessions, id: \.id) { session in
                    Button {
                        appStore.openSessionFromMenuBar(session.id)
                    } label: {
                        Text(Self.itemTitle(for: session, now: context.date))
                    }
                }
                if slice.overflowCount > 0 {
                    Text("\(slice.overflowCount) more live sessions")
                }
            }
            Divider()
            Button("Open AgentTrail") {
                appStore.bringMainWindowForward()
            }
            Button("Refresh Sessions") {
                appStore.refresh()
            }
        }
    }

    static func itemTitle(for session: SessionRecord, now: Date) -> String {
        let project = session.project?.name ?? "Unknown project"
        let events = "\(session.stepCount) events"
        return "\(session.title) — \(project) · \(events)"
    }
}

struct LiveSessionsStatusLabel: View {
    @Query private var sessions: [SessionRecord]

    init(limit: Int) {
        var descriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\SessionRecord.sourceModifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit, 1)
        _sessions = Query(descriptor)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: SessionLiveness.tickInterval)) { context in
            let slice = SessionLiveness.slice(from: sessions, now: context.date)
            let liveCount = slice.sessions.count + slice.overflowCount
            Image(systemName: SessionLiveness.extraSymbolName(liveCount: liveCount))
                .accessibilityLabel(SessionLiveness.extraAccessibilityLabel(liveCount: liveCount))
        }
    }
}

struct LiveSessionsUnavailableMenu: View {
    let explanation: String
    let onOpen: () -> Void

    var body: some View {
        Text(explanation)
        Divider()
        Button("Open AgentTrail", action: onOpen)
    }
}
```

`.menu` style flattens to one line, so item titles use the spec fallback `title — projectName · N events`. Do not put paths, commands, or payloads in the menu. Empty and overflow rows are `Text` (non-actionable in a SwiftUI menu); do not wrap those rows in `Button`.

- [ ] **Step 5: Add a title-format test**

In `AgentTrailTests/SessionLivenessTests.swift`, add:

```swift
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
```

- [ ] **Step 6: Regenerate and run tests**

```bash
xcodegen generate
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests/SessionLivenessTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add AgentTrail/Views/LiveSessionsMenu.swift AgentTrail/Views/LibraryUnavailableView.swift AgentTrailTests/SessionLivenessTests.swift AgentTrail.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(menu-bar): add live session menu views

- Extra menu lists recently writing Codex threads without payloads
EOF
)"
```

---

### Task 5: Mount the MenuBarExtra scene

**Files:**
- Modify: `AgentTrail/AgentTrailApp.swift` (`body` scenes)

**Interfaces:**
- Consumes: `LiveSessionsMenu`, `LiveSessionsStatusLabel`, `LiveSessionsUnavailableMenu`, `LibraryAccessIssue.menuExplanation`, `AppStore.loadedSessionLimit`, `AppStore.bringMainWindowForward`, `AgentTrailRuntime.isTestHost`
- Produces: a `.menu` `MenuBarExtra` in non-test runs; omitted in the test host

- [ ] **Step 1: Add the extra scene**

In `AgentTrail/AgentTrailApp.swift`, keep `WindowGroup` and `Settings` as they are. After the `Settings { ... }` scene, append:

```swift
        if !AgentTrailRuntime.isTestHost {
            MenuBarExtra {
                if let libraryAccessIssue {
                    LiveSessionsUnavailableMenu(
                        explanation: libraryAccessIssue.menuExplanation,
                        onOpen: { appStore.bringMainWindowForward() }
                    )
                } else if let modelContainer {
                    LiveSessionsMenu(limit: appStore.loadedSessionLimit)
                        .environment(appStore)
                        .modelContainer(modelContainer)
                } else {
                    LiveSessionsUnavailableMenu(
                        explanation: appStore.statusMessage,
                        onOpen: { appStore.bringMainWindowForward() }
                    )
                }
            } label: {
                if let modelContainer {
                    LiveSessionsStatusLabel(limit: appStore.loadedSessionLimit)
                        .environment(appStore)
                        .modelContainer(modelContainer)
                } else {
                    Image(systemName: SessionLiveness.extraSymbolName(liveCount: 0))
                        .accessibilityLabel(SessionLiveness.extraAccessibilityLabel(liveCount: 0))
                }
            }
            .menuBarExtraStyle(.menu)
        }
```

Do not set `LSUIElement`. Do not change `NSApplication.activationPolicy`. Do not add a Settings toggle. When the library is unavailable, omit Refresh (the unavailable menu already has no Refresh button).

If `SceneBuilder` rejects `if !AgentTrailRuntime.isTestHost` as a sibling of `WindowGroup`/`Settings`, add this computed property on `AgentTrailApp` and put `liveSessionsExtra` in `body` instead of the inline `if`:

```swift
    @SceneBuilder
    private var liveSessionsExtra: some Scene {
        if !AgentTrailRuntime.isTestHost {
            MenuBarExtra {
                if let libraryAccessIssue {
                    LiveSessionsUnavailableMenu(
                        explanation: libraryAccessIssue.menuExplanation,
                        onOpen: { appStore.bringMainWindowForward() }
                    )
                } else if let modelContainer {
                    LiveSessionsMenu(limit: appStore.loadedSessionLimit)
                        .environment(appStore)
                        .modelContainer(modelContainer)
                } else {
                    LiveSessionsUnavailableMenu(
                        explanation: appStore.statusMessage,
                        onOpen: { appStore.bringMainWindowForward() }
                    )
                }
            } label: {
                if let modelContainer {
                    LiveSessionsStatusLabel(limit: appStore.loadedSessionLimit)
                        .environment(appStore)
                        .modelContainer(modelContainer)
                } else {
                    Image(systemName: SessionLiveness.extraSymbolName(liveCount: 0))
                        .accessibilityLabel(SessionLiveness.extraAccessibilityLabel(liveCount: 0))
                }
            }
            .menuBarExtraStyle(.menu)
        }
    }
```

- [ ] **Step 2: Run the unit tests that must stay green, including parser status**

```bash
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests/SessionLivenessTests -only-testing:AgentTrailTests/ParserTests/testCursorParserHandlesStatusTimestampsAndTokenCounts
```

Expected: PASS. `JSONLineSupport.sessionStatus` is untouched; Cursor still reports `.historical`. The `testOpenSessionFromMenuBarSetsSelectionWithoutRefreshing` case lives in `SessionLivenessTests` and is included in that target filter.

- [ ] **Step 3: Confirm the test host does not create a status item**

The `if !AgentTrailRuntime.isTestHost` guard is the mechanism. XCTest sets `XCTestConfigurationFilePath`, which `AgentTrailRuntime.isTestHost` already reads. Do not add a runtime assertion against `NSApp.windows` in unit tests.

- [ ] **Step 4: Commit**

```bash
git add AgentTrail/AgentTrailApp.swift
git commit -m "$(cat <<'EOF'
feat(menu-bar): show companion live Codex extra

- MenuBarExtra lists live sessions and is omitted in the test host
EOF
)"
```

---

### Task 6: README and verification

**Files:**
- Modify: `README.md` (Current experience list)

**Interfaces:**
- Consumes: shipping behavior from Tasks 1–5
- Produces: one README bullet; full `AgentTrailTests` run

- [ ] **Step 1: Add the README bullet**

In `README.md`, under **Current experience**, add this bullet after “Watches `~/.codex/sessions` for active-session updates.”:

```markdown
- Shows a menu bar extra for Codex sessions whose history files were written in the last three minutes.
```

- [ ] **Step 2: Run the full test target**

```bash
xcodebuild test -project AgentTrail.xcodeproj -scheme AgentTrail -destination 'platform=macOS' -derivedDataPath Build/DerivedData -only-testing:AgentTrailTests
```

Expected: PASS, `** TEST SUCCEEDED **`.

- [ ] **Step 3: Manual check (normal app run, not XCTest)**

Run the AgentTrail scheme on My Mac:

1. A status item appears (`circle.dashed` when idle).
2. While a Codex session is writing, the extra lists it; choosing it fronts AgentTrail on that session.
3. After more than 3 minutes with no writes, the row disappears.
4. The sidebar Live badge matches extra membership for the same session.
5. `AgentTrailTests` still does not leave a status item (already guaranteed by the test-host guard).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(menu-bar): note live Codex extra

- README current experience includes the three-minute menu bar extra
EOF
)"
```

---

## Spec coverage

| Spec requirement | Task |
| --- | --- |
| Companion `MenuBarExtra`, `.menu` style | 5 |
| 3-minute derived liveness, not stored `recording` | 1 |
| Extra + sidebar share helper | 1, 3, 4 |
| No disk scan in the extra; uses imported page | 4 (`Query` + `loadedSessionLimit`) |
| 15s `TimelineView` tick | 3, 4 |
| Click sets selection and fronts window | 2, 4 |
| Cap 20 + overflow row | 1, 4 |
| Empty copy, Open, Refresh | 4 |
| Unavailable: explanation + Open, no Refresh | 4, 5 |
| Test host omits extra | 5 |
| Idle/live SF Symbols + VoiceOver | 1, 4, 5 |
| No payloads/paths in menu | 4 title test |
| Do not change `JSONLineSupport.sessionStatus` | 5 Cursor status test |
| AppStore selection unit test (`SessionLivenessTests`) | 2 |
| README bullet | 6 |
| No LSUIElement / accessory policy / badge / second watcher | 5 (omitted on purpose) |
