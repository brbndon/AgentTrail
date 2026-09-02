# Live Codex menu bar extra

Date: 2026-09-01  
Status: approved design  
App: AgentTrail (macOS 15+, SwiftUI, Codex-first local session viewer)

## Goal

Add a companion menu bar extra that lists Codex sessions that are currently writing, so the user can jump to one without hunting the sidebar. The main library window remains the app. Closing that window still quits.

## Non-goals

- Accessory / keep-running-after-close activation policy (`LSUIElement`, `NSApplication.ActivationPolicy.accessory`)
- AppKit `NSStatusItem` numeric badge
- A second filesystem watcher or Codex process sniffing
- Rich popover, live-follow mini Console, or Dock-only live UI
- Follow-the-tail timeline, pin UI, context menus, extra command-menu work
- Changing `JSONLineSupport.sessionStatus` (10-second `recording` snapshot at ingest)
- New SwiftData fields, settings toggle, or notifications

## Decisions already made

| Topic | Choice |
| --- | --- |
| App relationship | Companion extra; main `WindowGroup` stays primary |
| Click surface | Compact `.menu` list, not a popover |
| Liveness | Recently writing: `sourceModifiedAt` within the last 3 minutes |
| Implementation | SwiftUI `MenuBarExtra`, derived query over imported sessions |

## Architecture

The extra is a second SwiftUI scene on the existing `AgentTrailApp`, beside `WindowGroup` and `Settings`. It shares the same `AppStore` and SwiftData `ModelContainer`. No new persistence. No change to Launch Services or Info.plist activation.

**Liveness is derived at render time**, not stored. Shared helper `SessionLiveness` answers whether a session is recently writing. The extra and the sidebar “Live” badge both use it. `SessionStatus.recording` remains the ingest-time 10-second flag and is not shown as “Live”.

**The extra does not scan disk.** FSEvents → `AppStore.refresh()` continues to upsert `sourceModifiedAt`. The extra reads the currently imported page. A writing Codex file is expected to sit in the newest-30 set. A 15-second SwiftUI `TimelineView` tick recomputes the menu so rows age out after 3 minutes even when no further FSEvent arrives.

**Click path:** set `selectedSessionID`, activate AgentTrail, order the existing window front (unminimize if needed). `RootView` already binds detail to that selection.

If the Application Support lease is missing or the store cannot open, the extra still appears but does not list sessions.

Omit the extra scene when `AgentTrailRuntime.isTestHost` is true so XCTest does not create an `NSStatusItem`.

## Liveness rule

A session is live when all of the following hold at `now`:

1. `agentType == .codex`
2. `isBranch == false`
3. `sourceState != .unavailable`
4. `sourceModifiedAt <= now` (future timestamps are not live)
5. `now.timeIntervalSince(sourceModifiedAt) < 180` seconds

Boundary: 0s and 2m59s are live; 3m0s is not. Degraded and failed sessions may still appear if they were recently written. Non-Codex agents never appear in the extra.

Constant: `SessionLiveness.recency: TimeInterval = 180`. Do not read `statusRawValue` in this helper.

## Components

### `SessionLiveness`

Pure helper (no SwiftUI, no SwiftData writes). Input: `sourceModifiedAt`, `isBranch`, `agentType`, `sourceState`, `now`. Output: `Bool`. Unit-testable with frozen dates.

Suggested path: `AgentTrail/Models/SessionLiveness.swift`.

### `LiveSessionsMenu`

`MenuBarExtra` content. Queries imported `SessionRecord`s (same loaded page as the sidebar), filters with `SessionLiveness`, sorts by `sourceModifiedAt` descending.

Suggested path: `AgentTrail/Views/LiveSessionsMenu.swift`.

Menu structure:

1. Live session buttons, newest first, capped at **20**. Each item:
   - Title: session title
   - Secondary text, one line: `projectName · N events · Updated <relative>`
   - If `MenuBarExtra` `.menu` style flattens to a single line, concatenate: `title — projectName · N events`
2. If more than 20 live sessions, one disabled row: `N more live sessions`
3. If zero live sessions and the library is available: one disabled row, `No live Codex sessions`
4. Separator
5. **Open AgentTrail** — activate and front the window; do not change selection
6. **Refresh Sessions** — `appStore.refresh()`, enabled when the library is available (including while an import is running; existing coalescing applies)

Action for a session row: `appStore.openSessionFromMenuBar(session.id)`.

Privacy: titles, project names, relative times, and event counts only. No payloads, commands, or paths.

### Extra label

Template SF Symbol:

- 0 live: `circle.dashed`
- 1+ live: `record.circle`

VoiceOver: `No live Codex sessions` or `N live Codex session(s)`. No numeric badge in the status item.

### `AppStore.openSessionFromMenuBar(_ id: UUID)`

