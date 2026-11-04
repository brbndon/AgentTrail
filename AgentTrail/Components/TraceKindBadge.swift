import SwiftUI

/// A compact, accessible label for a normalized trace event kind.
struct TraceKindBadge: View {
    let kind: StepKind
    let hasError: Bool
    var showsLabel = true
    var viewMode: BrowseViewMode = .technical

    private var title: String { viewMode == .simple ? kind.plainLanguageName : kind.displayName }

    var body: some View {
        Group {
            if showsLabel {
                Label(title, systemImage: kind.systemImage)
            } else {
                Label(title, systemImage: kind.systemImage)
                    .labelStyle(.iconOnly)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(hasError ? .red : kind.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((hasError ? Color.red : kind.tint).opacity(0.12), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasError ? "Error, \(title)" : title)
    }
}

extension StepKind {
    var tint: Color {
        switch self {
        case .user: .blue
        case .assistant: .teal
        case .thought: .purple
        case .toolCall: .orange
        case .toolResult: .indigo
        case .fileChange: .green
        case .shellCommand: .brown
        case .error: .red
        case .system: .secondary
        }
    }
}

#Preview("Trace kind badges") {
    VStack(alignment: .leading, spacing: 12) {
        TraceKindBadge(kind: .user, hasError: false)
        TraceKindBadge(kind: .toolCall, hasError: false)
        TraceKindBadge(kind: .error, hasError: true)
    }
    .padding()
}
