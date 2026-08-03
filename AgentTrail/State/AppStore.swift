import Foundation
import Observation
import SwiftData
import os

/// Main-actor application state for discovery progress and selected session navigation.
@MainActor
@Observable
final class AppStore {
    var isLoading = false
    var lastRefreshDate: Date?
    var statusMessage: String
    /// Sticky message after degraded durable storage (emergency or backup recovery);
    /// not cleared by refresh, branch create, or status updates.
    private(set) var persistenceWarning: String?
    var selectedSessionID: UUID?
    var sidebarSearch = ""
    var agentFilter: AgentType?
    private(set) var isWatching = false

    let agentDirectories: AgentDirectories
    let payloadStore: PayloadStore

    private var hasBootstrapped = false
    private var modelContext: ModelContext?
    private var eventWatcher: FSEventWatcher?
    private var refreshTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var refreshRequestedWhileLoading = false
    private var refreshGeneration: UInt64 = 0
    private var watchToken: UUID?
    private let logger = Logger(subsystem: "com.brandon.AgentTrail", category: "app")

    init(
        modelContext: ModelContext? = nil,
        agentDirectories: AgentDirectories = AgentDirectories(),
        payloadStore: PayloadStore = PayloadStore(),
        startupMessage: String? = nil,
        persistenceWarning: String? = nil
    ) {
        self.modelContext = modelContext
        self.agentDirectories = agentDirectories
        self.payloadStore = payloadStore
        self.persistenceWarning = persistenceWarning
        self.statusMessage = startupMessage ?? persistenceWarning ?? "Ready to discover local agent sessions"
    }

    /// Loads the local trace directories once when the main window appears.
    func bootstrap(context: ModelContext) {
        modelContext = context
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        Task { await recomputeBranchPayloadProtection(in: context) }
        startWatching()
        refresh()
    }

