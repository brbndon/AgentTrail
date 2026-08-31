import Foundation
import os

/// The default on-disk locations used by the supported local agents.
struct AgentDirectories: Sendable {
    let codexSessions: URL
    let grokSessions: URL
    let cursorProjects: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let homeDirectory = homeDirectory.standardizedFileURL
        codexSessions = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        grokSessions = homeDirectory.appendingPathComponent(".grok/sessions", isDirectory: true)
        cursorProjects = homeDirectory.appendingPathComponent(".cursor/projects", isDirectory: true)
    }

    var defaultWatchPaths: [URL] {
        [codexSessions, grokSessions, cursorProjects].sorted { $0.path < $1.path }
    }
}

struct IngestionSourceReport: Sendable {
    let agentType: AgentType
    let rootPath: String
    let state: SessionSourceState
    let discoveredSourcePaths: Set<String>
    let failedSourcePaths: Set<String>
    let degradedSourcePaths: Set<String>
}

struct IngestionReport: Sendable {
    let sessions: [ParsedSession]
    let sources: [IngestionSourceReport]
    /// Sources skipped because their on-disk mtime matched a known library snapshot.
    let skippedUnchangedCount: Int
    /// Total Codex JSONL files found before the newest-first page limit is applied.
    let totalDiscoveredSessionCount: Int
    let requestedSessionLimit: Int

    var hasMoreSessions: Bool {
        requestedSessionLimit < totalDiscoveredSessionCount
    }

    init(
        sessions: [ParsedSession],
        sources: [IngestionSourceReport],
        skippedUnchangedCount: Int,
        totalDiscoveredSessionCount: Int = 0,
        requestedSessionLimit: Int = 0
    ) {
        self.sessions = sessions
        self.sources = sources
        self.skippedUnchangedCount = skippedUnchangedCount
        self.totalDiscoveredSessionCount = totalDiscoveredSessionCount
        self.requestedSessionLimit = requestedSessionLimit
    }
}

/// Live discovery/parse progress for status UI. Large local trees can take minutes.
struct IngestionProgress: Sendable, Equatable {
    enum Phase: String, Sendable, Equatable {
        case scanning
        case parsing
        case saving
        case cleanup
    }

    var phase: Phase
    var agentType: AgentType?
    /// Overall sources handled so far (across all agents).
    var processed: Int
    /// Overall discovered sources after the scan phase (stable — does not reset per agent).
    var total: Int
    var sessionsImported: Int
    var sessionsSkipped: Int
    var failures: Int
    /// Short leaf name of the source currently being parsed, when known.
    var currentName: String?

    var userFacingMessage: String {
        let agent = agentType?.displayName
        switch phase {
        case .scanning:
            if let agent {
                return "Scanning \(agent) folders…"
            }
            return "Scanning local agent folders…"
        case .parsing:
            if total > 0 {
                var line = "Importing \(min(processed, total)) of \(total)"
                if let agent { line += " · \(agent)" }
                if sessionsImported > 0 { line += " · \(sessionsImported) new" }
                if sessionsSkipped > 0 { line += " · \(sessionsSkipped) unchanged" }
                if failures > 0 { line += " · \(failures) failed" }
                if let currentName, !currentName.isEmpty {
                    line += " · \(currentName)"
                }
                return line
            }
            return agent.map { "Parsing \($0)…" } ?? "Parsing local sessions…"
        case .saving:
            return sessionsImported == 1
                ? "Saving 1 session to the local library…"
                : "Saving \(max(sessionsImported, 0)) sessions to the local library…"
        case .cleanup:
            return "Cleaning up unused payload files…"
        }
    }

    /// Determinate fraction over the full import, never resets when switching agents.
    var fractionCompleted: Double? {
        switch phase {
        case .parsing, .saving:
            guard total > 0 else { return nil }
            return min(1, max(0, Double(processed) / Double(total)))
        case .scanning:
            return total > 0 ? min(0.05, Double(processed) / Double(max(total, 1))) : nil
        case .cleanup:
            return 1
        }
    }
}

