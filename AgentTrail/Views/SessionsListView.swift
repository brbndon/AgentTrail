import SwiftData
import SwiftUI

struct SessionsListView: View {
    @Environment(AppStore.self) private var appStore
    @Query(sort: \SessionRecord.startDate, order: .reverse) private var sessions: [SessionRecord]
    @Binding var selection: UUID?

    private var filteredSessions: [SessionRecord] {
        let query = appStore.sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter {
            guard appStore.agentFilter == nil || $0.agentType == appStore.agentFilter else { return false }
            return TraceSearch.matches(query, fields: [
                $0.title,
                $0.agentType.displayName,
                $0.workingDirectory,
                $0.sourcePath,
                $0.status.rawValue,
                $0.sourceState.rawValue
            ])
        }
    }

    var body: some View {
        @Bindable var appStore = appStore

        List(selection: $selection) {
            ForEach(AgentType.allCases) { agentType in
                let agentSessions = filteredSessions.filter { $0.agentType == agentType }
                if !agentSessions.isEmpty {
                    Section(agentType.displayName) {
                        ForEach(agentSessions) { session in
                            SessionRowView(session: session)
                                .tag(session.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
            VStack(alignment: .leading, spacing: 6) {
                Text(appStore.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if appStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .navigationTitle("Sessions")
        .onAppear { reconcileSelection() }
        .onChange(of: appStore.sidebarSearch) { _, _ in reconcileSelection() }
        .onChange(of: appStore.agentFilter) { _, _ in reconcileSelection() }
        .onChange(of: sessions.map(\.id)) { _, _ in reconcileSelection() }
    }

    private func reconcileSelection() {
        if let selection {
            if !filteredSessions.contains(where: { $0.id == selection }) {
                self.selection = filteredSessions.first?.id
            }
        } else {
            selection = filteredSessions.first?.id
        }
    }
}

private struct SessionRowView: View {
    let session: SessionRecord

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
                    Text(session.startDate, style: .relative)
                    Text("·")
                    Text("\(session.stepCount) events")
                    if session.sourceState == .degraded {
                        Text("·")
                        Label("Degraded", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if session.status == .recording {
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
                session.title,
                "\(session.stepCount) events",
                session.status == .recording ? "Live" : nil,
                session.isPinned ? "Pinned" : nil
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }
}