    /// Re-scans all supported agent directories and upserts normalized metadata.
    /// A generation prevents a cancelled or stale task from publishing results.
    func refresh() {
        guard let context = modelContext else { return }
        guard !isLoading else {
            refreshRequestedWhileLoading = true
            return
        }
        isLoading = true
        if persistenceWarning == nil {
            statusMessage = "Discovering local sessions…"
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        let directories = agentDirectories
        let payloadStore = payloadStore
        refreshTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.refreshGeneration == generation {
                    self.isLoading = false
                    self.refreshTask = nil
                    if self.refreshRequestedWhileLoading {
                        self.refreshRequestedWhileLoading = false
                        self.scheduleRefresh()
                    }
                }
            }

            do {
                let service = IngestionService(directories: directories, payloadStore: payloadStore)
                let report = try await service.discoverAndParse()
                try Task.checkCancellation()
                guard let self, self.refreshGeneration == generation else { return }
                try self.upsert(report, into: context)
                await self.recomputeBranchPayloadProtection(in: context)
                let references = try self.payloadReferences(in: context)
                await payloadStore.setLiveReferences(references)
                do {
                    try await payloadStore.removeUnreferenced(keeping: references)
                } catch {
                    if self.persistenceWarning == nil {
                        self.statusMessage = "Imported sessions, but payload cleanup needs attention"
                    }
                    self.logger.error("Payload cleanup failed")
                }
                guard self.refreshGeneration == generation else { return }
                self.lastRefreshDate = .now
                if self.persistenceWarning == nil {
                    let failed = report.sources.reduce(0) { $0 + $1.failedSourcePaths.count }
                    let degraded = report.sources.reduce(0) { $0 + $1.degradedSourcePaths.count }
                    let unavailable = report.sources.filter { $0.state == .unavailable }.count
                    if failed > 0 || unavailable > 0 || degraded > 0 {
                        let issues = failed + unavailable + degraded
                        let suffix = issues == 1 ? "" : "s"
                        self.statusMessage = "Imported \(report.sessions.count) sessions; \(issues) source\(suffix) needs attention"
                    } else {
                        let suffix = report.sessions.count == 1 ? "" : "s"
                        self.statusMessage = report.sessions.isEmpty
                            ? "No sessions found in the configured agent directories"
                            : "Imported \(report.sessions.count) local session\(suffix)"
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.refreshGeneration == generation else { return }
                if self.persistenceWarning == nil {
                    self.statusMessage = "Unable to save discovered sessions."
                }
                self.logger.error("Unable to save discovered sessions")
            }
        }
    }

    /// Creates an immutable local child trace containing the selected session prefix.
    func createBranch(from step: StepRecord, named name: String) async throws -> SessionRecord {
        guard let parentSession = step.session, let context = modelContext else {
            throw BranchingError.missingParentSession
        }

        let branchName = TraceLimits.required(name, to: TraceLimits.title, fallback: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else { throw BranchingError.emptyName }
        guard parentSession.steps.contains(where: { $0.id == step.id }) else {
            throw BranchingError.missingParentSession
        }

        let prefix = parentSession.steps
            .sorted {
                if $0.stepIndex != $1.stepIndex { return $0.stepIndex < $1.stepIndex }
                return $0.id.uuidString < $1.id.uuidString
            }
            .filter { $0.stepIndex <= step.stepIndex }

        let branch = SessionRecord(
            sourceKey: "branch:\(UUID().uuidString.lowercased())",
            agentType: parentSession.agentType,
            title: branchName,
            startDate: parentSession.startDate,
            endDate: step.timestamp,
            workingDirectory: parentSession.workingDirectory,
            sourcePath: parentSession.sourcePath,
            sourceModifiedAt: .now,
            status: .historical,
            sourceState: .scanned,
            project: parentSession.project
        )
        branch.parentSessionID = parentSession.id
        branch.forkStepID = step.id
        context.insert(branch)

        branch.steps = prefix.map { sourceStep in
            let branchStep = StepRecord(
                stepIndex: sourceStep.stepIndex,
                kind: sourceStep.kind,
                timestamp: sourceStep.timestamp,
                title: sourceStep.title,
                contentSummary: sourceStep.contentSummary,
                searchText: sourceStep.searchText,
                fullPayloadRef: sourceStep.fullPayloadRef,
                hasError: sourceStep.hasError,
                commandText: sourceStep.commandText,
                filePath: sourceStep.filePath,
                exitCode: sourceStep.exitCode,
                tokenCount: sourceStep.tokenCount,
                traceIdentity: sourceStep.traceIdentity,
                session: branch
            )
            branchStep.parentStepID = sourceStep.id
            context.insert(branchStep)
            branchStep.fileChanges = sourceStep.fileChanges.map { sourceChange in
                let copy = FileChangeRecord(
                    path: sourceChange.path,
                    changeType: sourceChange.changeTypeRawValue,
                    beforeHash: sourceChange.beforeHash,
                    afterHash: sourceChange.afterHash,
                    diffStorageKey: sourceChange.diffStorageKey,
                    step: branchStep
                )
                context.insert(copy)
                return copy
            }
            return branchStep
        }

        // Protect payloads only after a successful durable save.
        try context.save()
        await recomputeBranchPayloadProtection(in: context)
        selectedSessionID = branch.id
        if persistenceWarning == nil {
            statusMessage = "Created branch \"\(branchName)\""
        }
        return branch
    }

    /// Stops filesystem observation and invalidates all pending refresh work.
    func stopWatching() {
        refreshGeneration &+= 1
        watchToken = nil
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestedWhileLoading = false
        eventWatcher?.stop()
        eventWatcher = nil
        isWatching = false
        isLoading = false
    }

    private func startWatching() {
        guard eventWatcher == nil else { return }
        let token = UUID()
        watchToken = token
        let watcher = FSEventWatcher(paths: agentDirectories.defaultWatchPaths) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.watchToken == token, self.eventWatcher != nil else { return }
                self.scheduleRefresh()
            }
        }
        eventWatcher = watcher
        isWatching = watcher.start()
    }

    private func scheduleRefresh() {
        guard let token = watchToken else { return }
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task<Void, Never> { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.watchToken == token else { return }
            self.scheduledRefreshTask = nil
            self.refresh()
        }
    }

