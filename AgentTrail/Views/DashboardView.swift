import SwiftData
import SwiftUI

/// A grid home for the loaded sessions. Shown when no session is open, and as
/// the whole window in the Dashboard layout.
struct DashboardView: View {
    private static let timelineStart = Date()
    private static let columns = [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 14, alignment: .top)]

    @Environment(AppStore.self) private var appStore
    @Query private var sessions: [SessionRecord]
    let showsSearch: Bool
    var showsDiscoveryStatus = true

    init(limit: Int, showsSearch: Bool, showsDiscoveryStatus: Bool = true) {
        self.showsDiscoveryStatus = showsDiscoveryStatus
        self.showsSearch = showsSearch
        var descriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\SessionRecord.sourceModifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit, 1)
        _sessions = Query(descriptor)
    }

    private var filteredSessions: [SessionRecord] {
        SessionArrangement.filtered(sessions, query: appStore.sidebarSearch, agent: appStore.agentFilter)
    }

    private var hasActiveFilters: Bool {
        !TraceSearch.terms(appStore.sidebarSearch).isEmpty || appStore.agentFilter != nil
    }

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: Self.timelineStart, by: SessionLiveness.tickInterval)) { context in
            content(now: context.date)
        }
        .navigationTitle("Dashboard")
        .task(id: appStore.sessionSummaryCache.request(for: sessions)) {
            await appStore.sessionSummaryCache.prepare(sessions)
        }
        .safeAreaInset(edge: .bottom) {
            if showsDiscoveryStatus {
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
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let filtered = filteredSessions
        VStack(alignment: .leading, spacing: 0) {
            header(filtered: filtered, liveCount: filtered.filter { SessionLiveness.isRecentlyWriting($0, now: now) }.count)
                .padding(24)
            if filtered.isEmpty {
                EmptyStateView(
                    isLoading: appStore.isLoading,
                    statusMessage: appStore.statusMessage,
                    progress: appStore.ingestionProgress,
                    hasSessions: !sessions.isEmpty,
                    hasActiveFilters: hasActiveFilters,
                    clearFilters: {
                        appStore.sidebarSearch = ""
                        appStore.agentFilter = nil
                    }
                )
            } else {
                let preferences = appStore.browsePreferences
                let groups = SessionArrangement.groups(
                    sessions: filtered,
                    sort: preferences.sortField,
                    direction: preferences.sortDirection,
                    grouping: preferences.grouping,
                    totalCounts: appStore.projectSessionCounts
                )
                let live = filtered.filter { SessionLiveness.isRecentlyWriting($0, now: now) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !live.isEmpty {
                            liveStrip(live)
                        }
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                if group.showsHeader {
                                    groupHeader(group)
                                }
                                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14) {
                                    ForEach(group.sessions) { session in
                                        Button {
                                            appStore.selectedSessionID = session.id
                                        } label: {
                                            SessionCardView(
                                                session: session, now: now, sortField: preferences.sortField,
                                                summary: appStore.sessionSummaryCache.summary(for: session, now: now))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1_400, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func header(filtered: [SessionRecord], liveCount: Int) -> some View {
        let projectCount = Set(filtered.map { $0.project?.identity ?? "project:unknown" }).count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sessions")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                if showsSearch {
                    searchField
                }
            }
            HStack(spacing: 12) {
                StatTile(
                    value: appStore.sessionSummaryCache.needsAttention(in: filtered), title: "Needs attention",
                    systemImage: "exclamationmark.triangle")
                StatTile(value: projectCount, title: projectCount == 1 ? "Project" : "Projects", systemImage: "folder")
                StatTile(value: liveCount, title: "Live now", systemImage: "record.circle", highlight: liveCount > 0)
            }
            HStack(spacing: 10) {
                SessionBrowseControls(preferences: appStore.browsePreferences)
                if let agent = appStore.agentFilter {
                    Button {
                        appStore.agentFilter = nil
                    } label: {
                        Label("\(agent.displayName) only", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show all agents")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var searchField: some View {
        @Bindable var appStore = appStore
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search loaded sessions", text: $appStore.sidebarSearch)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search loaded sessions")
            if !appStore.sidebarSearch.isEmpty {
                Button {
                    appStore.sidebarSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))
        .frame(width: 280)
    }

    private func liveStrip(_ live: [SessionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live now", systemImage: "record.circle")
                .font(.headline)
                .foregroundStyle(.red)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(live) { session in
                        Button {
                            appStore.selectedSessionID = session.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(session.project?.name ?? "Unknown project")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: 240, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.10), in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Live session: \(session.title), \(session.project?.name ?? "Unknown project")")
                    }
                }
            }
        }
    }

    private func groupHeader(_ group: ProjectSessionGroup) -> some View {
        HStack(spacing: 8) {
            Label(group.name, systemImage: "folder")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text("\(group.totalCount) \(group.totalCount == 1 ? "thread" : "threads")")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct StatTile: View {
    let value: Int?
    let title: String
    let systemImage: String
    var highlight = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(highlight ? Color.red : Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.map(String.init) ?? "…")
                    .font(.title2.weight(.semibold).monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: 220)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "\($0) \(title)" } ?? "Checking \(title)")
    }
}

#Preview("Session card · Light") {
    SessionCardPreview().preferredColorScheme(.light)
}

#Preview("Session card · Dark") {
    SessionCardPreview().preferredColorScheme(.dark)
}

private struct SessionCardPreview: View {
    var body: some View {
        let session = SessionRecord(
            sourceKey: "preview:card", agentType: .codex, title: "Repair the ingestion pipeline",
            startDate: .now.addingTimeInterval(-1_800), endDate: .now.addingTimeInterval(-600),
            workingDirectory: "/tmp/AgentTrail", sourcePath: "/tmp/card.jsonl", sourceModifiedAt: .now.addingTimeInterval(-600))
        let reply = StepRecord(
            stepIndex: 1, kind: .assistant, timestamp: .now.addingTimeInterval(-600), title: "Fixed importing",
            contentSummary: "Updated the parser to resume after incomplete records.", searchText: "", fullPayloadRef: nil,
            hasError: false, filePath: "Sources/Parser.swift")
        SessionCardView(
            session: session, now: .now, sortField: .lastUpdated,
            summary: SessionSummary(session: session, steps: [reply], now: .now)
        )
        .padding().frame(width: 360)
    }
}

/// One session as a card: title first, then where and when it ran.
struct SessionCardView: View {
    let session: SessionRecord
    let now: Date
    let sortField: SessionSortField
    let summary: SessionSummary?
    @State private var isHovering = false

    private var isLive: Bool {
        SessionLiveness.isRecentlyWriting(session, now: now)
    }

    private var dateText: String {
        let date = sortField == .started ? session.startDate : session.sourceModifiedAt
        let prefix = sortField == .started ? "Started" : "Updated"
        return "\(prefix) \(date.formatted(.relative(presentation: .numeric, unitsStyle: .wide)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: session.agentType.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let summary {
                    Label(outcomeTitle(summary), systemImage: outcomeSymbol(summary))
                        .font(.caption)
                        .foregroundStyle(summary.errorCount > 0 ? .red : .secondary)
                        .accessibilityLabel("Session outcome: \(outcomeTitle(summary))")
                }
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.sourceState == .degraded {
                    Label("Degraded", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if isLive, summary == nil {
                    Label("Live", systemImage: "record.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text(session.title)
                .font(.headline)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            if let summary {
                Text(summary.finalAssistantMessage ?? "No assistant reply recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                HStack {
                    Text(
                        "\(summary.filesTouched.count) \(summary.filesTouched.count == 1 ? "file" : "files") · \(summary.errorCount) \(summary.errorCount == 1 ? "error" : "errors")"
                    )
                    Spacer(minLength: 6)
                    Text(Duration.seconds(summary.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView("Summarizing…").controlSize(.small)
            }
            Label(session.project?.name ?? "Unknown project", systemImage: "folder")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Text(dateText)
                Spacer(minLength: 8)
                if let summary { Text("\(summary.stepCount) events") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isHovering ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: 14))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [
                session.agentType.displayName,
                session.project?.name ?? "Unknown project",
                session.title,
                dateText,
                summary.map { "\($0.stepCount) events, \($0.filesTouched.count) files, \($0.errorCount) errors, \(outcomeTitle($0))" },
                summary?.finalAssistantMessage,
                summary.map {
                    "Duration \(Duration.seconds($0.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)))"
                },
                session.sourceState == .degraded ? "Degraded" : nil,
                session.sourceState != .degraded && isLive ? "Live" : nil,
                session.isPinned ? "Pinned" : nil,
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
        .accessibilityAddTraits(.isButton)
    }

    private func outcomeTitle(_ summary: SessionSummary) -> String {
        switch summary.outcome {
        case .completed: "Done"
        case .hasErrors(let count): count == 1 ? "1 error" : "\(count) errors"
        case .running: "Live"
        }
    }

    private func outcomeSymbol(_ summary: SessionSummary) -> String {
        switch summary.outcome {
        case .completed: "checkmark.circle"
        case .hasErrors: "exclamationmark.triangle"
        case .running: "record.circle"
        }
    }
}
