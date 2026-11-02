import SwiftUI

/// Names and persists a child trace branch created from a selected step.
struct BranchSessionSheet: View {
    let step: StepRecord
    /// Captured at presentation so the sheet never reads a step an import deleted.
    private let forkPoint: String

    @Environment(AppStore.self) private var appStore
    @Environment(\.dismiss) private var dismiss
    @State private var branchName: String
    @State private var errorMessage: String?
    @State private var isCreating = false

    init(step: StepRecord) {
        self.step = step
        forkPoint = "Step \(step.stepIndex + 1): \(step.title)"
        _branchName = State(initialValue: "Branch at step \(step.stepIndex + 1)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Create trace branch", systemImage: "arrow.triangle.branch")
                    .font(.title3.weight(.semibold))
                Text("AgentTrail will copy the trace through this step into a new local session. Payload blobs are reused, not duplicated.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Branch name", text: $branchName)
                LabeledContent("Fork point", value: forkPoint)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Create branch") {
                    Task { await createBranch() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 520)
    }

    private func createBranch() async {
        isCreating = true
        defer { isCreating = false }
        guard !step.isDeleted, step.modelContext != nil else {
            errorMessage = "This step is no longer in the library. Close this sheet and choose another step."
            return
        }
        do {
            _ = try await appStore.createBranch(from: step, named: branchName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
