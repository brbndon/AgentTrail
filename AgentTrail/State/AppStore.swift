import AppKit
import Foundation
import Observation
import SwiftData
import os

/// Main-actor application state for discovery progress and selected session navigation.
@MainActor
@Observable
final class AppStore {
    static let sessionPageSize = 30
    private static let codexNormalizationVersion = 5
    private static let codexNormalizationVersionKey = "CodexNormalizationVersion"

    var isLoading = false
    var lastRefreshDate: Date?
    var statusMessage: String
    /// Latest discovery/parse progress while `isLoading` (nil when idle).
    private(set) var ingestionProgress: IngestionProgress?
    /// Sticky message after degraded durable storage (emergency or backup recovery);
    /// not cleared by refresh, branch create, or status updates.
    private(set) var persistenceWarning: String?
    var selectedSessionID: UUID?
    var sidebarSearch = ""
    var agentFilter: AgentType?
    private(set) var isWatching = false
    private(set) var loadedSessionLimit = AppStore.sessionPageSize
    private(set) var totalAvailableSessionCount = 0
    /// Live Codex count for the currently loaded page, derived from source mtimes.
    private(set) var liveSessionCount = 0
    /// Render-ready menu rows for the currently loaded page. This is transient
    /// UI state; it deliberately keeps SwiftData queries out of MenuBarExtra.
    private(set) var liveSessionMenuItems: [LiveSessionMenuItem] = []
    private(set) var liveSessionOverflowCount = 0
    /// Total persisted threads per project, populated with database counts so
    /// sidebar headers never materialize the full session history.
    private(set) var projectSessionCounts: [String: Int] = [:]

    var hasMoreSessions: Bool {
        loadedSessionLimit < totalAvailableSessionCount
    }

    var nextSessionPageCount: Int {
        min(Self.sessionPageSize, max(totalAvailableSessionCount - loadedSessionLimit, 0))
    }

    let agentDirectories: AgentDirectories
    let payloadStore: PayloadStore
    /// Sort, grouping, and layout choices shared by every browsing surface.
    let browsePreferences: BrowsePreferences

    private var hasBootstrapped = false
    private var modelContext: ModelContext?
    private var eventWatcher: FSEventWatcher?
    private var refreshTask: Task<Void, Never>?
    /// Keeps the menu-bar count fresh even when the main window is closed.
    /// This is a render tick, not a second filesystem watcher.
    private var liveCountTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    /// User-requested or filesystem-requested rescan while a run is in flight.
    /// Only honored once after the current run finishes (never cancels mid-import).
    private var refreshRequestedWhileLoading = false
    private var refreshGeneration: UInt64 = 0
    private var watchToken: UUID?
    private var lastProgressPublish: ContinuousClock.Instant?
    private var knownSessionLimitOverride: Int?
    private var requiresVisiblePageReindex = !AgentTrailRuntime.isTestHost
        && UserDefaults.standard.integer(forKey: AppStore.codexNormalizationVersionKey) < AppStore.codexNormalizationVersion
    /// Ignore FSEvents until first successful import finishes; they restart multi-minute scans.
    private var filesystemWatchEnabled = false
    private let logger = Logger(subsystem: "com.brandon.AgentTrail", category: "app")

    init(
        modelContext: ModelContext? = nil,
        agentDirectories: AgentDirectories = AgentDirectories(),
        payloadStore: PayloadStore = PayloadStore(),
        startupMessage: String? = nil,
        persistenceWarning: String? = nil,
        browsePreferences: BrowsePreferences? = nil
    ) {
        self.browsePreferences = browsePreferences ?? BrowsePreferences()
        self.modelContext = modelContext
        self.agentDirectories = agentDirectories
        self.payloadStore = payloadStore
        self.persistenceWarning = persistenceWarning
        self.statusMessage = startupMessage ?? persistenceWarning ?? "Ready to discover local agent sessions"
    }

