import CryptoKit
import Foundation

struct ParsedFileChange: Sendable {
    let path: String
    let changeType: String
    let beforeHash: String?
    let afterHash: String?
    let hasDiff: Bool

    init(
        path: String,
        changeType: String,
        beforeHash: String? = nil,
        afterHash: String? = nil,
        hasDiff: Bool = false
    ) {
        self.path = TraceLimits.required(path, to: TraceLimits.path)
        self.changeType = TraceLimits.required(changeType, to: TraceLimits.eventType, fallback: "modified")
        self.beforeHash = TraceLimits.bounded(beforeHash, to: TraceLimits.hash)
        self.afterHash = TraceLimits.bounded(afterHash, to: TraceLimits.hash)
        self.hasDiff = hasDiff
    }
}

/// The lightweight value produced by an agent parser before SwiftData insertion.
struct ParsedStep: Sendable {
    let identity: String
    let index: Int
    let kind: StepKind
    let timestamp: Date
    let title: String
    let summary: String
    let searchText: String
    let payloadReference: String?
    let hasError: Bool
    let commandText: String?
    let filePath: String?
    let exitCode: Int?
    let tokenCount: Int?
    let fileChanges: [ParsedFileChange]

    init(
        identity: String,
        index: Int,
        kind: StepKind,
        timestamp: Date,
        title: String,
        summary: String,
        searchText: String,
        payloadReference: String?,
        hasError: Bool,
        commandText: String? = nil,
        filePath: String? = nil,
        exitCode: Int? = nil,
        tokenCount: Int? = nil,
        fileChanges: [ParsedFileChange] = []
    ) {
        self.identity = TraceLimits.required(identity, to: TraceLimits.identity)
        self.index = TraceLimits.boundedNonNegative(index)
        self.kind = kind
        self.timestamp = timestamp
        self.title = TraceLimits.required(title, to: TraceLimits.title, fallback: kind.displayName)
        self.summary = TraceLimits.required(summary, to: TraceLimits.summary)
        self.searchText = TraceLimits.search(searchText)
        self.payloadReference = TraceLimits.bounded(payloadReference, to: TraceLimits.identity)
        self.hasError = hasError
        self.commandText = TraceLimits.bounded(commandText, to: TraceLimits.command)
        self.filePath = TraceLimits.bounded(filePath, to: TraceLimits.path)
        self.exitCode = exitCode.map(TraceLimits.boundedInteger)
        self.tokenCount = tokenCount.map(TraceLimits.boundedNonNegative)
        self.fileChanges = Array(fileChanges.prefix(TraceLimits.maxFileChanges))
    }
}

/// A complete normalized session ready to be persisted on the main actor.
struct ParsedSession: Sendable {
    let sourceKey: String
    let agentType: AgentType
    let title: String
    let startDate: Date
    let endDate: Date?
    let workingDirectory: String
    let sourcePath: String
    let sourceModifiedAt: Date
    let status: SessionStatus
    let sourceState: SessionSourceState
    let projectIdentity: String
    let projectPath: String
    let projectName: String
    let steps: [ParsedStep]

    init(
        sourceKey: String,
        agentType: AgentType,
        title: String,
        startDate: Date,
        endDate: Date?,
        workingDirectory: String,
        sourcePath: String,
        sourceModifiedAt: Date,
        status: SessionStatus,
        sourceState: SessionSourceState = .scanned,
        projectIdentity: String,
        projectPath: String,
        projectName: String,
        steps: [ParsedStep]
    ) {
        self.sourceKey = TraceLimits.required(sourceKey, to: TraceLimits.sourceKey)
        self.agentType = agentType
        self.title = TraceLimits.required(title, to: TraceLimits.title, fallback: "Untitled session")
        self.startDate = startDate
        self.endDate = endDate
        self.workingDirectory = TraceLimits.required(workingDirectory, to: TraceLimits.path)
        self.sourcePath = TraceLimits.required(sourcePath, to: TraceLimits.path)
        self.sourceModifiedAt = sourceModifiedAt
        self.status = status
        self.sourceState = sourceState
        self.projectIdentity = TraceLimits.required(projectIdentity, to: TraceLimits.identity)
        self.projectPath = TraceLimits.required(projectPath, to: TraceLimits.path)
        self.projectName = TraceLimits.required(projectName, to: TraceLimits.projectName, fallback: "Unknown project")
        self.steps = Array(steps.prefix(TraceLimits.maxSteps))
    }
}

enum TraceParserError: LocalizedError, Sendable {
    case unavailable(URL)
    case sourceChanged(URL)
    case malformedOnly(URL)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The source is unavailable."
        case .sourceChanged: "The source changed while it was being scanned."
        case .malformedOnly: "The source contained only malformed or unreadable records."
        }
    }
}

extension TraceLimits {
    static let maxFileChanges = 256
    static let maxSteps = 100_000
}

enum StableTraceIdentity {
    /// Hashes the exact source bytes. A rewrite therefore creates a new
    /// reconciliation key even if the source reuses its event identifier.
    static func payloadDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a fixed-size identity. Explicit IDs and digests are hashed
    /// together so long IDs cannot truncate the digest away.
    static func baseIdentity(record: [String: Any], rawPayload: Data) -> String {
        let digest = payloadDigest(rawPayload)
        let explicitID = JSONLineSupport.firstString(
            in: record,
            keys: [
                "id", "event_id", "eventId", "eventID", "uuid", "message_id", "messageId",
                "call_id", "callId", "request_id", "requestId", "sequence_id", "sequenceId"
            ]
        )
        if let explicitID, !explicitID.isEmpty {
            let composite = Data("event:\(explicitID)\0\(digest)".utf8)
            return "event:\(payloadDigest(composite))"
        }
        return "fallback:\(digest)"
    }

    /// Assigns occurrence-stable identities. Unique bases keep their hash;
    /// duplicates get a deterministic ordinal so refreshes do not churn.
    static func assignIdentities(to bases: [String]) -> [String] {
        var totals: [String: Int] = [:]
        for base in bases { totals[base, default: 0] += 1 }
        var ordinals: [String: Int] = [:]
        return bases.map { base in
            if totals[base] == 1 {
                return TraceLimits.required(base, to: TraceLimits.identity)
            }
            let ordinal = ordinals[base, default: 0]
            ordinals[base] = ordinal + 1
            let composite = Data("\(base)#\(ordinal)".utf8)
            return TraceLimits.required("dup:\(payloadDigest(composite))", to: TraceLimits.identity)
        }
    }

    static func uuid(for value: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(value.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    static func payloadKey(for value: String) -> String {
        uuid(for: value).uuidString.lowercased()
    }
}
