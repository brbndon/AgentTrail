import AppKit
import SwiftUI

struct CommandBlockView: View {
    let command: String
    let exitCode: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Command").font(.headline)
                Spacer(minLength: 8)
                if let exitCode {
                    Label("Exit \(exitCode)", systemImage: exitCode == 0 ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                        .accessibilityLabel(exitCode == 0 ? "Command succeeded, exit code 0" : "Command failed, exit code \(exitCode)")
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .accessibilityLabel("Copy command")
            }
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}
