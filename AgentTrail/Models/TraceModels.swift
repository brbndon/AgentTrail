import Foundation
import SwiftData

/// The hard limits applied before trace content enters SwiftData or search indexes.
enum TraceLimits {
    static let identity = 512
    static let sourceKey = 4_096
    static let title = 512
    static let summary = 32_000
    static let searchText = 32_000
    static let path = 4_096
    static let command = 32_000
    static let role = 128
    static let eventType = 256
    static let projectName = 512
    static let hash = 256
    static let maxInteger = 1_000_000_000

    static func bounded(_ value: String?, to limit: Int, trim: Bool = false) -> String? {
        guard var value else { return nil }
        if trim { value = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }

    static func required(_ value: String, to limit: Int, fallback: String = "") -> String {
        bounded(value, to: limit, trim: true) ?? fallback
    }

    static func search(_ value: String) -> String {
        required(value, to: searchText)
    }

    static func boundedNonNegative(_ value: Int) -> Int {
        min(max(value, 0), maxInteger)
    }

    static func boundedInteger(_ value: Int) -> Int {
        min(max(value, -maxInteger), maxInteger)
    }
}

/// A local project that owns one or more agent sessions.
@Model
final class ProjectRecord {
    @Attribute(.unique) var identity: String
    var path: String
    var name: String
    var lastOpened: Date

    @Relationship(deleteRule: .cascade, inverse: \SessionRecord.project)
    var sessions: [SessionRecord] = []

    init(identity: String, path: String, name: String, lastOpened: Date = .now) {
        self.identity = TraceLimits.required(identity, to: TraceLimits.identity)
        self.path = TraceLimits.required(path, to: TraceLimits.path)
        self.name = TraceLimits.required(name, to: TraceLimits.projectName, fallback: "Unknown project")
        self.lastOpened = lastOpened
    }
}

/// Metadata for one historical or currently growing agent trace.
@Model
final class SessionRecord {
    @Attribute(.unique) var sourceKey: String
    @Attribute(.unique) var id: UUID
    var agentTypeRawValue: String
    var title: String
    var startDate: Date
    var endDate: Date?
    var workingDirectory: String
    var sourcePath: String
    var sourceModifiedAt: Date
    var statusRawValue: String
    /// Default enables lightweight migration from V1 (attribute was added in V2).
    var sourceStateRawValue: String = SessionSourceState.scanned.rawValue
    var isPinned: Bool
    var parentSessionID: UUID?
    var forkStepID: UUID?
    var project: ProjectRecord?

    @Relationship(deleteRule: .cascade, inverse: \StepRecord.session)
    var steps: [StepRecord] = []

    init(
        sourceKey: String,
        id: UUID = UUID(),
        agentType: AgentType,
        title: String,
        startDate: Date,
        endDate: Date?,
        workingDirectory: String,
        sourcePath: String,
        sourceModifiedAt: Date,
        status: SessionStatus = .historical,
        sourceState: SessionSourceState = .scanned,
        isPinned: Bool = false,
        parentSessionID: UUID? = nil,
        forkStepID: UUID? = nil,
        project: ProjectRecord? = nil
    ) {
        self.sourceKey = TraceLimits.required(sourceKey, to: TraceLimits.sourceKey)
        self.id = id
        self.agentTypeRawValue = agentType.rawValue
        self.title = TraceLimits.required(title, to: TraceLimits.title, fallback: "Untitled session")
        self.startDate = startDate
        self.endDate = endDate
        self.workingDirectory = TraceLimits.required(workingDirectory, to: TraceLimits.path)
        self.sourcePath = TraceLimits.required(sourcePath, to: TraceLimits.path)
        self.sourceModifiedAt = sourceModifiedAt
        self.statusRawValue = status.rawValue
        self.sourceStateRawValue = sourceState.rawValue
        self.isPinned = isPinned
        self.parentSessionID = parentSessionID
        self.forkStepID = forkStepID
        self.project = project
    }

    var agentType: AgentType {
        AgentType(rawValue: agentTypeRawValue) ?? .codex
    }

    var status: SessionStatus {
        SessionStatus(rawValue: statusRawValue) ?? .historical
    }

    var sourceState: SessionSourceState {
        SessionSourceState(rawValue: sourceStateRawValue) ?? .scanned
    }

