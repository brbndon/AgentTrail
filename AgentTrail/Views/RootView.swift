import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionRecord.startDate, order: .reverse) private var sessions: [SessionRecord]

    var body: some View {
        @Bindable var appStore = appStore

        NavigationSplitView {
            SessionsListView(selection: $appStore.selectedSessionID)
                .frame(minWidth: 270)
        } detail: {
            if let selectedSession = sessions.first(where: { $0.id == appStore.selectedSessionID }) {
                TimelineView(session: selectedSession, payloadStore: appStore.payloadStore)
                    .id(selectedSession.id)
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appStore.refresh()
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                }
                .disabled(appStore.isLoading)
                .help("Scan Codex, Grok Build, and Cursor session folders")
            }
        }
        .task {
            guard !AgentTrailRuntime.isTestHost else { return }
            appStore.bootstrap(context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentTrailFocusTimelineSearch)) { _ in
            if appStore.selectedSessionID == nil {
                appStore.statusMessage = "Select a session to search its timeline"
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Choose a session", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("Select a trace from the sidebar to inspect its imported events.")
        }
        .accessibilityElement(children: .combine)
    }
}
