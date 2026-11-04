import SwiftUI

/// The searchable, filterable event timeline for one imported agent session.
struct TimelineView: View {
    private static let timelineStart = Date()
    let session: SessionRecord
    let payloadStore: PayloadStore
    @Bindable var preferences: BrowsePreferences
    @State private var presentation: TimelinePresentation = .turns

    @State private var filter = TimelineFilter()
    @State private var selectedStepID: UUID?
    @State private var errorNavigationID = UUID()
    @State private var isInspectorVisible = true
    @State private var branchStep: StepRecord?
    @FocusState private var isSearchFocused: Bool

    private var orderedSteps: [StepRecord] {
        session.steps.sorted { $0.stepIndex < $1.stepIndex }
    }

    private var matchingSteps: [StepRecord] {
        orderedSteps.filter(filter.matches)
    }

    var body: some View {
        // Reuse one snapshot per render instead of re-sorting and re-filtering
        // the entire history for each toolbar, list, and inspector read.
        let orderedSteps = self.orderedSteps
        let matchingSteps = orderedSteps.filter(filter.matches)
        let selectedStep = matchingSteps.first(where: { $0.id == selectedStepID }) ?? matchingSteps.first
        let errorIndex = TimelineErrorIndex(orderedSteps: orderedSteps, filter: filter)
        let stepNavigation = TimelineStepNavigation(orderedIDs: matchingSteps.map(\.id), selection: selectedStep?.id)

        VStack(spacing: 0) {
            SwiftUI.TimelineView(.periodic(from: Self.timelineStart, by: SessionLiveness.tickInterval)) { context in
                SessionSummaryHeader(
                    summary: SessionSummary(session: session, steps: orderedSteps, now: context.date),
                    filePathQuery: $filter.filePathQuery
                )
            }

            TimelineToolbar(
                session: session,
                filter: $filter,
                presentation: $presentation,
                viewMode: $preferences.viewMode,
                resultCount: matchingSteps.count,
                totalCount: orderedSteps.count,
                errorCount: errorIndex.errorIDs.count,
                previousError: { navigateError(.previous, index: errorIndex, orderedSteps: orderedSteps) },
                nextError: { navigateError(.next, index: errorIndex, orderedSteps: orderedSteps) },
                isInspectorVisible: $isInspectorVisible,
                isSearchFocused: $isSearchFocused
            )
            TimelineActiveFilters(filter: $filter)
            Divider()

            if matchingSteps.isEmpty {
                VStack(spacing: 12) {
                    TimelineEmptyState(filter: filter)
                    if filter.isActive {
                        Button("Clear filters") { filter.reset() }
                            .buttonStyle(.bordered)
                            .padding(.bottom, 24)
                    }
                }
            } else {
                HSplitView {
                    TimelineStepList(
                        orderedSteps: orderedSteps, matchingSteps: matchingSteps, sessionStart: session.startDate, presentation: presentation,
                        viewMode: preferences.viewMode, selection: $selectedStepID, errorNavigationID: errorNavigationID
                    )
                    .frame(minWidth: 430)

                    if isInspectorVisible, let selectedStep {
                        StepDetailView(
                            step: selectedStep, payloadStore: payloadStore, viewMode: preferences.viewMode,
                            previousStep: stepNavigation.previous.map { id in { selectStep(id) } },
                            nextStep: stepNavigation.next.map { id in { selectStep(id) } }
                        ) {
                            branchStep = selectedStep
                        }
                        .id(selectedStep.id)
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
        .sheet(item: $branchStep) { step in
            BranchSessionSheet(step: step)
        }
    }

    private func navigateError(_ direction: TimelineErrorIndex.Direction, index: TimelineErrorIndex, orderedSteps: [StepRecord]) {
        guard let destination = index.destination(from: selectedStepID, direction: direction) else { return }
        // Keep the destination visible when the step-type picker excludes it.
        if let step = orderedSteps.first(where: { $0.id == destination }), !filter.matches(step) {
            filter.kindRawValue = "all"
            filter.preset = .all
        }
        selectStep(destination)
    }

    private func selectStep(_ id: UUID) {
        selectedStepID = id
        errorNavigationID = UUID()
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
    @Binding var presentation: TimelinePresentation
    @Binding var viewMode: BrowseViewMode
    let resultCount: Int
    let totalCount: Int
    let errorCount: Int
    let previousError: () -> Void
    let nextError: () -> Void
    @Binding var isInspectorVisible: Bool
    @FocusState.Binding var isSearchFocused: Bool
    @State private var isFilterPresented = false

    var body: some View {
        VStack(spacing: 10) {
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

                Picker("Timeline layout", selection: $presentation) {
                    ForEach(TimelinePresentation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .accessibilityLabel("Timeline layout")

                HStack(spacing: 6) {
                    Label(errorCount == 1 ? "1 error" : "\(errorCount) errors", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(errorCount > 0 ? .red : .secondary)
                        .accessibilityLabel("\(errorCount) errors matching search, file, and date filters across all step types")

                    Button("Previous error", systemImage: "chevron.up", action: previousError)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Go to previous error")
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Previous error (⌘[)")

                    Button("Next error", systemImage: "chevron.down", action: nextError)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Go to next error")
                        .keyboardShortcut("]", modifiers: .command)
                        .help("Next error (⌘])")
                }
                .buttonStyle(.borderless)
                .disabled(errorCount == 0)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.55), in: .capsule)

                Text("\(resultCount) of \(totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Showing \(resultCount) of \(totalCount) events")

                Button {
                    isInspectorVisible.toggle()
                } label: {
                    Image(systemName: isInspectorVisible ? "sidebar.right" : "rectangle")
                        .frame(minWidth: 28, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(isInspectorVisible ? "Hide step inspector" : "Show step inspector")
                .help(isInspectorVisible ? "Hide step inspector" : "Show step inspector")
            }
            HStack(spacing: 10) {
                Picker("Event category", selection: $filter.preset) {
                    ForEach(TimelineFilterPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .labelsHidden()
                .accessibilityLabel("Filter events by category")
                Spacer(minLength: 0)
                Picker("Detail level", selection: $viewMode) {
                    ForEach(BrowseViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .accessibilityLabel("Simple or technical detail")
                RelatedSessionsButton(session: session)
                Button("More filters", systemImage: "line.3.horizontal.decrease.circle") {
                    isFilterPresented.toggle()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Show more timeline filters")
                .popover(isPresented: $isFilterPresented, arrowEdge: .top) {
                    TimelineFilterPopover(filter: $filter)
                }
            }
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
    return TimelineView(session: session, payloadStore: PayloadStore(), preferences: BrowsePreferences())
        .frame(width: 1_100, height: 700)
        .modelContainer(for: SessionRecord.self, inMemory: true)
}
