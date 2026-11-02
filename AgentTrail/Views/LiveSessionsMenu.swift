import SwiftUI

struct LiveSessionsMenu: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        // MenuBarExtra can re-enter its AppKit host while a Query/Timeline is
        // updating. AppStore publishes this small snapshot on its 15-second
        // tick so opening the menu stays render-only.
        let items = appStore.liveSessionMenuItems
        if items.isEmpty {
            Text("No live Codex sessions")
        } else {
            ForEach(items) { item in
                Button {
                    appStore.openSessionFromMenuBar(item.id)
                } label: {
                    Text(item.displayTitle)
                }
            }
            if appStore.liveSessionOverflowCount > 0 {
                Text("\(appStore.liveSessionOverflowCount) more live sessions")
            }
        }
        Divider()
        Button("Open AgentTrail") {
            appStore.bringMainWindowForward()
        }
        Button("Refresh Sessions") {
            appStore.refresh()
        }
        .disabled(appStore.isLoading)
    }

    static func itemTitle(for session: SessionRecord, now: Date) -> String {
        LiveSessionMenuItem(
            id: session.id,
            title: session.title,
            projectName: session.project?.name ?? "Unknown project",
            eventCount: session.stepCount
        ).displayTitle
    }
}

struct LiveSessionsStatusLabel: View {
    let liveCount: Int

    init(liveCount: Int) { self.liveCount = liveCount }

    var body: some View {
        // Keep the MenuBarExtra label free of Query/Timeline dependencies: on
        // macOS 26, reactive labels can prevent the WindowGroup from launching.
        Image(systemName: SessionLiveness.extraSymbolName(liveCount: liveCount))
            .accessibilityLabel(SessionLiveness.extraAccessibilityLabel(liveCount: liveCount))
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