    /// Loads the local trace directories once when the main window appears.
    /// Filesystem watching starts only after the first import completes so live
    /// agent logs cannot restart a multi-minute first scan.
    func bootstrap(context: ModelContext) {
        modelContext = context
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        startLiveCountUpdates()
        refreshLiveSessionCount()
        do {
            try refreshProjectSessionCounts(in: context)
        } catch {
            logger.error("Unable to count project sessions: \(error.localizedDescription, privacy: .public)")
        }
        Task { await recomputeBranchPayloadProtection(in: context) }
        refresh()
    }

    /// Re-scans all supported agent directories and upserts normalized metadata.
    /// A generation prevents a cancelled or stale task from publishing results.
    /// Mid-import work is never cancelled by FSEvents; at most one follow-up runs after.
    func refresh() {
        guard let context = modelContext else {
            statusMessage = "Local library is not ready yet. Try Refresh again."
            return
        }
        guard !isLoading else {
            refreshRequestedWhileLoading = true
            if persistenceWarning == nil, !statusMessage.contains("rescan queued") {
                statusMessage += " · rescan queued after this import"
            }
            return
        }
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        isLoading = true
        ingestionProgress = IngestionProgress(
            phase: .scanning,
            agentType: nil,
            processed: 0,
            total: 0,
            sessionsImported: 0,
            sessionsSkipped: 0,
            failures: 0,
            currentName: nil
        )
        lastProgressPublish = nil
        if persistenceWarning == nil {
            statusMessage = "Starting local session discovery…"
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        let directories = agentDirectories
        let payloadStore = payloadStore
        let sessionLimit = loadedSessionLimit
        let knownSessionLimit = knownSessionLimitOverride ?? (requiresVisiblePageReindex ? 0 : sessionLimit)
        knownSessionLimitOverride = nil
        refreshTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.refreshGeneration == generation {
                    self.isLoading = false
                    self.ingestionProgress = nil
                    self.refreshTask = nil
                    self.startWatchingIfNeeded()
                    if self.refreshRequestedWhileLoading {
                        self.refreshRequestedWhileLoading = false
                        // Follow-up uses skip-unchanged and only runs once.
                        self.scheduleRefresh(delayMilliseconds: 1_500)
                    }
                }
            }

            do {
                guard let self else { return }
                let known = knownSessionLimit > 0
                    ? try self.knownSourceModificationDates(in: context, limit: knownSessionLimit)
                    : [:]
                let service = IngestionService(directories: directories, payloadStore: payloadStore)
                // Stream batches back to the main actor so ModelContext is never captured in a Sendable closure.
                let (batchStream, batchContinuation) = AsyncStream.makeStream(of: [ParsedSession].self)
                async let reportTask: IngestionReport = {
                    defer { batchContinuation.finish() }
                    return try await service.discoverAndParse(
                        knownSourceModifiedAt: known,
                        codexSessionLimit: sessionLimit,
                        onProgress: { [weak self] progress in
                            guard let self else { return }
                            await self.publishIngestionProgress(progress, generation: generation)
                        },
                        onBatch: { batch in
                            batchContinuation.yield(batch)
                        }
                    )
                }()
                for await batch in batchStream {
                    guard self.refreshGeneration == generation else { break }
                    try self.upsertSessions(batch, into: context)
                }
                let report = try await reportTask
                try Task.checkCancellation()
                guard self.refreshGeneration == generation else { return }
                self.totalAvailableSessionCount = report.totalDiscoveredSessionCount

                let totalWork = report.sessions.count + report.skippedUnchangedCount
                let saving = IngestionProgress(
                    phase: .saving,
                    agentType: nil,
                    processed: totalWork,
                    total: max(totalWork, 1),
                    sessionsImported: report.sessions.count,
                    sessionsSkipped: report.skippedUnchangedCount,
                    failures: report.sources.reduce(0) { $0 + $1.failedSourcePaths.count },
                    currentName: nil
                )
                self.publishIngestionProgress(saving, generation: generation, force: true)
                // Every snapshot was saved from the stream. Only reconcile source
                // health here; rewriting the full page doubles main-actor work.
                try self.upsert(report, into: context, applySourceHealth: true, applySessions: false)
                try self.refreshProjectSessionCounts(in: context)
                self.refreshLiveSessionCount()
                guard self.refreshGeneration == generation else { return }
                self.lastRefreshDate = .now
                if self.requiresVisiblePageReindex {
                    self.requiresVisiblePageReindex = false
                    UserDefaults.standard.set(
                        Self.codexNormalizationVersion,
                        forKey: Self.codexNormalizationVersionKey
                    )
                }
                if self.persistenceWarning == nil {
                    self.statusMessage = self.completionStatusMessage(for: report)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.refreshGeneration == generation else { return }
                if self.persistenceWarning == nil {
                    let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = detail.isEmpty
                        ? "Unable to import local sessions."
                        : "Unable to import local sessions: \(detail)"
                }
                self.logger.error("Unable to import local sessions: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func loadMoreSessions() {
        guard !isLoading, hasMoreSessions else { return }
        knownSessionLimitOverride = loadedSessionLimit
        loadedSessionLimit = min(loadedSessionLimit + Self.sessionPageSize, totalAvailableSessionCount)
        refresh()
    }

    func updateLiveSessionCount(from sessions: [SessionRecord], now: Date) {
        let slice = SessionLiveness.slice(from: sessions, now: now)
        liveSessionMenuItems = slice.sessions.map { session in
            LiveSessionMenuItem(
                id: session.id,
                title: session.title,
                projectName: session.project?.name ?? "Unknown project",
                eventCount: session.stepCount
            )
        }
        liveSessionOverflowCount = slice.overflowCount
        let count = slice.sessions.count + slice.overflowCount
        if liveSessionCount != count {
            liveSessionCount = count
        }
    }

    private func startLiveCountUpdates() {
        guard liveCountTask == nil, !AgentTrailRuntime.isTestHost else { return }
        liveCountTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.refreshLiveSessionCount()
                do {
                    try await Task.sleep(for: .milliseconds(Int(SessionLiveness.tickInterval * 1_000)))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshLiveSessionCount(now: Date = .now) {
        guard let context = modelContext else { return }
        var descriptor = FetchDescriptor<SessionRecord>(
            sortBy: [SortDescriptor(\SessionRecord.sourceModifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(loadedSessionLimit, 1)
        do {
            updateLiveSessionCount(from: try context.fetch(descriptor), now: now)
        } catch {
            logger.error("Unable to refresh live session count: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openSessionFromMenuBar(_ id: UUID) {
        selectedSessionID = id
        bringMainWindowForward()
    }

    func bringMainWindowForward() {
        guard !AgentTrailRuntime.isTestHost else { return }
        NSApp.activate()
        let window = NSApp.windows.first(where: \.isMiniaturized)
            ?? NSApp.windows.first(where: { $0.canBecomeMain })
            ?? NSApp.windows.first
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Publishes discovery progress to the status bar, throttled so large trees
    /// do not flood the main actor while still updating at least ~10×/sec.
    private func publishIngestionProgress(
        _ progress: IngestionProgress,
        generation: UInt64,
        force: Bool = false
    ) {
        guard refreshGeneration == generation else { return }
        let now = ContinuousClock.now
        if !force, let last = lastProgressPublish, now - last < .milliseconds(100) {
            return
        }
        lastProgressPublish = now
        ingestionProgress = progress
        if persistenceWarning == nil {
            statusMessage = progress.userFacingMessage
        }
    }

    private func completionStatusMessage(for report: IngestionReport) -> String {
        let failed = report.sources.reduce(0) { $0 + $1.failedSourcePaths.count }
        let degraded = report.sources.reduce(0) { $0 + $1.degradedSourcePaths.count }
        let unavailable = report.sources.filter { $0.state == .unavailable }.count
        let scannedRoots = report.sources.filter { $0.state == .scanned }.count
        let discovered = report.sources.reduce(0) { $0 + $1.discoveredSourcePaths.count }
        let skipped = report.skippedUnchangedCount

        if report.sessions.isEmpty && skipped == 0 {
            if unavailable == report.sources.count {
                return "The Codex session folder at ~/.codex/sessions is unavailable"
            }
            if discovered == 0 {
                return "Scanned \(scannedRoots) agent location\(scannedRoots == 1 ? "" : "s"); no session files found"
            }
            if failed > 0 {
                return "Found \(discovered) source\(discovered == 1 ? "" : "s") but none imported (\(failed) failed)"
            }
            return "No sessions could be imported from \(discovered) discovered source\(discovered == 1 ? "" : "s")"
        }

        var parts: [String] = []
        if report.sessions.count > 0 {
            let suffix = report.sessions.count == 1 ? "" : "s"
            parts.append("Imported \(report.sessions.count) session\(suffix)")
        }
        if skipped > 0 {
            parts.append("\(skipped) unchanged")
        }
        if failed > 0 || unavailable > 0 || degraded > 0 {
            let issues = failed + unavailable + degraded
            let suffix = issues == 1 ? "" : "s"
            parts.append("\(issues) source\(suffix) needs attention")
        }
        return parts.joined(separator: "; ")
    }

    private func knownSourceModificationDates(in context: ModelContext, limit: Int) throws -> [String: Date] {
        let codex = AgentType.codex.rawValue
        var descriptor = FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.agentTypeRawValue == codex && $0.parentSessionID == nil },
            sortBy: [SortDescriptor(\SessionRecord.sourceModifiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit, 1)
        let sessions = try context.fetch(descriptor)
        var known: [String: Date] = [:]
        for session in sessions where !session.isBranch
            && session.sourceState != .failed && session.sourceState != .unavailable {
            known[session.sourceKey] = session.sourceModifiedAt
        }
        return known
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
        try refreshProjectSessionCounts(in: context)
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
        liveCountTask?.cancel()
        liveCountTask = nil
        refreshRequestedWhileLoading = false
        liveSessionMenuItems = []
        liveSessionOverflowCount = 0
        liveSessionCount = 0
        filesystemWatchEnabled = false
        eventWatcher?.stop()
        eventWatcher = nil
        isWatching = false
        isLoading = false
        ingestionProgress = nil
    }

    private func startWatchingIfNeeded() {
        filesystemWatchEnabled = true
        guard eventWatcher == nil else { return }
        let token = UUID()
        watchToken = token
        let watcher = FSEventWatcher(paths: [agentDirectories.codexSessions]) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.watchToken == token, self.eventWatcher != nil else { return }
                // Never cancel an in-flight import. Queue at most one follow-up.
                guard self.filesystemWatchEnabled else { return }
                if self.isLoading {
                    self.refreshRequestedWhileLoading = true
                    return
                }
                self.scheduleRefresh(delayMilliseconds: 2_500)
            }
        }
        eventWatcher = watcher
        isWatching = watcher.start()
    }

    func scheduleRefresh(delayMilliseconds: UInt64 = 2_500) {
        // Keep the first deadline so continuous writes cannot postpone refresh
        // indefinitely. Events during import already queue one follow-up.
        guard scheduledRefreshTask == nil else { return }
        let token = watchToken
        scheduledRefreshTask = Task<Void, Never> { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if let token, self.watchToken != token { return }
            self.scheduledRefreshTask = nil
            self.refresh()
        }
    }

    /// Incremental save during long imports so the sidebar fills before the full tree finishes.
    private func upsertSessions(_ sessions: [ParsedSession], into context: ModelContext) throws {
        guard !sessions.isEmpty else { return }
        try upsert(IngestionReport(sessions: sessions, sources: [], skippedUnchangedCount: 0), into: context, applySourceHealth: false)
    }

    private func upsert(
        _ report: IngestionReport,
        into context: ModelContext,
        applySourceHealth: Bool,
        applySessions: Bool = true
    ) throws {
        for snapshot in (applySessions ? report.sessions : []) where !snapshot.sourceKey.hasPrefix("branch:") {
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

        if applySourceHealth, !report.sources.isEmpty {
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

    private func refreshProjectSessionCounts(in context: ModelContext) throws {
        let projects = try context.fetch(FetchDescriptor<ProjectRecord>())
        var counts: [String: Int] = [:]
        counts.reserveCapacity(projects.count)
        for project in projects {
            let projectIdentity = project.identity
            let descriptor = FetchDescriptor<SessionRecord>(
                predicate: #Predicate { $0.project?.identity == projectIdentity }
            )
            counts[projectIdentity] = try context.fetchCount(descriptor)
        }
        projectSessionCounts = counts
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