    var isBranch: Bool { sourceKey.hasPrefix("branch:") }
    var stepCount: Int { steps.count }
}

/// The current lifecycle state of a discovered session.
enum SessionStatus: String, Codable, Sendable {
    case historical
    case recording
    case failed
    case unavailable
}

/// The result of scanning the source that owns a session.
enum SessionSourceState: String, Codable, Sendable {
    case scanned
    case degraded
    case failed
    case unavailable
}

/// A normalized trace event. Large payloads are stored separately on disk.
@Model
final class StepRecord {
    @Attribute(.unique) var id: UUID
    /// This is an immutable reconciliation key, never a line number. It includes
    /// the source event identifier (when available) and a payload revision digest.
    var traceIdentity: String?
    var stepIndex: Int
    var kindRawValue: String
    var timestamp: Date
    var title: String
    var contentSummary: String
    var searchText: String
    var fullPayloadRef: String?
    var hasError: Bool
    var commandText: String?
    var filePath: String?
    var exitCode: Int?
    var tokenCount: Int?
    var parentStepID: UUID?
    var session: SessionRecord?

    @Relationship(deleteRule: .cascade, inverse: \FileChangeRecord.step)
    var fileChanges: [FileChangeRecord] = []

    init(
        id: UUID = UUID(),
        stepIndex: Int,
        kind: StepKind,
        timestamp: Date,
        title: String,
        contentSummary: String,
        searchText: String,
        fullPayloadRef: String?,
        hasError: Bool,
        commandText: String? = nil,
        filePath: String? = nil,
        exitCode: Int? = nil,
        tokenCount: Int? = nil,
        traceIdentity: String? = nil,
        session: SessionRecord? = nil
    ) {
        self.id = id
        self.traceIdentity = TraceLimits.bounded(traceIdentity, to: TraceLimits.identity)
        self.stepIndex = TraceLimits.boundedNonNegative(stepIndex)
        self.kindRawValue = kind.rawValue
        self.timestamp = timestamp
        self.title = TraceLimits.required(title, to: TraceLimits.title, fallback: kind.displayName)
        self.contentSummary = TraceLimits.required(contentSummary, to: TraceLimits.summary)
        self.searchText = TraceLimits.search(searchText)
        self.fullPayloadRef = TraceLimits.bounded(fullPayloadRef, to: TraceLimits.identity)
        self.hasError = hasError
        self.commandText = TraceLimits.bounded(commandText, to: TraceLimits.command)
        self.filePath = TraceLimits.bounded(filePath, to: TraceLimits.path)
        self.exitCode = exitCode.map(TraceLimits.boundedInteger)
        self.tokenCount = tokenCount.map(TraceLimits.boundedNonNegative)
        self.session = session
    }

    var kind: StepKind {
        StepKind(rawValue: kindRawValue) ?? .system
    }
}

/// A file-level change associated with a trace step.
@Model
final class FileChangeRecord {
    var path: String
    var changeTypeRawValue: String
    var beforeHash: String?
    var afterHash: String?
    var diffStorageKey: String?
    var step: StepRecord?

    init(
        path: String,
        changeType: String,
        beforeHash: String? = nil,
        afterHash: String? = nil,
        diffStorageKey: String? = nil,
        step: StepRecord? = nil
    ) {
        self.path = TraceLimits.required(path, to: TraceLimits.path)
        self.changeTypeRawValue = TraceLimits.required(changeType, to: TraceLimits.eventType, fallback: "modified")
        self.beforeHash = TraceLimits.bounded(beforeHash, to: TraceLimits.hash)
        self.afterHash = TraceLimits.bounded(afterHash, to: TraceLimits.hash)
        self.diffStorageKey = TraceLimits.bounded(diffStorageKey, to: TraceLimits.identity)
        self.step = step
    }
}

/// Current schema. Historical stores open through lightweight evolution of
/// optional fields; a pre-open backup is taken before migration is attempted.
///
/// Entity names (`*Record`) are stable across versions. Lightweight migration
/// only adds optional/defaulted attributes — it must never rename entities.
enum AgentTrailSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ProjectRecord.self, SessionRecord.self, StepRecord.self, FileChangeRecord.self]
    }
}