/// Discovers and parses local agent traces without touching the network or the main actor.
actor IngestionService {
    private let directories: AgentDirectories
    private let payloadStore: PayloadStore
    private let codexCheckpointStore: CodexCheckpointStore
    private let logger = Logger(subsystem: "com.brandon.AgentTrail", category: "ingestion")

    init(
        directories: AgentDirectories = AgentDirectories(),
        payloadStore: PayloadStore = PayloadStore(),
        codexCheckpointStore: CodexCheckpointStore? = nil
    ) {
        self.directories = directories
        self.payloadStore = payloadStore
        self.codexCheckpointStore = codexCheckpointStore ?? CodexCheckpointStore(
            rootURL: payloadStore.rootURL.deletingLastPathComponent().appendingPathComponent("Checkpoints", isDirectory: true)
        )
    }

    /// Returns parse results and source health. A failed individual source is
    /// retained in the report so AppStore can preserve its last good snapshot.
    ///
    /// - Parameters:
    ///   - knownSourceModifiedAt: `sourceKey` → last imported mtime. Matching sources
    ///     are counted as processed but not re-parsed (fast refresh / resume).
    ///   - onProgress: UI progress; `processed`/`total` are global across agents.
    ///   - onBatch: Optional incremental sessions so the library can populate mid-import.
    func discoverAndParse(
        knownSourceModifiedAt: [String: Date] = [:],
        codexSessionLimit: Int = 30,
        includeExperimentalAgents: Bool = false,
        onProgress: (@Sendable (IngestionProgress) async -> Void)? = nil,
        onBatch: (@Sendable ([ParsedSession]) async throws -> Void)? = nil
    ) async throws -> IngestionReport {
        let codexParser = CodexSessionParser()
        let grokParser = GrokBuildSessionParser()
        let cursorParser = CursorSessionParser()
        let requestedLimit = max(codexSessionLimit, 0)

        enum WorkItem {
            case codex(URL)
            case grok(URL)
            case cursor(URL)

            var agent: AgentType {
                switch self {
                case .codex: .codex
                case .grok: .grokBuild
                case .cursor: .cursor
                }
            }

            var displayName: String {
                switch self {
                case .codex(let url), .cursor(let url): url.lastPathComponent
                case .grok(let url): url.lastPathComponent
                }
            }

            var sourcePath: String {
                switch self {
                case .codex(let url), .cursor(let url), .grok(let url):
                    url.standardizedFileURL.path
                }
            }

            var sourceKey: String {
                switch self {
                case .codex(let url): "codex:\(url.standardizedFileURL.path)"
                case .grok(let url): "grok:\(url.standardizedFileURL.path)"
                case .cursor(let url): "cursor:\(url.standardizedFileURL.path)"
                }
            }

            var modifiedAt: Date {
                switch self {
                case .codex(let url), .cursor(let url):
                    return url.contentModificationDate
                case .grok(let url):
                    return Self.directoryModifiedAt(url)
                }
            }

            private static func directoryModifiedAt(_ directory: URL) -> Date {
                let names = ["events.jsonl", "chat_history.jsonl", "prompt_history.jsonl", "rewind_points.jsonl"]
                let dates = names.compactMap { name -> Date? in
                    let file = directory.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                    return file.contentModificationDate
                }
                return dates.max() ?? directory.contentModificationDate
            }
        }

        var work: [WorkItem] = []
        var sourceStates: [(agent: AgentType, root: URL, readable: Bool, paths: [String])] = []

        // Phase 1: discover everything first so progress totals stay stable.
        await Self.emitProgress(
            onProgress,
            phase: .scanning,
            agent: .codex,
            processed: 0,
            total: 0,
            sessionsImported: 0,
            sessionsSkipped: 0,
            failures: 0
        )
        if isReadableDirectory(directories.codexSessions) {
            let discovered = codexParser.discover(in: directories.codexSessions)
            work.append(contentsOf: discovered.prefix(requestedLimit).map { .codex($0) })
            sourceStates.append((.codex, directories.codexSessions, true, discovered.map { $0.standardizedFileURL.path }))
        } else {
            sourceStates.append((.codex, directories.codexSessions, false, []))
        }

        // Keep the existing parsers available for targeted development, but the
        // user-facing app is Codex-first until their schemas and UX are ready.
        if includeExperimentalAgents {
            if isReadableDirectory(directories.grokSessions) {
                let discovered = grokParser.discover(in: directories.grokSessions)
                work.append(contentsOf: discovered.map { .grok($0) })
                sourceStates.append((.grokBuild, directories.grokSessions, true, discovered.map { $0.standardizedFileURL.path }))
            } else {
                sourceStates.append((.grokBuild, directories.grokSessions, false, []))
            }
            if isReadableDirectory(directories.cursorProjects) {
                let discovered = cursorParser.discover(in: directories.cursorProjects)
                work.append(contentsOf: discovered.map { .cursor($0) })
                sourceStates.append((.cursor, directories.cursorProjects, true, discovered.map { $0.standardizedFileURL.path }))
            } else {
                sourceStates.append((.cursor, directories.cursorProjects, false, []))
            }
        }

        work.sort {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.sourcePath > $1.sourcePath
        }

        let overallTotal = work.count
        var results: [ParsedSession] = []
        var pendingBatch: [ParsedSession] = []
        var sessionsImported = 0
        var sessionsSkipped = 0
        var totalFailures = 0
        var failedByAgent: [AgentType: Set<String>] = [:]
        var degradedByAgent: [AgentType: Set<String>] = [:]

        await Self.emitProgress(
            onProgress,
            phase: .parsing,
            agent: work.first?.agent,
            processed: 0,
            total: overallTotal,
            sessionsImported: 0,
            sessionsSkipped: 0,
            failures: 0
        )

        for (index, item) in work.enumerated() {
            try Task.checkCancellation()
            let path = item.sourcePath
            let key = item.sourceKey
            let modifiedAt = item.modifiedAt

            await Self.emitProgress(
                onProgress,
                phase: .parsing,
                agent: item.agent,
                processed: index + 1,
                total: overallTotal,
                sessionsImported: sessionsImported,
                sessionsSkipped: sessionsSkipped,
                failures: totalFailures,
                currentName: item.displayName
            )

            if Self.isUnchanged(sourceKey: key, modifiedAt: modifiedAt, known: knownSourceModifiedAt) {
                sessionsSkipped += 1
                continue
            }

            do {
                let session: ParsedSession?
                switch item {
                case .codex(let url):
                    session = try await codexParser.parseIncrementally(
                        fileURL: url,
                        payloadStore: payloadStore,
                        checkpointStore: codexCheckpointStore
                    ).session
                case .grok(let url):
                    session = try await grokParser.parse(directory: url, payloadStore: payloadStore)
                case .cursor(let url):
                    session = try await cursorParser.parse(fileURL: url, payloadStore: payloadStore)
                }
                if let session {
                    results.append(session)
                    pendingBatch.append(session)
                    sessionsImported += 1
                    if session.sourceState == .degraded {
                        degradedByAgent[item.agent, default: []].insert(path)
                    }
                    if pendingBatch.count >= 20 {
                        let batch = pendingBatch
                        pendingBatch = []
                        if let onBatch {
                            try await onBatch(batch)
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedByAgent[item.agent, default: []].insert(path)
                totalFailures += 1
                logger.debug("Skipping unavailable source for \(item.agent.rawValue, privacy: .public)")
            }
        }
        if !pendingBatch.isEmpty, let onBatch {
            try await onBatch(pendingBatch)
            pendingBatch = []
        }

        var reports: [IngestionSourceReport] = []
        for entry in sourceStates {
            if !entry.readable {
                reports.append(IngestionSourceReport(
                    agentType: entry.agent,
                    rootPath: entry.root.path,
                    state: .unavailable,
                    discoveredSourcePaths: [],
                    failedSourcePaths: [],
                    degradedSourcePaths: []
                ))
            } else {
                reports.append(IngestionSourceReport(
                    agentType: entry.agent,
                    rootPath: entry.root.standardizedFileURL.path,
                    state: .scanned,
                    discoveredSourcePaths: Set(entry.paths),
                    failedSourcePaths: failedByAgent[entry.agent] ?? [],
                    degradedSourcePaths: degradedByAgent[entry.agent] ?? []
                ))
            }
        }

        return IngestionReport(
            sessions: results.sorted {
                if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
                return $0.sourceKey < $1.sourceKey
            },
            sources: reports.sorted { $0.agentType.rawValue < $1.agentType.rawValue },
            skippedUnchangedCount: sessionsSkipped,
            totalDiscoveredSessionCount: sourceStates.first(where: { $0.agent == .codex })?.paths.count ?? 0,
            requestedSessionLimit: requestedLimit
        )
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    /// File mtimes and SwiftData dates can differ by sub-second rounding.
    private static func isUnchanged(sourceKey: String, modifiedAt: Date, known: [String: Date]) -> Bool {
        guard let knownDate = known[sourceKey] else { return false }
        return abs(knownDate.timeIntervalSince(modifiedAt)) < 1.5
    }

    private static func emitProgress(
        _ onProgress: (@Sendable (IngestionProgress) async -> Void)?,
        phase: IngestionProgress.Phase,
        agent: AgentType?,
        processed: Int = 0,
        total: Int = 0,
        sessionsImported: Int,
        sessionsSkipped: Int,
        failures: Int,
        currentName: String? = nil
    ) async {
        guard let onProgress else { return }
        await onProgress(IngestionProgress(
            phase: phase,
            agentType: agent,
            processed: processed,
            total: total,
            sessionsImported: sessionsImported,
            sessionsSkipped: sessionsSkipped,
            failures: failures,
            currentName: currentName
        ))
    }
}

private extension URL {
    var contentModificationDate: Date {
        (try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
    }
}
