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
    /// Sources processed in the current parse loop (1-based when total > 0).
    var processed: Int
    /// Discovered sources for the current agent (0 while scanning).
    var total: Int
    var sessionsImported: Int
    var failures: Int
    /// Short leaf name of the source currently being parsed, when known.
    var currentName: String?

    var userFacingMessage: String {
        let agent = agentType?.displayName ?? "local agents"
        switch phase {
        case .scanning:
            return "Scanning \(agent) folders…"
        case .parsing:
            if total > 0 {
                var line = "Parsing \(agent): \(min(processed, total)) of \(total)"
                if sessionsImported > 0 { line += " · \(sessionsImported) ready" }
                if failures > 0 { line += " · \(failures) failed" }
                if let currentName, !currentName.isEmpty {
                    line += " · \(currentName)"
                }
                return line
            }
            return "Parsing \(agent)…"
        case .saving:
            return sessionsImported == 1
                ? "Saving 1 session to the local library…"
                : "Saving \(sessionsImported) sessions to the local library…"
        case .cleanup:
            return "Cleaning up unused payload files…"
        }
    }

    /// Determinate fraction while parsing a known agent batch; nil otherwise.
    var fractionCompleted: Double? {
        guard phase == .parsing, total > 0 else { return nil }
        return min(1, max(0, Double(processed) / Double(total)))
    }
}