    private func upsert(_ report: IngestionReport, into context: ModelContext) throws {
        for snapshot in report.sessions where !snapshot.sourceKey.hasPrefix("branch:") {
            let projectIdentity = snapshot.projectIdentity
            let projectDescriptor = FetchDescriptor<ProjectRecord>(predicate: #Predicate { $0.identity == projectIdentity })
            let project: ProjectRecord
            if let existingProject = try context.fetch(projectDescriptor).first {
                project = existingProject
            } else {
                project = ProjectRecord(identity: snapshot.projectIdentity, path: snapshot.projectPath, name: snapshot.projectName)
                context.insert(project)
            }
            project.path = TraceLimits.required(snapshot.projectPath, to: TraceLimits.path)
            project.name = TraceLimits.required(snapshot.projectName, to: TraceLimits.projectName, fallback: "Unknown project")
            project.lastOpened = .now

            let sourceKey = snapshot.sourceKey
            let sessionDescriptor = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.sourceKey == sourceKey })
            let session: SessionRecord
            if let existingSession = try context.fetch(sessionDescriptor).first, !existingSession.isBranch {
                session = existingSession
            } else {
                session = SessionRecord(
                    sourceKey: snapshot.sourceKey,
                    agentType: snapshot.agentType,
                    title: snapshot.title,
                    startDate: snapshot.startDate,
                    endDate: snapshot.endDate,
                    workingDirectory: snapshot.workingDirectory,
                    sourcePath: snapshot.sourcePath,
                    sourceModifiedAt: snapshot.sourceModifiedAt,
                    status: snapshot.status,
                    sourceState: snapshot.sourceState,
                    project: project
                )
                context.insert(session)
            }
            session.agentTypeRawValue = snapshot.agentType.rawValue
            session.title = TraceLimits.required(snapshot.title, to: TraceLimits.title, fallback: "Untitled session")
            session.startDate = snapshot.startDate
            session.endDate = snapshot.endDate
            session.workingDirectory = TraceLimits.required(snapshot.workingDirectory, to: TraceLimits.path)
            session.sourcePath = TraceLimits.required(snapshot.sourcePath, to: TraceLimits.path)
            session.sourceModifiedAt = snapshot.sourceModifiedAt
            session.statusRawValue = snapshot.status.rawValue
            session.sourceStateRawValue = snapshot.sourceState.rawValue
            session.project = project

            let existingCounts = session.steps.compactMap(\.traceIdentity).reduce(into: [:]) { counts, identity in counts[identity, default: 0] += 1 }
            let existingStepsByIdentity = session.steps.compactMap { step -> (String, StepRecord)? in
                guard let identity = step.traceIdentity,
                      !identity.hasPrefix("line:"),
                      existingCounts[identity] == 1
                else { return nil }
                return (identity, step)
            }.reduce(into: [String: StepRecord]()) { $0[$1.0] = $1.1 }
            let incomingIdentities = Set(snapshot.steps.map(\.identity))
            for existingStep in session.steps where existingStep.traceIdentity == nil || !incomingIdentities.contains(existingStep.traceIdentity ?? "") {
                context.delete(existingStep)
            }

            session.steps = snapshot.steps.map { parsed in
                let step: StepRecord
                if let existingStep = existingStepsByIdentity[parsed.identity] {
                    step = existingStep
                } else {
                    step = StepRecord(
                        id: StableTraceIdentity.uuid(for: "\(snapshot.sourceKey)#\(parsed.identity)"),
                        stepIndex: parsed.index,
                        kind: parsed.kind,
                        timestamp: parsed.timestamp,
                        title: parsed.title,
                        contentSummary: parsed.summary,
                        searchText: parsed.searchText,
                        fullPayloadRef: parsed.payloadReference,
                        hasError: parsed.hasError,
                        commandText: parsed.commandText,
                        filePath: parsed.filePath,
                        exitCode: parsed.exitCode,
                        tokenCount: parsed.tokenCount,
                        traceIdentity: parsed.identity,
                        session: session
                    )
                    context.insert(step)
                }
                step.traceIdentity = parsed.identity
                step.stepIndex = parsed.index
                step.kindRawValue = parsed.kind.rawValue
                step.timestamp = parsed.timestamp
                step.title = TraceLimits.required(parsed.title, to: TraceLimits.title, fallback: parsed.kind.displayName)
                step.contentSummary = TraceLimits.required(parsed.summary, to: TraceLimits.summary)
                step.searchText = TraceLimits.search(parsed.searchText)
                step.fullPayloadRef = parsed.payloadReference
                step.hasError = parsed.hasError
                step.commandText = TraceLimits.bounded(parsed.commandText, to: TraceLimits.command)
                step.filePath = TraceLimits.bounded(parsed.filePath, to: TraceLimits.path)
                step.exitCode = parsed.exitCode
                step.tokenCount = parsed.tokenCount
                step.parentStepID = nil
                step.session = session
                for change in step.fileChanges { context.delete(change) }
                step.fileChanges = parsed.fileChanges.map { parsedChange in
                    let change = FileChangeRecord(
                        path: parsedChange.path,
                        changeType: parsedChange.changeType,
                        beforeHash: parsedChange.beforeHash,
                        afterHash: parsedChange.afterHash,
                        diffStorageKey: parsedChange.hasDiff ? parsed.payloadReference : nil,
                        step: step
                    )
                    context.insert(change)
                    return change
                }
                return step
            }
        }

