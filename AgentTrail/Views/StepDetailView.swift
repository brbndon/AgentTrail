import SwiftUI

/// Shows the complete normalized metadata and on-disk payload for one trace step.
struct StepDetailView: View {
    let step: StepRecord
    let onCreateBranch: () -> Void
    let viewMode: BrowseViewMode
    let previousStep: (() -> Void)?
    let nextStep: (() -> Void)?

    @State private var payloadText: String?
    @State private var payloadWasTruncated = false
    @State private var isLoadingPayload = false
    @State private var payloadErrorMessage: String?
    @State private var payloadLoadID = UUID()
    @State private var isPayloadExpanded = false
    let payloadStore: PayloadStore

    init(
        step: StepRecord, payloadStore: PayloadStore, viewMode: BrowseViewMode = .technical,
        previousStep: (() -> Void)? = nil, nextStep: (() -> Void)? = nil, onCreateBranch: @escaping () -> Void
    ) {
        self.step = step
        self.payloadStore = payloadStore
        self.onCreateBranch = onCreateBranch
        self.viewMode = viewMode
        self.previousStep = previousStep
        self.nextStep = nextStep
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let command = step.commandText, !command.isEmpty {
                    CommandBlockView(command: command, exitCode: step.exitCode)
                }
                summary
                if !step.fileChanges.isEmpty {
                    DetailSection(title: "File changes") {
                        ForEach(step.fileChanges) { change in
                            FileChangeDiffView(change: change, payloadStore: payloadStore)
                        }
                    }
                }
                metadata
                if viewMode == .technical { rawPayload }
            }
            .padding(22)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: viewMode == .technical && isPayloadExpanded ? step.id : nil) {
            guard viewMode == .technical, isPayloadExpanded else {
                payloadLoadID = UUID()
                return
            }
            await loadPayload()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(step.kind.plainLanguageName)
                        .font(.headline)
                    if step.hasError {
                        Label("Error recorded", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text(step.title)
                        .font(.callout)
                        .textSelection(.enabled)
                    if viewMode == .technical {
                        Text("Step \(step.stepIndex + 1)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu("Step actions", systemImage: "ellipsis.circle") {
                    Button("Create branch", systemImage: "arrow.triangle.branch", action: onCreateBranch)
                        .accessibilityLabel("Create a branch through this step")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Step actions")
            }
            HStack {
                Button("Previous", systemImage: "chevron.left") { previousStep?() }
                    .disabled(previousStep == nil)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .help("Previous matching event (⌥⌘←)")
                    .accessibilityLabel("Inspect previous matching event")
                Spacer(minLength: 8)
                Button("Next", systemImage: "chevron.right") { nextStep?() }
                    .disabled(nextStep == nil)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .help("Next matching event (⌥⌘→)")
                    .accessibilityLabel("Inspect next matching event")
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailMetadataRow(title: "Timestamp", value: step.timestamp.formatted(date: .abbreviated, time: .standard))
            if let path = step.filePath, !path.isEmpty {
                DetailMetadataRow(title: "File", value: path)
            }
            if step.commandText == nil, let exitCode = step.exitCode {
                DetailMetadataRow(title: "Exit code", value: "\(exitCode)")
            }
            if viewMode == .technical, let tokenCount = step.tokenCount {
                DetailMetadataRow(title: "Tokens", value: tokenCount.formatted())
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary)
        }
    }

    private var summary: some View {
        DetailSection(title: "Summary") {
            Text(step.contentSummary)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private var rawPayload: some View {
        DisclosureGroup(isExpanded: $isPayloadExpanded) {
            rawPayloadContent
                .padding(.top, 9)
        } label: {
            Text("Original data (JSON)")
                .font(.headline)
        }
        .accessibilityLabel("Original data in JSON format")
    }

    @ViewBuilder
    private var rawPayloadContent: some View {
        if isLoadingPayload {
            ProgressView("Loading payload…")
                .controlSize(.small)
        } else if let payloadText {
            Text(payloadText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if payloadWasTruncated {
                Text("Payload preview truncated at 4 MB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let payloadErrorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(payloadErrorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task {
                        let loadID = UUID()
                        payloadLoadID = loadID
                        await loadPayload(loadID: loadID)
                    }
                }
                .buttonStyle(.bordered)
            }
        } else {
            Text("The original payload is unavailable for this step.")
                .foregroundStyle(.secondary)
        }
    }

    private func loadPayload() async {
        let loadID = UUID()
        payloadLoadID = loadID
        await loadPayload(loadID: loadID)
    }

    private func loadPayload(loadID: UUID) async {
        guard payloadLoadID == loadID else { return }
        guard let reference = step.fullPayloadRef else {
            payloadText = nil
            payloadWasTruncated = false
            payloadErrorMessage = nil
            isLoadingPayload = false
            return
        }

        isLoadingPayload = true
        payloadText = nil
        payloadWasTruncated = false
        payloadErrorMessage = nil
        defer {
            if payloadLoadID == loadID { isLoadingPayload = false }
        }
        do {
            let result = try await payloadStore.read(key: reference)
            guard !Task.isCancelled, payloadLoadID == loadID else { return }
            guard let text = String(data: result.data, encoding: .utf8) else {
                payloadText = nil
                payloadWasTruncated = false
                payloadErrorMessage = "The payload is not valid UTF-8."
                return
            }
            payloadText = text
            payloadWasTruncated = result.isTruncated
        } catch is CancellationError {
            return
        } catch {
            guard payloadLoadID == loadID else { return }
            payloadText = nil
            payloadWasTruncated = false
            payloadErrorMessage = (error as? LocalizedError)?.errorDescription ?? "The payload could not be loaded."
        }
    }
}

private struct DetailMetadataRow: View {
    let title: String
    let value: String
    var isMonospaced = false

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(isMonospaced ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InspectorPreview: View {
    var body: some View {
        let step = StepRecord(
            stepIndex: 4,
            kind: .toolCall,
            timestamp: .now,
            title: "Run focused tests",
            contentSummary: "swift test --filter ParserTests",
            searchText: "run focused tests swift test ParserTests",
            fullPayloadRef: nil,
            hasError: false,
            commandText: "swift test --filter ParserTests",
            exitCode: 0
        )
        return StepDetailView(step: step, payloadStore: PayloadStore()) {}
            .frame(width: 420, height: 620)
    }
}

#Preview("Step detail · Light") {
    InspectorPreview().preferredColorScheme(.light)
}

#Preview("Step detail · Dark") {
    InspectorPreview().preferredColorScheme(.dark)
}
