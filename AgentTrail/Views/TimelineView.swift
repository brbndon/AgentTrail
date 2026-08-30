import SwiftUI

/// The searchable, filterable event timeline for one imported agent session.
struct TimelineView: View {
    let session: SessionRecord
    let payloadStore: PayloadStore

    @State private var filter = TimelineFilter()
    @State private var selectedStepID: UUID?
    @State private var isInspectorVisible = true
    @State private var isBranchSheetPresented = false
    @State private var isBranchGraphPresented = false
    @State private var branchStepID: UUID?
    @FocusState private var isSearchFocused: Bool

    private var orderedSteps: [StepRecord] {
        session.steps.sorted { $0.stepIndex < $1.stepIndex }
    }

    private var matchingSteps: [StepRecord] {
        orderedSteps.filter(filter.matches)
    }

    private var selectedStep: StepRecord? {
        matchingSteps.first(where: { $0.id == selectedStepID }) ?? matchingSteps.first
    }

    private var branchStep: StepRecord? {
        orderedSteps.first(where: { $0.id == branchStepID })
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(
                session: session,
                filter: $filter,
                resultCount: matchingSteps.count,
                totalCount: orderedSteps.count,
                isInspectorVisible: $isInspectorVisible,
                isBranchGraphPresented: $isBranchGraphPresented,
                isSearchFocused: $isSearchFocused
            )
            Divider()

            if matchingSteps.isEmpty {
                TimelineEmptyState(filter: filter)
            } else {
                HSplitView {
                    TimelineStepList(steps: matchingSteps, selection: $selectedStepID)
                        .frame(minWidth: 430)

                    if isInspectorVisible, let selectedStep {
                        StepDetailView(step: selectedStep, payloadStore: payloadStore) {
                            branchStepID = selectedStep.id
                            isBranchSheetPresented = true
                        }
                            .frame(minWidth: 340, idealWidth: 410, maxWidth: 560)
                    }
                }
            }
        }
        .navigationTitle(session.title)
        .navigationSubtitle(session.project?.name ?? "Unknown project")
        .onAppear {
            ensureSelection()
        }
        .onChange(of: filter) { _, _ in
            ensureSelection()
        }
        .onChange(of: orderedSteps.map(\.id)) { _, _ in
            ensureSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentTrailFocusTimelineSearch)) { _ in
            isSearchFocused = true
        }
        .sheet(isPresented: $isBranchSheetPresented) {
            if let branchStep {
                BranchSessionSheet(step: branchStep)
            }
        }
    }

    private func ensureSelection() {
        guard let firstStep = matchingSteps.first else {
            selectedStepID = nil
            return
        }
        guard matchingSteps.contains(where: { $0.id == selectedStepID }) else {
            selectedStepID = firstStep.id
            return
        }
    }
}

private struct TimelineToolbar: View {
    let session: SessionRecord
    @Binding var filter: TimelineFilter
    let resultCount: Int
    let totalCount: Int
    @Binding var isInspectorVisible: Bool
    @Binding var isBranchGraphPresented: Bool
    @FocusState.Binding var isSearchFocused: Bool
    @State private var isFilterPresented = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search trace", text: $filter.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit {
                        isSearchFocused = false
                    }
                    .accessibilityLabel("Search trace events")
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear trace search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))
            .frame(minWidth: 220, maxWidth: .infinity)

            Button {
                isFilterPresented.toggle()
            } label: {
                Label("Filters", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $isFilterPresented, arrowEdge: .top) {
                TimelineFilterPopover(filter: $filter)
            }

            Button {
                isBranchGraphPresented.toggle()
            } label: {
                Label("Branches", systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $isBranchGraphPresented, arrowEdge: .top) {
                BranchGraphView(session: session)
            }

            if filter.isActive {
                Button("Clear filters") {
                    filter.reset()
                }
                .buttonStyle(.link)
            }

            Spacer(minLength: 12)

            Text("\(resultCount) of \(totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Showing \(resultCount) of \(totalCount) events")

            Button {
                isInspectorVisible.toggle()
            } label: {
                Image(systemName: isInspectorVisible ? "sidebar.right" : "sidebar.right")
                    .frame(minWidth: 28, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isInspectorVisible ? "Hide step inspector" : "Show step inspector")
            .help(isInspectorVisible ? "Hide step inspector" : "Show step inspector")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct TimelineFilterPopover: View {
    @Binding var filter: TimelineFilter

    var body: some View {
        Form {
            Picker("Step type", selection: $filter.kindRawValue) {
                Text("All steps").tag("all")
                ForEach(StepKind.allCases) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }

            Toggle("Errors only", isOn: $filter.errorsOnly)

            TextField("File path contains", text: $filter.filePathQuery)
                .textFieldStyle(.roundedBorder)

            Picker("Date", selection: $filter.dateRange) {
                ForEach(TimelineDateRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .padding(8)
    }
}

private struct TimelineStepList: View {
    let steps: [StepRecord]
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(steps) { step in
                TimelineStepRow(step: step)
                    .tag(step.id)
                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct TimelineStepRow: View {
    let step: StepRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 3) {
                Circle()
                    .fill(step.hasError ? Color.red : Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 12)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TraceKindBadge(kind: step.kind, hasError: step.hasError)
                    Text("#\(step.stepIndex + 1)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text(step.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(step.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)

                Text(step.contentSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    if let path = step.filePath, !path.isEmpty {
                        Label(path, systemImage: "doc")
                            .lineLimit(1)
                    }
                    if step.hasError {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(step.hasError ? .red : .secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.stepIndex + 1), \(step.kind.displayName), \(step.title)")
        .accessibilityValue(step.hasError ? "Error" : step.contentSummary)
    }
}

private struct TimelineEmptyState: View {
    let filter: TimelineFilter

    var body: some View {
        if filter.query.isEmpty && !filter.isActive {
            ContentUnavailableView {
                Label("No trace events", systemImage: "list.bullet.rectangle")
            } description: {
                Text("This session has not produced any parseable events yet.")
            }
        } else {
            ContentUnavailableView.search(text: filter.query)
        }
    }
}

#Preview("Timeline") {
    let session = SessionRecord(
        sourceKey: "preview",
        agentType: .codex,
        title: "Repair the ingestion pipeline",
        startDate: .now.addingTimeInterval(-1_800),
        endDate: .now,
        workingDirectory: "/Users/example/AgentTrail",
        sourcePath: "/Users/example/.codex/sessions/sample.jsonl",
        sourceModifiedAt: .now
    )
    let firstStep = StepRecord(
        stepIndex: 0,
        kind: .user,
        timestamp: .now.addingTimeInterval(-1_800),
        title: "Repair the ingestion pipeline",
        contentSummary: "Find why the live session stopped importing events.",
        searchText: "repair ingestion pipeline live session stopped importing events",
        fullPayloadRef: nil,
        hasError: false,
        session: session
    )
    let secondStep = StepRecord(
        stepIndex: 1,
        kind: .error,
        timestamp: .now.addingTimeInterval(-900),
        title: "Parser skipped a malformed record",
        contentSummary: "The final JSONL line was incomplete while the agent was still writing.",
        searchText: "parser skipped malformed record incomplete JSONL",
        fullPayloadRef: nil,
        hasError: true,
        filePath: nil,
        session: session
    )
    session.steps = [firstStep, secondStep]
    return TimelineView(session: session, payloadStore: PayloadStore())
        .frame(width: 1_100, height: 700)
}
