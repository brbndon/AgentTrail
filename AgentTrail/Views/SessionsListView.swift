import SwiftData
import SwiftUI

struct SessionsListView: View {
    private static let timelineStart = Date()
    @Environment(AppStore.self) private var appStore
    @Query private var sessions: [SessionRecord]
    @Binding var selection: UUID?

    init(selection: Binding<UUID?>, limit: Int) {
        _selection = selection
        var descriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\SessionRecord.sourceModifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit, 1)
        _sessions = Query(descriptor)
    }

    private var filteredSessions: [SessionRecord] {
        SessionArrangement.filtered(sessions, query: appStore.sidebarSearch, agent: appStore.agentFilter)
    }

    private var sessionGroups: [ProjectSessionGroup] {
        let preferences = appStore.browsePreferences
        return SessionArrangement.groups(
            sessions: filteredSessions,
            sort: preferences.sortField,
            direction: preferences.sortDirection,
            grouping: preferences.grouping,
            totalCounts: appStore.projectSessionCounts
        )
    }

    private var availableAgents: [AgentType] {
        AgentType.allCases.filter { agent in
            agent == .codex || agent == appStore.agentFilter || sessions.contains { $0.agentType == agent }
        }
    }

    var body: some View {
        @Bindable var appStore = appStore

        // AppStore owns the menu-bar count timer and import updates. Keep this
        // AppKit-backed List render-pure to avoid reentrant delegate updates.
        SwiftUI.TimelineView(.periodic(from: Self.timelineStart, by: SessionLiveness.tickInterval)) { context in
            List(selection: $selection) {
                ForEach(sessionGroups) { group in
                    if group.showsHeader {
                        Section {
                            sessionRows(in: group, now: context.date)
                        } header: {
                            ProjectSectionHeader(name: group.name, sessionCount: group.totalCount)
                        }
                    } else {
                        Section {
                            sessionRows(in: group, now: context.date)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .searchable(text: $appStore.sidebarSearch, placement: .sidebar, prompt: "Search loaded sessions")
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                if availableAgents.count > 1 {
                    Picker("Agent", selection: $appStore.agentFilter) {
                        Text("All imported agents").tag(AgentType?.none)
                        ForEach(availableAgents) { agentType in
                            Text(agentType.displayName).tag(AgentType?.some(agentType))
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Label("Codex sessions", systemImage: AgentType.codex.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                SessionBrowseControls(preferences: appStore.browsePreferences)
            }
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
                visibleCount: sessions.filter { $0.parentSessionID == nil }.count,
                totalCount: appStore.totalAvailableSessionCount,
                hasMoreSessions: appStore.hasMoreSessions,
                nextPageCount: appStore.nextSessionPageCount,
                sortNote: appStore.browsePreferences.sortField == .lastUpdated
                    ? nil
                    : "Sorted within the \(sessions.count) loaded sessions",
                loadMore: appStore.loadMoreSessions
            )
        }
        .navigationTitle("Sessions")
    }

    private func sessionRows(in group: ProjectSessionGroup, now: Date) -> some View {
        ForEach(group.sessions) { session in
            SessionRowView(session: session, now: now, sortField: appStore.browsePreferences.sortField)
                .tag(session.id)
        }
    }


}

struct ProjectSessionGroup: Identifiable {
    let id: String
    let name: String
    let totalCount: Int
    let sessions: [SessionRecord]
    var showsHeader = true
}

enum SessionProjectGrouping {
    /// The input is already the globally newest-first page from SwiftData. The
    /// first appearance of each project therefore defines section order, while
    /// each project's rows retain the same newest-first ordering.
    static func groups(
        sessions: [SessionRecord],
        totalCounts: [String: Int]
    ) -> [ProjectSessionGroup] {
        var projectOrder: [String] = []
        var names: [String: String] = [:]
        var sessionsByProject: [String: [SessionRecord]] = [:]

        for session in sessions {
            let identity = session.project?.identity ?? "project:unknown"
            if sessionsByProject[identity] == nil {
                projectOrder.append(identity)
                sessionsByProject[identity] = []
                names[identity] = session.project?.name ?? "Unknown project"
            }
            sessionsByProject[identity, default: []].append(session)
        }

        return projectOrder.compactMap { identity in
            guard let projectSessions = sessionsByProject[identity] else { return nil }
            return ProjectSessionGroup(
                id: identity,
                name: names[identity] ?? "Unknown project",
                totalCount: max(totalCounts[identity] ?? 0, projectSessions.count),
                sessions: projectSessions
            )
        }
    }
}

private struct ProjectSectionHeader: View {
    let name: String
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Label(name, systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(sessionCount) \(sessionCount == 1 ? "thread" : "threads")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(sessionCount) \(sessionCount == 1 ? "thread" : "threads") total")
    }
}

struct DiscoveryStatusBar: View {
    let message: String
    let isLoading: Bool
    let progress: IngestionProgress?
    let visibleCount: Int
    let totalCount: Int
    let hasMoreSessions: Bool
    let nextPageCount: Int
    var sortNote: String?
    let loadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(isLoading ? "Discovery progress" : "Status")
                .accessibilityValue(message)

            if isLoading {
                if let fraction = progress?.fractionCompleted {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .accessibilityLabel("Import progress")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                }
            }

            if totalCount > 0 {
                Text("\(visibleCount) loaded · \(totalCount) discovered")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let sortNote {
                Text(sortNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if hasMoreSessions {
                Button("Load \(nextPageCount) Older Sessions", systemImage: "arrow.down.circle", action: loadMore)
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                    .frame(minHeight: 44)
                    .accessibilityHint("Loads the next older page of Codex threads")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct SessionRowView: View {
    let session: SessionRecord
    let now: Date
    let sortField: SessionSortField

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
                    if sortField == .started {
                        Text("Started \(session.startDate, style: .relative)")
                    } else {
                        Text("Updated \(session.sourceModifiedAt, style: .relative)")
                    }
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
