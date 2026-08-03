import Foundation

struct CodexSessionParser {
    /// Test seam invoked after the first-pass scan and before second-pass payload writes.
    var betweenPasses: (@Sendable () async throws -> Void)?

    func discover(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension.caseInsensitiveCompare("jsonl") == .orderedSame,
                  Self.isRegularNonSymlink(url)
            else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    func parse(fileURL: URL, payloadStore: PayloadStore) async throws -> ParsedSession? {
        guard Self.isRegularNonSymlink(fileURL) else { throw TraceParserError.unavailable(fileURL) }
        let sourcePath = fileURL.standardizedFileURL.path
        let sourceKey = "codex:\(sourcePath)"
        let modificationDate = fileURL.modificationDate

        struct RawEvent {
            let lineIndex: Int
            let digest: String
            let baseIdentity: String
            let eventType: String
            let role: String?
            let date: Date
            let kind: StepKind
            let title: String
            let text: String
            let path: String?
            let error: Bool
            let command: String?
            let exitCode: Int?
            let tokenCount: Int?
            let fileChanges: [ParsedFileChange]
            var identity: String = ""
            var payloadReference: String?
        }

        var workingDirectory = ""
        var events: [RawEvent] = []
        var capped = false
        let firstStats = try await JSONLineSupport.forEachDictionary(at: fileURL) { lineIndex, record, rawPayload in
            try Task.checkCancellation()
            let payload = JSONLineSupport.dictionary(record["payload"]) ?? record
            let outerType = JSONLineSupport.string(JSONLineSupport.firstValue(in: record, keys: ["type"]))
            let payloadType = JSONLineSupport.string(JSONLineSupport.firstValue(in: payload, keys: ["type"]))
            let eventType = TraceLimits.required((payloadType ?? outerType ?? "event").lowercased(), to: TraceLimits.eventType)
            let role = TraceLimits.bounded(
                JSONLineSupport.firstString(in: payload, keys: ["role"]) ?? JSONLineSupport.firstString(in: record, keys: ["role"]),
                to: TraceLimits.role,
                trim: true
            )?.lowercased()
            let eventDate = JSONLineSupport.firstDate(in: record as Any, keys: ["timestamp", "ts", "created_at", "createdAt", "time"]) ?? modificationDate

            if let cwd = TraceLimits.bounded(JSONLineSupport.firstString(in: payload, keys: ["cwd", "working_directory", "workingDirectory"]), to: TraceLimits.path, trim: true), !cwd.isEmpty {
                workingDirectory = cwd
            }
            guard eventType != "session_meta", eventType != "session_metadata" else { return }
            guard events.count < TraceLimits.maxSteps else {
                capped = true
                return
            }

            let text = JSONLineSupport.compactText(from: payload)
            let path = TraceLimits.bounded(JSONLineSupport.firstPath(in: payload), to: TraceLimits.path)
            let command = TraceLimits.bounded(JSONLineSupport.firstString(in: payload, keys: ["command", "cmd", "input"]), to: TraceLimits.command)
            let kind = Self.kind(for: eventType, role: role, payload: payload, text: text, command: command)
            let hasError = eventType.contains("error") || JSONLineSupport.isTruthyError(payload["error"]) || kind == .error
            let stepTitle = Self.title(for: kind, eventType: eventType, text: text, path: path)

            events.append(RawEvent(
                lineIndex: lineIndex,
                digest: StableTraceIdentity.payloadDigest(rawPayload),
                baseIdentity: StableTraceIdentity.baseIdentity(record: record, rawPayload: rawPayload),
                eventType: eventType,
                role: role,
                date: eventDate,
                kind: kind,
                title: stepTitle,
                text: text,
                path: path,
                error: hasError,
                command: command,
                exitCode: JSONLineSupport.firstInteger(in: payload as Any, keys: ["exit_code", "exitCode", "code"]),
                tokenCount: JSONLineSupport.tokenCount(in: payload),
                fileChanges: JSONLineSupport.fileChanges(in: payload, eventType: eventType)
            ))
        }

        if firstStats.isMalformedOnly {
            throw TraceParserError.malformedOnly(fileURL)
        }
        guard firstStats.validRecords > 0, !events.isEmpty else { return nil }

        let identities = StableTraceIdentity.assignIdentities(to: events.map(\.baseIdentity))
        for index in events.indices { events[index].identity = identities[index] }
        let expectedLines = Set(events.map(\.lineIndex))
        var seenLines = Set<Int>()
        let eventsByLine = Dictionary(uniqueKeysWithValues: events.map { ($0.lineIndex, $0) })

        if let betweenPasses {
            try await betweenPasses()
        }

        // Second pass persists payloads and detects mid-scan mutation: every
        // first-pass event line must reappear with the same digest, and the
        // overall valid-record count must match.
        let secondStats = try await JSONLineSupport.forEachDictionary(at: fileURL) { lineIndex, _, rawPayload in
            try Task.checkCancellation()
            guard let event = eventsByLine[lineIndex] else { return }
            guard StableTraceIdentity.payloadDigest(rawPayload) == event.digest else {
                throw TraceParserError.sourceChanged(fileURL)
            }
            seenLines.insert(lineIndex)
            let reference = try await payloadStore.write(
                rawPayload,
                key: StableTraceIdentity.payloadKey(for: "\(sourceKey)#\(event.identity)")
            )
            guard let index = events.firstIndex(where: { $0.lineIndex == lineIndex }) else { return }
            events[index].payloadReference = reference
        }
        guard secondStats.validRecords == firstStats.validRecords,
              seenLines == expectedLines,
              events.allSatisfy({ $0.payloadReference != nil })
        else {
            throw TraceParserError.sourceChanged(fileURL)
        }

        events.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.identity != $1.identity { return $0.identity < $1.identity }
            return $0.lineIndex < $1.lineIndex
        }
        let title = events.first(where: { $0.kind == .user && !$0.text.isEmpty })?.text ?? fileURL.deletingPathExtension().lastPathComponent
        let steps = events.enumerated().map { index, event in
            ParsedStep(
                identity: event.identity,
                index: index,
                kind: event.kind,
                timestamp: event.date,
                title: event.title,
                summary: event.text.isEmpty ? event.title : event.text,
                searchText: [event.eventType, event.role, event.text, event.path, event.command].compactMap { $0 }.joined(separator: " "),
                payloadReference: event.payloadReference,
                hasError: event.error,
                commandText: event.command,
                filePath: event.path,
                exitCode: event.exitCode,
                tokenCount: event.tokenCount,
                fileChanges: event.fileChanges
            )
        }
        let projectPath = TraceLimits.required(workingDirectory, to: TraceLimits.path)
        let sourceState: SessionSourceState = (firstStats.hasProblems || capped) ? .degraded : .scanned
        return ParsedSession(
            sourceKey: sourceKey,
            agentType: .codex,
            title: title,
            startDate: steps.first?.timestamp ?? modificationDate,
            endDate: steps.last?.timestamp,
            workingDirectory: projectPath,
            sourcePath: sourcePath,
            sourceModifiedAt: modificationDate,
            status: JSONLineSupport.sessionStatus(for: modificationDate),
            sourceState: sourceState,
            projectIdentity: projectPath.isEmpty ? "codex:unknown" : "path:\(projectPath)",
            projectPath: projectPath,
            projectName: Self.projectName(for: projectPath),
            steps: steps
        )
    }

