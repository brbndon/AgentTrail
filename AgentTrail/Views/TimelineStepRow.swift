import SwiftUI

struct TimelineStepRow: View {
    let step: StepRecord
    let sessionStart: Date
    var viewMode: BrowseViewMode = .technical
    var showsFullMessage = false

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
                    TraceKindBadge(kind: step.kind, hasError: step.hasError, viewMode: viewMode)
                    if viewMode == .technical {
                        Text("#\(step.stepIndex + 1)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(TimelineElapsedTime.label(timestamp: step.timestamp, sessionStart: sessionStart))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(step.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(showsFullMessage ? nil : 1)

                Text(step.contentSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(showsFullMessage ? nil : 2)
                    .textSelection(.enabled)

                if viewMode == .technical, let command = step.commandText {
                    Text(command)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    if let path = step.filePath, !path.isEmpty {
                        Label(path, systemImage: "doc")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: .rect(cornerRadius: 8))
                    }
                    if let exitCode = step.exitCode, exitCode != 0 {
                        Label("Exit \(exitCode)", systemImage: "exclamationmark.circle")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: .rect(cornerRadius: 8))
                    } else if step.hasError {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(step.hasError ? .red : .secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            viewMode == .simple ? "\(step.kind.plainLanguageName), \(step.title)" : "Step \(step.stepIndex + 1), \(step.kind.displayName), \(step.title)"
        )
        .accessibilityValue(step.hasError ? "Error" : step.contentSummary)
    }
}
