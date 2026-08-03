import SwiftUI

struct SessionOverviewView: View {
    let session: SessionRecord

    private var statusIcon: String {
        if session.sourceState == .degraded {
            return "exclamationmark.triangle"
        }
        switch session.status {
        case .failed: return "xmark.circle"
        case .unavailable: return "questionmark.circle"
        case .recording: return "record.circle"
        case .historical: return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        if session.sourceState == .degraded {
            return .orange
        }
        switch session.status {
        case .failed: return .red
        case .unavailable: return .orange
        case .recording: return .accentColor
        case .historical: return .secondary
        }
    }

    private var orderedSteps: [StepRecord] {
        session.steps.sorted { $0.stepIndex < $1.stepIndex }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                metadata
                importedEvents
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(32)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(session.title)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: session.agentType.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 54, height: 54)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.title2.weight(.semibold))
                Text("\(session.agentType.displayName) trace")
                    .foregroundStyle(.secondary)
                Text(session.workingDirectory.isEmpty ? session.sourcePath : session.workingDirectory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer()
            Label(statusLabel, systemImage: statusIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .accessibilityLabel("Session status: \(statusLabel)")
        }
    }

    private var statusLabel: String {
        if session.sourceState == .degraded {
            return "Degraded"
        }
        return session.status.rawValue.capitalized
    }

    private var metadata: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 14) {
            MetadataTile(title: "Events", value: "\(session.stepCount)", systemImage: "list.number")
            MetadataTile(title: "Started", value: session.startDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            MetadataTile(title: "Updated", value: session.sourceModifiedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "arrow.triangle.2.circlepath")
            MetadataTile(title: "Storage", value: "Local only", systemImage: "lock.shield")
        }
    }

    private var importedEvents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Imported events")
                    .font(.headline)
                Spacer()
                if orderedSteps.count > 12 {
                    Text("Showing first 12 of \(orderedSteps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if orderedSteps.isEmpty {
                Text("This session did not contain any parseable events yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(orderedSteps.prefix(12)) { step in
                        StepPreviewRow(step: step)
                        if step.id != orderedSteps.prefix(12).last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .background(.background, in: .rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary)
                }
            }
        }
    }
}

private struct MetadataTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary)
        }
    }
}

private struct StepPreviewRow: View {
    let step: StepRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: step.kind.systemImage)
                .foregroundStyle(step.hasError ? .red : .secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.55), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.kind.displayName)
                        .font(.callout.weight(.medium))
                    Text("#\(step.stepIndex + 1)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(step.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(step.contentSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}