    private static func kind(for eventType: String, role: String?, payload: [String: Any], text: String, command: String?) -> StepKind {
        if eventType.contains("error") || JSONLineSupport.isTruthyError(payload["error"]) { return .error }
        if eventType.contains("function_call_output") || eventType.contains("tool_result") || eventType.contains("command_execution_output") { return .toolResult }
        let toolName = JSONLineSupport.firstString(in: payload, keys: ["name", "tool_name", "toolName"])?.lowercased()
        if eventType.contains("shell") || eventType.contains("command_execution") || ["shell", "exec", "terminal", "run_command"].contains(toolName) { return .shellCommand }
        if eventType.contains("function_call") || eventType.contains("custom_tool_call") || eventType.contains("tool_call") || eventType.contains("tool_use") { return .toolCall }
        if command != nil && eventType.contains("command") { return .shellCommand }
        if eventType.contains("reasoning") || eventType.contains("thought") { return .thought }
        if eventType.contains("file") || eventType.contains("patch") { return .fileChange }
        if role == "user" { return .user }
        if role == "assistant" || (!text.isEmpty && eventType.contains("message")) { return .assistant }
        return .system
    }

    private static func title(for kind: StepKind, eventType: String, text: String, path: String?) -> String {
        if !text.isEmpty { return text }
        if let path, kind == .fileChange { return path }
        return kind == .system ? eventType.replacingOccurrences(of: "_", with: " ").capitalized : kind.displayName
    }

    private static func projectName(for path: String) -> String {
        guard !path.isEmpty else { return "Unknown project" }
        return TraceLimits.required(URL(fileURLWithPath: path).lastPathComponent, to: TraceLimits.projectName, fallback: "Unknown project")
    }

    private static func isRegularNonSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

private extension URL {
    var modificationDate: Date {
        (try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
    }
}
