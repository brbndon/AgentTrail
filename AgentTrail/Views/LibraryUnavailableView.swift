import AppKit
import SwiftUI

struct LibraryUnavailableView: View {
    let issue: LibraryAccessIssue

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
            Text(recoveryMessage)
                .foregroundStyle(.secondary)
        } actions: {
            if case .ownedByAnotherProcess(let owner) = issue,
               let processIdentifier = owner?.processIdentifier {
                Button("Show Other Copy") {
                    showOwner(processIdentifier: processIdentifier)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private var title: String {
        switch issue {
        case .ownedByAnotherProcess:
            "Library Already Open"
        case .unavailable:
            "Local Library Unavailable"
        }
    }

    private var message: String {
        switch issue {
        case .ownedByAnotherProcess(let owner):
            if let owner {
                "Another AgentTrail \(owner.copyDescription) is using this library. Only one copy can import or edit it at a time."
            } else {
                "Another AgentTrail copy is using this library. Only one copy can import or edit it at a time."
            }
        case .unavailable(let message):
            message
        }
    }

    private var recoveryMessage: String {
        switch issue {
        case .ownedByAnotherProcess:
            "Use the other copy, or quit it and reopen this one. Your existing library has not been changed."
        case .unavailable:
            "Quit AgentTrail, check the AgentTrail folder in Application Support, then try again. Existing data was left untouched."
        }
    }

    private func showOwner(processIdentifier: Int32) {
        NSRunningApplication(processIdentifier: pid_t(processIdentifier))?
            .activate(options: [.activateAllWindows])
    }
}
