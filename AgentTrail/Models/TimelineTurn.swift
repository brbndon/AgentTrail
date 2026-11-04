import Foundation

/// Groups before filtering so hidden user messages never merge separate turns.
struct TimelineTurn: Identifiable {
    let id: UUID
    let blocks: [Block]

    struct Block: Identifiable {
        let steps: [StepRecord]
        var id: UUID { steps[0].id }
        var isMessage: Bool { steps[0].kind == .user || steps[0].kind == .assistant }
        var hasError: Bool { steps.contains(where: \.hasError) }

        var summary: String {
            let commands = steps.filter { $0.kind == .shellCommand }.count
            let files = Set(
                steps.flatMap { step in
                    (step.filePath.map { [$0] } ?? []) + step.fileChanges.map(\.path)
                }.filter { !$0.isEmpty }
            ).count
            let errors = steps.filter(\.hasError).count
            var parts: [String] = []
            if commands > 0 { parts.append("Ran \(commands) \(commands == 1 ? "command" : "commands")") }
            if files > 0 { parts.append("touched \(files) \(files == 1 ? "file" : "files")") }
            let otherActions = steps.filter { $0.kind != .shellCommand && $0.kind != .fileChange }.count
            if otherActions > 0 { parts.append("\(otherActions) other \(otherActions == 1 ? "event" : "events")") }
            if parts.isEmpty { parts.append("\(steps.count) work \(steps.count == 1 ? "event" : "events")") }
            if errors > 0 { parts.append("\(errors) \(errors == 1 ? "error" : "errors")") }
            return parts.joined(separator: ", ")
        }

        func matchingSteps(_ visibleIDs: Set<UUID>) -> [StepRecord] {
            steps.filter { visibleIDs.contains($0.id) }
        }
    }

    static func group(orderedSteps: [StepRecord]) -> [TimelineTurn] {
        var turns: [[StepRecord]] = []
        for step in orderedSteps {
            if turns.isEmpty || step.kind == .user { turns.append([]) }
            turns[turns.count - 1].append(step)
        }
        return turns.map { steps in
            var blocks: [[StepRecord]] = []
            for step in steps {
                let isMessage = step.kind == .user || step.kind == .assistant
                if isMessage || blocks.isEmpty || blocks.last?.last?.kind == .user || blocks.last?.last?.kind == .assistant {
                    blocks.append([step])
                } else {
                    blocks[blocks.count - 1].append(step)
                }
            }
            return TimelineTurn(id: steps[0].id, blocks: blocks.map { Block(steps: $0) })
        }
    }

    static func workBlockID(containing selection: UUID?, in turns: [TimelineTurn], visibleIDs: Set<UUID>) -> UUID? {
        guard let selection, visibleIDs.contains(selection) else { return nil }
        return turns.lazy.flatMap(\.blocks).first { !$0.isMessage && $0.steps.contains { $0.id == selection } }?.id
    }
}

enum TimelinePresentation: String, CaseIterable, Identifiable {
    case turns, events
    var id: String { rawValue }
    var title: String { self == .turns ? "Turns" : "All events" }
}
