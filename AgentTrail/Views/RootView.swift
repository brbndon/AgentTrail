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
                EmptyStateView(
                    isLoading: appStore.isLoading,
                    statusMessage: appStore.statusMessage,
                    progress: appStore.ingestionProgress,
                    hasSessions: !sessions.isEmpty
                )
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
    var isLoading = false
    var statusMessage = ""
    var progress: IngestionProgress?
    var hasSessions = false

    var body: some View {
        ContentUnavailableView {
            if isLoading {
                Label("Importing local sessions", systemImage: "arrow.triangle.2.circlepath")
            } else if hasSessions {
                Label("Choose a session", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                Label("No sessions yet", systemImage: "tray")
            }
        } description: {
            if isLoading {
                VStack(spacing: 12) {
                    Text(statusMessage.isEmpty ? "Scanning local agent folders…" : statusMessage)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    if let fraction = progress?.fractionCompleted {
                        ProgressView(value: fraction)
                            .frame(maxWidth: 280)
                    } else {
                        ProgressView()
                            .controlSize(.regular)
                    }
                    Text("Large Codex/Grok trees can take several minutes on first import. Progress updates in the sidebar status bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            } else if hasSessions {
                Text("Select a trace from the sidebar to inspect its imported events.")
            } else {
                Text(statusMessage.isEmpty
                    ? "Use Refresh to scan ~/.codex, ~/.grok, and ~/.cursor for local agent traces."
                    : statusMessage)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
