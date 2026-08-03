import SwiftData
import SwiftUI

/// A compact lineage view showing the selected session and its trace branches.
struct BranchGraphView: View {
    let session: SessionRecord

    @Environment(AppStore.self) private var appStore
    @Query(sort: \SessionRecord.startDate, order: .reverse) private var sessions: [SessionRecord]

    private var parent: SessionRecord? {
        guard let parentID = session.parentSessionID else { return nil }
        return sessions.first(where: { $0.id == parentID })
    }

    private var children: [SessionRecord] {
        sessions.filter { $0.parentSessionID == session.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Branch lineage", systemImage: "arrow.triangle.branch")
                .font(.headline)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    if let parent {
                        BranchNode(session: parent, isCurrent: false) {
                            appStore.selectedSessionID = parent.id
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    BranchNode(session: session, isCurrent: true) { }
                }
                .padding(.vertical, 4)
            }

            if !children.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Child branches")
                        .font(.subheadline.weight(.medium))
                    ForEach(children) { child in
                        BranchNode(session: child, isCurrent: false) {
                            appStore.selectedSessionID = child.id
                        }
                    }
                }
            } else {
                Text("No child branches yet. Select a step and choose Create branch in the inspector.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 430)
    }
}

private struct BranchNode: View {
    let session: SessionRecord
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: session.agentType.systemImage)
                    Text(isCurrent ? "Current" : session.agentType.displayName)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text("\(session.stepCount) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            .padding(12)
            .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isCurrent ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.2))
            }
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .accessibilityLabel(isCurrent ? "Current branch, \(session.title)" : "Open branch, \(session.title)")
    }
}