/// V1 captures the pre-lineage store shape used before branch/source-state fields.
/// Nested model types use the same persistent entity names as production
/// (`*Record`) so lightweight migration adds fields instead of dropping rows.
enum AgentTrailSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ProjectRecord.self, SessionRecord.self, StepRecord.self, FileChangeRecord.self]
    }

    @Model
    final class ProjectRecord {
        @Attribute(.unique) var identity: String
        var path: String
        var name: String
        var lastOpened: Date
        @Relationship(deleteRule: .cascade, inverse: \SessionRecord.project)
        var sessions: [SessionRecord] = []
        init(identity: String = "", path: String = "", name: String = "", lastOpened: Date = .now) {
            self.identity = identity
            self.path = path
            self.name = name
            self.lastOpened = lastOpened
        }
    }

    @Model
    final class SessionRecord {
        @Attribute(.unique) var sourceKey: String
        @Attribute(.unique) var id: UUID
        var agentTypeRawValue: String
        var title: String
        var startDate: Date
        var endDate: Date?
        var workingDirectory: String
        var sourcePath: String
        var sourceModifiedAt: Date
        var statusRawValue: String
        var isPinned: Bool
        var project: ProjectRecord?
        @Relationship(deleteRule: .cascade, inverse: \StepRecord.session)
        var steps: [StepRecord] = []
        init(
            sourceKey: String = "",
            id: UUID = UUID(),
            agentTypeRawValue: String = "",
            title: String = "",
            startDate: Date = .now,
            endDate: Date? = nil,
            workingDirectory: String = "",
            sourcePath: String = "",
            sourceModifiedAt: Date = .now,
            statusRawValue: String = "",
            isPinned: Bool = false
        ) {
            self.sourceKey = sourceKey
            self.id = id
            self.agentTypeRawValue = agentTypeRawValue
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.workingDirectory = workingDirectory
            self.sourcePath = sourcePath
            self.sourceModifiedAt = sourceModifiedAt
            self.statusRawValue = statusRawValue
            self.isPinned = isPinned
        }
    }

    @Model
    final class StepRecord {
        @Attribute(.unique) var id: UUID
        var stepIndex: Int
        var kindRawValue: String
        var timestamp: Date
        var title: String
        var contentSummary: String
        var searchText: String
        var fullPayloadRef: String?
        var hasError: Bool
        var commandText: String?
        var filePath: String?
        var exitCode: Int?
        var tokenCount: Int?
        var session: SessionRecord?
        @Relationship(deleteRule: .cascade, inverse: \FileChangeRecord.step)
        var fileChanges: [FileChangeRecord] = []
        init(
            id: UUID = UUID(),
            stepIndex: Int = 0,
            kindRawValue: String = "",
            timestamp: Date = .now,
            title: String = "",
            contentSummary: String = "",
            searchText: String = "",
            fullPayloadRef: String? = nil,
            hasError: Bool = false,
            commandText: String? = nil,
            filePath: String? = nil,
            exitCode: Int? = nil,
            tokenCount: Int? = nil
        ) {
            self.id = id
            self.stepIndex = stepIndex
            self.kindRawValue = kindRawValue
            self.timestamp = timestamp
            self.title = title
            self.contentSummary = contentSummary
            self.searchText = searchText
            self.fullPayloadRef = fullPayloadRef
            self.hasError = hasError
            self.commandText = commandText
            self.filePath = filePath
            self.exitCode = exitCode
            self.tokenCount = tokenCount
        }
    }

    @Model
    final class FileChangeRecord {
        var path: String
        var changeTypeRawValue: String
        var beforeHash: String?
        var afterHash: String?
        var diffStorageKey: String?
        var step: StepRecord?
        init(
            path: String = "",
            changeTypeRawValue: String = "",
            beforeHash: String? = nil,
            afterHash: String? = nil,
            diffStorageKey: String? = nil
        ) {
            self.path = path
            self.changeTypeRawValue = changeTypeRawValue
            self.beforeHash = beforeHash
            self.afterHash = afterHash
            self.diffStorageKey = diffStorageKey
        }
    }
}

enum AgentTrailMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AgentTrailSchemaV1.self, AgentTrailSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        // Additive only: entity names stay `*Record`; V2 adds optional lineage
        // and source-state fields with defaults.
        [.lightweight(fromVersion: AgentTrailSchemaV1.self, toVersion: AgentTrailSchemaV2.self)]
    }
}
