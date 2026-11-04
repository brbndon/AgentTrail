import Foundation

/// A local coding agent whose trace format AgentTrail understands.
enum AgentType: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case grokBuild
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .grokBuild: "Grok Build"
        case .cursor: "Cursor Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "terminal"
        case .grokBuild: "sparkles"
        case .cursor: "cursorarrow.rays"
        }
    }

    var tintName: String {
        switch self {
        case .codex: "indigo"
        case .grokBuild: "orange"
        case .cursor: "mint"
        }
    }
}

/// The normalized kinds of events that can appear in an agent trace.
enum StepKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case user
    case assistant
    case thought
    case toolCall
    case toolResult
    case fileChange
    case shellCommand
    case error
    case system

    var id: String { rawValue }

    var plainLanguageName: String {
        switch self {
        case .user: "Your request"
        case .assistant: "Agent reply"
        case .thought: "Thinking"
        case .toolCall: "Used a tool"
        case .toolResult: "Tool output"
        case .fileChange: "Edited a file"
        case .shellCommand: "Ran a command"
        case .error: "Something went wrong"
        case .system: "Session update"
        }
    }

    var displayName: String {
        switch self {
        case .user: "User message"
        case .assistant: "Assistant"
        case .thought: "Reasoning"
        case .toolCall: "Tool call"
        case .toolResult: "Tool result"
        case .fileChange: "File change"
        case .shellCommand: "Shell command"
        case .error: "Error"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .user: "person"
        case .assistant: "bubble.left"
        case .thought: "brain"
        case .toolCall: "wrench.and.screwdriver"
        case .toolResult: "arrow.down.doc"
        case .fileChange: "doc.badge.gearshape"
        case .shellCommand: "chevron.left.forwardslash.chevron.right"
        case .error: "exclamationmark.triangle"
        case .system: "gearshape"
        }
    }
}
