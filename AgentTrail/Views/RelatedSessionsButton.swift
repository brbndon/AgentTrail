import SwiftData
import SwiftUI

/// Fetch only enough lineage metadata to decide whether the graph is useful.
struct RelatedSessionsButton: View {
    let session: SessionRecord
    @Query private var children: [SessionRecord]
    @State private var isPresented = false

    init(session: SessionRecord) {
        self.session = session
        let id = session.id
        var descriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.parentSessionID == id })
        descriptor.fetchLimit = 1
        _children = Query(descriptor)
    }

    var body: some View {
        if session.parentSessionID != nil || !children.isEmpty {
            Button("Related sessions", systemImage: "arrow.triangle.branch") { isPresented.toggle() }
                .buttonStyle(.bordered)
                .accessibilityLabel("Show related sessions")
                .popover(isPresented: $isPresented, arrowEdge: .top) { BranchGraphView(session: session) }
        }
    }
}
