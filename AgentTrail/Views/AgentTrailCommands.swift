import SwiftUI

struct AgentTrailCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find in Timeline") {
                NotificationCenter.default.post(name: .agentTrailFocusTimelineSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
