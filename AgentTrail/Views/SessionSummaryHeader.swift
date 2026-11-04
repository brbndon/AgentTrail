import SwiftUI

/// Keeps the session's request and result visible above its individual events.
struct SessionSummaryHeader: View {
    let summary: SessionSummary
    @Binding var filePathQuery: String
    @AppStorage("timeline.sessionSummaryExpanded") private var isExpanded = true

    private var outcomeTitle: String {
        switch summary.outcome {
        case .completed: "Completed"
        case .hasErrors(let count): count == 1 ? "1 error" : "\(count) errors"
        case .running: "Running"
        }
    }

    private var outcomeSymbol: String {
        switch summary.outcome {
        case .completed: "checkmark.circle"
        case .hasErrors: "exclamationmark.triangle"
        case .running: "record.circle"
        }
    }

    private var outcomeColor: Color {
        switch summary.outcome {
        case .completed: .secondary
        case .hasErrors: .red
        case .running: .accentColor
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryMessage("Request", text: summary.originalRequest ?? "No request recorded.")
                    summaryMessage("Result", text: summary.finalAssistantMessage ?? "No assistant reply recorded.")

                    if !summary.filesTouched.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Files touched")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading, spacing: 6) {
                                ForEach(summary.filesTouched, id: \.self) { path in
                                    Button {
                                        filePathQuery = path
                                    } label: {
                                        Label(path, systemImage: "doc")
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                    .help(path)
                                    .accessibilityLabel("Filter timeline by file \(path)")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 240)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    heading
                    Spacer(minLength: 8)
                    metrics
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    metrics
                }
            }
        }
        .accessibilityLabel("Session summary")
        .padding(14)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var heading: some View {
        HStack(spacing: 10) {
            Text("Session summary")
                .font(.headline)
            Label(outcomeTitle, systemImage: outcomeSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(outcomeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
                .accessibilityLabel("Session outcome: \(outcomeTitle)")
        }
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            Label(
                Duration.seconds(summary.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)),
                systemImage: "clock"
            )
            .accessibilityLabel(
                "Session duration: \(Duration.seconds(summary.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)))"
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: .capsule)
            Label("\(summary.stepCount) steps", systemImage: "list.number")
                .accessibilityLabel("\(summary.stepCount) steps in session")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
            Label("\(summary.filesTouched.count) files", systemImage: "doc.on.doc")
                .accessibilityLabel("\(summary.filesTouched.count) distinct files touched")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private func summaryMessage(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
    }
}

#Preview("Session summary · Light") {
    SessionSummaryHeader(summary: SessionSummaryPreview.summary, filePathQuery: .constant(""))
        .frame(width: 850, height: 330, alignment: .top)
        .preferredColorScheme(.light)
}

#Preview("Session summary · Dark") {
    SessionSummaryHeader(summary: SessionSummaryPreview.summary, filePathQuery: .constant(""))
        .frame(width: 850, height: 330, alignment: .top)
        .preferredColorScheme(.dark)
}

#Preview("Session summary · Empty") {
    let session = SessionRecord(
        sourceKey: "preview:empty", agentType: .codex, title: "Empty session",
        startDate: .now, endDate: nil, workingDirectory: "/tmp/AgentTrail",
        sourcePath: "/tmp/empty.jsonl", sourceModifiedAt: .distantPast
    )
    SessionSummaryHeader(summary: SessionSummary(session: session, steps: [], now: .now), filePathQuery: .constant(""))
        .frame(width: 600, height: 260, alignment: .top)
}

private enum SessionSummaryPreview {
    static var summary: SessionSummary {
        let now = Date.now
        let session = SessionRecord(
            sourceKey: "preview:summary", agentType: .codex, title: "Repair ingestion",
            startDate: now.addingTimeInterval(-1_800), endDate: now.addingTimeInterval(-600),
            workingDirectory: "/tmp/AgentTrail", sourcePath: "/tmp/summary.jsonl",
            sourceModifiedAt: now.addingTimeInterval(-600)
        )
        let request = StepRecord(
            stepIndex: 0, kind: .user, timestamp: session.startDate,
            title: "Repair ingestion", contentSummary: "Find why the live session stopped importing events.",
            searchText: "", fullPayloadRef: nil, hasError: false)
        let error = StepRecord(
            stepIndex: 1, kind: .toolResult, timestamp: now.addingTimeInterval(-900),
            title: "Tests failed", contentSummary: "The first regression test exposed an incomplete record.",
            searchText: "", fullPayloadRef: nil, hasError: true, filePath: "Tests/ParserTests.swift")
        let reply = StepRecord(
            stepIndex: 2, kind: .assistant, timestamp: now.addingTimeInterval(-600),
            title: "Fixed ingestion", contentSummary: "Updated the parser to resume after incomplete records. All tests now pass.",
            searchText: "", fullPayloadRef: nil, hasError: false, filePath: "Sources/Parser.swift")
        return SessionSummary(session: session, steps: [request, error, reply], now: now)
    }
}