        let allSessions = try context.fetch(FetchDescriptor<SessionRecord>())
        for source in report.sources {
            for session in allSessions where !session.isBranch && session.agentType == source.agentType && isWithin(session.sourcePath, rootPath: source.rootPath) {
                let path = URL(fileURLWithPath: session.sourcePath).standardizedFileURL.path
                if source.state == .unavailable {
                    session.sourceStateRawValue = SessionSourceState.unavailable.rawValue
                    session.statusRawValue = SessionStatus.unavailable.rawValue
                } else if source.failedSourcePaths.contains(path) {
                    // Preserve last good snapshot metadata; mark source failed.
                    session.sourceStateRawValue = SessionSourceState.failed.rawValue
                    session.statusRawValue = SessionStatus.failed.rawValue
                } else if source.degradedSourcePaths.contains(path) {
                    session.sourceStateRawValue = SessionSourceState.degraded.rawValue
                } else if source.discoveredSourcePaths.contains(path) {
                    // Keep session-level degraded from the parse if present.
                    if session.sourceState != .degraded {
                        session.sourceStateRawValue = SessionSourceState.scanned.rawValue
                    }
                } else {
                    session.sourceStateRawValue = SessionSourceState.unavailable.rawValue
                    session.statusRawValue = SessionStatus.unavailable.rawValue
                }
            }
        }
        try context.save()
    }

    private func recomputeBranchPayloadProtection(in context: ModelContext) async {
        do {
            let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
            var references = Set<String>()
            for session in sessions where session.isBranch {
                for step in session.steps {
                    if let ref = step.fullPayloadRef { references.insert(ref) }
                    for change in step.fileChanges {
                        if let ref = change.diffStorageKey { references.insert(ref) }
                    }
                }
            }
            await payloadStore.replaceProtectedBranchReferences(references)
        } catch {
            logger.error("Unable to recompute branch payload protection")
            // Fail-soft: leave prior protection set; surface a non-sticky note when
            // not already on emergency/backup recovery messaging.
            if persistenceWarning == nil {
                statusMessage = "Imported sessions, but branch payload protection needs attention"
            }
        }
    }

    private func payloadReferences(in context: ModelContext) throws -> Set<String> {
        let stepReferences = try context.fetch(FetchDescriptor<StepRecord>()).compactMap(\.fullPayloadRef)
        let diffReferences = try context.fetch(FetchDescriptor<FileChangeRecord>()).compactMap(\.diffStorageKey)
        return Set(stepReferences + diffReferences)
    }

    private func isWithin(_ path: String, rootPath: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// User-facing failures that can occur while creating a trace branch.
enum BranchingError: LocalizedError {
    case emptyName
    case missingParentSession

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for this branch."
        case .missingParentSession: "The selected step is no longer attached to a session."
        }
    }
}
