import SwiftUI

struct TimelineStepList: View {
    let orderedSteps: [StepRecord]
    let matchingSteps: [StepRecord]
    let sessionStart: Date
    let presentation: TimelinePresentation
    let viewMode: BrowseViewMode
    @Binding var selection: UUID?
    let errorNavigationID: UUID

    var body: some View {
        let visibleIDs = Set(matchingSteps.map(\.id))
        let turns = TimelineTurn.group(orderedSteps: orderedSteps)
        let selectedBlockID = TimelineTurn.workBlockID(containing: selection, in: turns, visibleIDs: visibleIDs)
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if presentation == .events {
                    ForEach(matchingSteps) { step in row(step) }
                } else {
                    ForEach(turns) { turn in
                        ForEach(turn.blocks) { block in
                            let visibleSteps = block.matchingSteps(visibleIDs)
                            if !visibleSteps.isEmpty {
                                if block.isMessage, let message = visibleSteps.first {
                                    row(message, fullMessage: true)
                                } else {
                                    TimelineWorkBlock(
                                        block: block, visibleSteps: visibleSteps, sessionStart: sessionStart,
                                        viewMode: viewMode, containsSelection: selectedBlockID == block.id, navigationID: errorNavigationID)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
            .task(id: "\(selection?.uuidString ?? "none")-\(errorNavigationID)-\(presentation.rawValue)-\(matchingSteps.count)") {
                // A selected action first expands its disclosure, then receives
                // its scroll target on the following layout pass.
                await Task.yield()
                await Task.yield()
                guard !Task.isCancelled, let selection else { return }
                proxy.scrollTo(selection)
            }
        }
    }

    private func row(_ step: StepRecord, fullMessage: Bool = false) -> some View {
        TimelineStepRow(step: step, sessionStart: sessionStart, viewMode: viewMode, showsFullMessage: fullMessage)
            .id(step.id)
            .tag(step.id)
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            .listRowSeparator(.hidden)
    }
}

private struct TimelineWorkBlock: View {
    let block: TimelineTurn.Block
    let visibleSteps: [StepRecord]
    let sessionStart: Date
    let viewMode: BrowseViewMode
    let containsSelection: Bool
    let navigationID: UUID
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(visibleSteps) { step in
                TimelineStepRow(step: step, sessionStart: sessionStart, viewMode: viewMode)
                    .id(step.id)
                    .tag(step.id)
                    .listRowSeparator(.hidden)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(block.summary, systemImage: block.hasError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(block.hasError ? .red : .secondary)
                if visibleSteps.count != block.steps.count {
                    Text("\(visibleSteps.count) of \(block.steps.count) events match filters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityLabel("Work: \(block.summary)")
        .onAppear { if containsSelection { isExpanded = true } }
        .onChange(of: containsSelection) { _, _ in if containsSelection { isExpanded = true } }
        .onChange(of: navigationID) { _, _ in if containsSelection { isExpanded = true } }
        .listRowSeparator(.hidden)
    }
}
