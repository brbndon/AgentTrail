import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var appStore = appStore

        Group {
            switch appStore.browsePreferences.layout {
            case .classic:
                NavigationSplitView {
                    SessionsListView(selection: $appStore.selectedSessionID, limit: appStore.loadedSessionLimit)
                        .id(appStore.loadedSessionLimit)
                        .frame(minWidth: 270)
                } detail: {
                    detailContent
                }
            case .dashboard:
                NavigationStack {
                    detailContent
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if appStore.selectedSessionID != nil {
                    Button {
                        appStore.selectedSessionID = nil
                    } label: {
                        Label("Dashboard", systemImage: "square.grid.2x2")
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .help("Return to the dashboard")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appStore.refresh()
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                }
                .disabled(appStore.isLoading)
                .help("Refresh the loaded Codex session pages")
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

    @ViewBuilder
    private var detailContent: some View {
        if let selectedSessionID = appStore.selectedSessionID {
            SelectedSessionView(sessionID: selectedSessionID, payloadStore: appStore.payloadStore)
        } else {
            DashboardView(
                limit: appStore.loadedSessionLimit,
                showsSearch: appStore.browsePreferences.layout == .dashboard
            )
            .id(appStore.loadedSessionLimit)
        }
    }
}

private struct SelectedSessionView: View {
    @Query private var sessions: [SessionRecord]
    let payloadStore: PayloadStore

    init(sessionID: UUID, payloadStore: PayloadStore) {
        let selectedID = sessionID
        _sessions = Query(filter: #Predicate<SessionRecord> { $0.id == selectedID })
        self.payloadStore = payloadStore
    }

    var body: some View {
        if let session = sessions.first {
            TimelineView(session: session, payloadStore: payloadStore)
                .id(session.id)
        } else {
            ContentUnavailableView("Session unavailable", systemImage: "questionmark.folder")
        }
    }
}

struct EmptyStateView: View {
    var isLoading = false
    var statusMessage = ""
    var progress: IngestionProgress?
    var hasSessions = false
    var hasActiveFilters = false
    var clearFilters: () -> Void = { }

    var body: some View {
        ContentUnavailableView {
            if isLoading {
                Label("Importing local sessions", systemImage: "arrow.triangle.2.circlepath")
            } else if hasSessions && hasActiveFilters {
                Label("No matching sessions", systemImage: "magnifyingglass")
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
                    Text("AgentTrail loads Codex history 30 threads at a time. Sessions appear as they import.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            } else if hasSessions && hasActiveFilters {
                Text("Search and filters apply to loaded sessions. Clear them to see your sessions, or load older sessions.")
            } else if hasSessions {
                Text("Select a trace from the sidebar to inspect its imported events.")
            } else {
                Text(statusMessage.isEmpty
                    ? "Use Refresh to scan ~/.codex/sessions for local Codex traces."
                    : statusMessage)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        } actions: {
            if hasSessions && hasActiveFilters && !isLoading {
                Button("Clear search and filters", action: clearFilters)
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