Main-actor method:

1. `selectedSessionID = id`
2. Activate the running app (`NSApp.activate()` on macOS 15)
3. Find the existing main `WindowGroup` window, deminiaturize if needed, `makeKeyAndOrderFront`

Do not open a second window. Do not fetch sessions outside the loaded page. If the id is missing from the sidebar’s current filter, existing reconcile logic may snap selection away; that is acceptable for v1.

Refresh is unchanged: `refresh()`.

### Sidebar `SessionRowView`

Replace `session.status == .recording` with `SessionLiveness` for the “Live” badge and its accessibility label. Pin, degraded, and failed presentation stay as they are. Degraded still takes visual priority over Live when both could apply (keep current `sourceState == .degraded` first).

### `AgentTrailApp`

Add:

```swift
MenuBarExtra {
    // LiveSessionsMenu or unavailable placeholder
} label: {
    // TimelineView-backed symbol + accessibility label
}
.menuBarExtraStyle(.menu)
```

Wire `.environment(appStore)` and `.modelContainer` when a container exists.

When `libraryAccessIssue != nil` or `modelContainer == nil`, still mount the extra. Menu content is one disabled row whose text matches `LibraryUnavailableView` for that issue (another copy owns the library, or the store cannot open) plus **Open AgentTrail**. Omit **Refresh Sessions**.

Do not create this scene in the test host.

`project.yml` already includes the `AgentTrail/` folder, so new files do not need a project-file edit unless XcodeGen membership changes.

## Data flow

```text
~/.codex/sessions  --FSEvents-->  AppStore.refresh()  -->  SwiftData SessionRecord.sourceModifiedAt
                                                              |
                         TimelineView 15s tick                |
                                                              v
                                              SessionLiveness.isRecentlyWriting
                                                              |
                         +------------------------------------+--------------------------------+
                         v                                                                     v
                  LiveSessionsMenu                                                    SessionRowView Live badge
                         |
                         | click
                         v
              AppStore.openSessionFromMenuBar  -->  selectedSessionID
                                               -->  NSApp.activate + order front
                                               -->  RootView detail TimelineView
```

While a file keeps growing, the next ingest moves `sourceModifiedAt` forward and the row stays. When writes stop, the row drops on the next 15s tick after 180s.

**Open AgentTrail** uses the same activate/front path with no selection change.

## Error handling

| Situation | Extra behavior |
| --- | --- |
| Lease conflict / store unavailable | Disabled explanation + Open AgentTrail; no session rows; no Refresh |
| Session deleted between render and click | Still set `selectedSessionID`; detail already shows “Session unavailable”; no alert |
| Import in flight | Refresh remains enabled; no spinner in the menu; icon may lag until next tick or ingest |
| Ingest fails | `sourceModifiedAt` does not advance; row ages out after 180s |
| Empty live set | Disabled `No live Codex sessions`; Open + Refresh still work |
| Test host | Extra scene not created |

No user notifications and no modal alerts from the extra.

## Testing

**Unit tests** (`AgentTrailTests`, frozen `now`, no status item):

- age 0s and 179s → live
- age 180s and 181s → not live
- future `sourceModifiedAt` → not live
- branch `sourceKey` → not live even if just written
- `agentType != .codex` → not live
- `sourceState == .unavailable` → not live
- `sourceState == .degraded` with recent mtime → live
- helper ignores `SessionStatus.recording`

**AppStore:** construct `AppStore` in a unit test and assert `openSessionFromMenuBar` sets `selectedSessionID`. Do not instantiate `NSStatusItem` or assert `NSApp` activation in unit tests.

**Parser tests:** do not change `JSONLineSupport.sessionStatus` or Codex fixtures.

**Manual check after implementation:**

1. Status item appears in a normal app run
2. While a Codex session is writing, the extra lists it; choosing it fronts AgentTrail on that session
3. After >3 minutes with no writes, the row disappears
4. `AgentTrailTests` does not leave a status item
5. Sidebar Live badge matches the extra’s membership for the same session

No Maestro flow for this slice.

## README

Add one bullet under Current experience: AgentTrail shows a menu bar extra for Codex sessions whose history files were written in the last three minutes.

## Implementation notes

- New files under `AgentTrail/` are picked up by XcodeGen `sources: AgentTrail`. If the checked-in `xcodeproj` is regenerated in this repo’s usual workflow, regenerate after adding files; otherwise the folder reference already includes them.
- Prefer `TimelineView(.periodic(from:start, by: 15))` around the extra label and menu so SwiftUI invalidates without a custom timer on `AppStore`.
- Use a template image so the extra respects menu-bar appearance.
- Keep `openSessionFromMenuBar` on `AppStore` so the menu, and later a command-menu item, share one path.
