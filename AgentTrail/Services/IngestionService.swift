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
    func discoverAndParse() async throws -> IngestionReport {
        var results: [ParsedSession] = []
        var reports: [IngestionSourceReport] = []
        let codexParser = CodexSessionParser()
        let grokParser = GrokBuildSessionParser()
        let cursorParser = CursorSessionParser()

        if isReadableDirectory(directories.codexSessions) {
            let discovered = codexParser.discover(in: directories.codexSessions)
            var failed: Set<String> = []
            var degraded: Set<String> = []
            for fileURL in discovered {
                try Task.checkCancellation()
                let path = fileURL.standardizedFileURL.path
                do {
                    if let session = try await codexParser.parse(fileURL: fileURL, payloadStore: payloadStore) {
                        results.append(session)
                        if session.sourceState == .degraded {
                            degraded.insert(path)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed.insert(path)
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

        if isReadableDirectory(directories.grokSessions) {
            let discovered = grokParser.discover(in: directories.grokSessions)
            var failed: Set<String> = []
            var degraded: Set<String> = []
            for directory in discovered {
                try Task.checkCancellation()
                let path = directory.standardizedFileURL.path
                do {
                    if let session = try await grokParser.parse(directory: directory, payloadStore: payloadStore) {
                        results.append(session)
                        if session.sourceState == .degraded {
                            degraded.insert(path)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed.insert(path)
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

        if isReadableDirectory(directories.cursorProjects) {
            let discovered = cursorParser.discover(in: directories.cursorProjects)
            var failed: Set<String> = []
            var degraded: Set<String> = []
            for fileURL in discovered {
                try Task.checkCancellation()
                let path = fileURL.standardizedFileURL.path
                do {
                    if let session = try await cursorParser.parse(fileURL: fileURL, payloadStore: payloadStore) {
                        results.append(session)
                        if session.sourceState == .degraded {
                            degraded.insert(path)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed.insert(path)
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
}