/// Discovers and parses local agent traces without touching the network or the main actor.
actor IngestionService {
    private let directories: AgentDirectories
    private let payloadStore: PayloadStore
    private let logger = Logger(subsystem: "com.brandon.AgentTrail", category: "ingestion")

    init(directories: AgentDirectories = AgentDirectories(), payloadStore: PayloadStore = PayloadStore()) {
        self.directories = directories
        self.payloadStore = payloadStore
    }

    /// Returns parse results and source health. A failed individual source is
    /// retained in the report so AppStore can preserve its last good snapshot.
    /// `onProgress` is invoked regularly so the UI can show agent/count updates
    /// instead of a silent indefinite spinner on large trees.
    func discoverAndParse(
        onProgress: (@Sendable (IngestionProgress) async -> Void)? = nil
    ) async throws -> IngestionReport {
        var results: [ParsedSession] = []
        var reports: [IngestionSourceReport] = []
        let codexParser = CodexSessionParser()
        let grokParser = GrokBuildSessionParser()
        let cursorParser = CursorSessionParser()
        var sessionsImported = 0
        var totalFailures = 0

        // Codex
        if isReadableDirectory(directories.codexSessions) {
            await Self.emitProgress(onProgress, phase: .scanning, agent: .codex, sessionsImported: sessionsImported, failures: totalFailures)
            let discovered = codexParser.discover(in: directories.codexSessions)
            var failed: Set<String> = []
            var degraded: Set<String> = []
            let total = discovered.count
            await Self.emitProgress(onProgress, phase: .parsing, agent: .codex, processed: 0, total: total, sessionsImported: sessionsImported, failures: totalFailures)
            for (index, fileURL) in discovered.enumerated() {
                try Task.checkCancellation()
                let path = fileURL.standardizedFileURL.path
                await Self.emitProgress(
                    onProgress,
                    phase: .parsing,
                    agent: .codex,
                    processed: index + 1,
                    total: total,
                    sessionsImported: sessionsImported,
                    failures: totalFailures,
                    currentName: fileURL.lastPathComponent
                )
                do {
                    if let session = try await codexParser.parse(fileURL: fileURL, payloadStore: payloadStore) {
                        results.append(session)
                        sessionsImported += 1
                        if session.sourceState == .degraded {
                            degraded.insert(path)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed.insert(path)
                    totalFailures += 1
                    logger.debug("Skipping unavailable Codex session file")
                }
            }
            reports.append(IngestionSourceReport(
                agentType: .codex,
                rootPath: directories.codexSessions.standardizedFileURL.path,
                state: .scanned,
                discoveredSourcePaths: Set(discovered.map { $0.standardizedFileURL.path }),
                failedSourcePaths: failed,
                degradedSourcePaths: degraded
            ))
        } else {
            logger.debug("Codex sessions directory is not present")
            reports.append(IngestionSourceReport(agentType: .codex, rootPath: directories.codexSessions.path, state: .unavailable, discoveredSourcePaths: [], failedSourcePaths: [], degradedSourcePaths: []))
        }

        // Grok Build
        if isReadableDirectory(directories.grokSessions) {
            await Self.emitProgress(onProgress, phase: .scanning, agent: .grokBuild, sessionsImported: sessionsImported, failures: totalFailures)
            let discovered = grokParser.discover(in: directories.grokSessions)
            var failed: Set<String> = []
            var degraded: Set<String> = []
            let total = discovered.count
            await Self.emitProgress(onProgress, phase: .parsing, agent: .grokBuild, processed: 0, total: total, sessionsImported: sessionsImported, failures: totalFailures)
            for (index, directory) in discovered.enumerated() {
                try Task.checkCancellation()
                let path = directory.standardizedFileURL.path
                await Self.emitProgress(
                    onProgress,
                    phase: .parsing,
                    agent: .grokBuild,
                    processed: index + 1,
                    total: total,
                    sessionsImported: sessionsImported,
                    failures: totalFailures,
                    currentName: directory.lastPathComponent
                )
                do {
                    if let session = try await grokParser.parse(directory: directory, payloadStore: payloadStore) {
                        results.append(session)
                        sessionsImported += 1
                        if session.sourceState == .degraded {
                            degraded.insert(path)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed.insert(path)
                    totalFailures += 1
                    logger.debug("Skipping unavailable Grok Build session directory")
                }
            }
            reports.append(IngestionSourceReport(
                agentType: .grokBuild,
                rootPath: directories.grokSessions.standardizedFileURL.path,
                state: .scanned,
                discoveredSourcePaths: Set(discovered.map { $0.standardizedFileURL.path }),
                failedSourcePaths: failed,
                degradedSourcePaths: degraded
            ))
        } else {
            logger.debug("Grok sessions directory is not present")
            reports.append(IngestionSourceReport(agentType: .grokBuild, rootPath: directories.grokSessions.path, state: .unavailable, discoveredSourcePaths: [], failedSourcePaths: [], degradedSourcePaths: []))
        }

        // Cursor
        if isReadableDirectory(directories.cursorProjects) {
            await Self.emitProgress(onProgress, phase: .scanning, agent: .cursor, sessionsImported: sessionsImported, failures: totalFailures)
            let discovered = cursorParser.discover(in: directories.cursorProjects)
            var failed: Set<String> = []
            var degraded: Set<String> = []
            let total = discovered.count
            await Self.emitProgress(onProgress, phase: .parsing, agent: .cursor, processed: 0, total: total, sessionsImported: sessionsImported, failures: totalFailures)
            for (index, fileURL) in discovered.enumerated() {
                try Task.checkCancellation()
                let path = fileURL.standardizedFileURL.path
                await Self.emitProgress(
                    onProgress,
                    phase: .parsing,
                    agent: .cursor,
                    processed: index + 1,
                    total: total,
                    sessionsImported: sessionsImported,
                    failures: totalFailures,
                    currentName: fileURL.lastPathComponent
                )
                do {
                    if let session = try await cursorParser.parse(fileURL: fileURL, payloadStore: payloadStore) {
                        results.append(session)
                        sessionsImported += 1
                        if session.sourceState == .degraded {
                            degraded.insert(path)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed.insert(path)
                    totalFailures += 1
                    logger.debug("Skipping unavailable Cursor transcript file")
                }
            }
            reports.append(IngestionSourceReport(
                agentType: .cursor,
                rootPath: directories.cursorProjects.standardizedFileURL.path,
                state: .scanned,
                discoveredSourcePaths: Set(discovered.map { $0.standardizedFileURL.path }),
                failedSourcePaths: failed,
                degradedSourcePaths: degraded
            ))
        } else {
            logger.debug("Cursor projects directory is not present")
            reports.append(IngestionSourceReport(agentType: .cursor, rootPath: directories.cursorProjects.path, state: .unavailable, discoveredSourcePaths: [], failedSourcePaths: [], degradedSourcePaths: []))
        }

        return IngestionReport(
            sessions: results.sorted {
                if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
                return $0.sourceKey < $1.sourceKey
            },
            sources: reports.sorted { $0.agentType.rawValue < $1.agentType.rawValue }
        )
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func emitProgress(
        _ onProgress: (@Sendable (IngestionProgress) async -> Void)?,
        phase: IngestionProgress.Phase,
        agent: AgentType?,
        processed: Int = 0,
        total: Int = 0,
        sessionsImported: Int,
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
            failures: failures,
            currentName: currentName
        ))
    }
}
