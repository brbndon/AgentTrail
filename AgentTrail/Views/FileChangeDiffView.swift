import SwiftUI

struct FileChangeDiffView: View {
    let change: FileChangeRecord
    let payloadStore: PayloadStore
    @State private var isExpanded = false
    @State private var preview: FileChangeDiffPreview?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            FileChangeDiffContent(preview: preview, path: change.path)
                .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(change.path).font(.callout.monospaced()).textSelection(.enabled)
                Text(change.changeTypeRawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("File change: \(change.path), \(change.changeTypeRawValue)")
        .task(id: "\(isExpanded):\(change.diffStorageKey ?? "none")") {
            guard isExpanded else {
                preview = nil
                return
            }
            let loaded = await FileChangeDiffPreview.load(key: change.diffStorageKey, path: change.path, store: payloadStore)
            guard !Task.isCancelled else { return }
            preview = loaded
        }
    }
}

struct FileChangeDiffContent: View {
    let preview: FileChangeDiffPreview?
    let path: String

    var body: some View {
        Group {
            switch preview {
            case .none:
                ProgressView("Loading diff…")
            case .available(let diff):
                VStack(alignment: .leading, spacing: 8) {
                    Text(diff.format == .unifiedDiff ? "Recorded diff" : "Added file contents")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ScrollView([.horizontal, .vertical]) {
                        Text(diff.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 240)
                    .defaultScrollAnchor(.topLeading, for: .alignment)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Recorded changes to \(path)")
                    if diff.isTruncated {
                        Text("Diff preview truncated at 128,000 characters or 2,000 lines.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Diff unavailable", systemImage: "doc.questionmark")
                } description: {
                    Text(reason)
                }
            }
        }
        .padding(.top, 8)
    }
}

#Preview("Diff · Light") {
    FileChangeDiffContent(
        preview: .available(FileChangeDiff(text: "@@ -1 +1 @@\n-old\n+new", format: .unifiedDiff, isTruncated: false)), path: "Sources/App.swift"
    )
    .padding().frame(width: 440, height: 320).preferredColorScheme(.light)
}

#Preview("Diff · Dark") {
    FileChangeDiffContent(
        preview: .available(FileChangeDiff(text: "@@ -1 +1 @@\n-old\n+new", format: .unifiedDiff, isTruncated: false)), path: "Sources/App.swift"
    )
    .padding().frame(width: 440, height: 320).preferredColorScheme(.dark)
}
