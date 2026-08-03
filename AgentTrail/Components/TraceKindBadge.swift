import SwiftUI

/// A compact, accessible label for a normalized trace event kind.
struct TraceKindBadge: View {
    let kind: StepKind
    let hasError: Bool
    var showsLabel = true

    var body: some View {
        Group {
            if showsLabel {
                Label(kind.displayName, systemImage: kind.systemImage)
            } else {
                Label(kind.displayName, systemImage: kind.systemImage)
                    .labelStyle(.iconOnly)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(hasError ? .red : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasError ? "Error, \(kind.displayName)" : kind.displayName)
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
