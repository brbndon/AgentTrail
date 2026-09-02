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
        SwiftUI.TimelineView(.periodic(from: .now, by: SessionLiveness.tickInterval)) { context in
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
        SwiftUI.TimelineView(.periodic(from: .now, by: SessionLiveness.tickInterval)) { context in
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
