import SwiftUI

struct SettingsView: View {
    let directories: AgentDirectories
    let payloadStore: PayloadStore

    init(directories: AgentDirectories, payloadStore: PayloadStore) {
        self.directories = directories
        self.payloadStore = payloadStore
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Codex sessions") {
                    Text(directories.codexSessions.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Watched location")
            } footer: {
                Text("AgentTrail currently watches Codex history and imports it in newest-first pages of 30 threads.")
            }

            Section {
                LabeledContent("Grok Build sessions") {
                    Text(directories.grokSessions.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Cursor projects") {
                    Text(directories.cursorProjects.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Experimental parsers")
            } footer: {
                Text("Grok Build and Cursor parsing remains in the project, but these sources are not scanned by the user-facing app yet.")
            }

            Section {
                LabeledContent("Payload storage") {
                    Text(payloadStore.location.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Label("AgentTrail never sends trace content anywhere.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
    }
}
