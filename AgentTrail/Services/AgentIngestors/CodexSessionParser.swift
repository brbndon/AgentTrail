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
        }.sorted {
            if $0.modificationDate != $1.modificationDate { return $0.modificationDate > $1.modificationDate }
            return $0.path > $1.path
        }
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
            let outerType: String
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

        var metadataWorkingDirectory = ""
        var contextualWorkingDirectory = ""
        var metadataStartDate: Date?
        var canonicalTitle: String?
        var hasCanonicalUserMessage = false
        var toolNamesByCallID: [String: String] = [:]
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
                if eventType == "session_meta" || eventType == "session_metadata" {
                    metadataWorkingDirectory = cwd
                } else {
                    contextualWorkingDirectory = cwd
                }
            }
            if eventType == "session_meta" || eventType == "session_metadata" {
                metadataStartDate = JSONLineSupport.firstDate(in: payload as Any, keys: ["timestamp", "created_at", "createdAt"]) ?? eventDate
                return
            }
            guard !Self.isContextOnly(eventType: eventType, role: role) else { return }
            guard events.count < TraceLimits.maxSteps else {
                capped = true
                return
            }

            let embeddedPayload = Self.embeddedPayload(in: payload)
            let toolName = JSONLineSupport.firstString(in: payload, keys: ["name", "tool_name", "toolName"])
            let callID = JSONLineSupport.firstString(in: payload, keys: ["call_id", "callId"])
            if let callID, let toolName { toolNamesByCallID[callID] = toolName }
            let resolvedToolName = toolName ?? callID.flatMap { toolNamesByCallID[$0] }
            let text = Self.summary(payload: payload, embeddedPayload: embeddedPayload, eventType: eventType)
            if eventType == "user_message" {
                hasCanonicalUserMessage = true
                if canonicalTitle == nil, !text.isEmpty { canonicalTitle = text }
            }
            let path = TraceLimits.bounded(JSONLineSupport.firstPath(in: embeddedPayload ?? payload), to: TraceLimits.path)
            let command = Self.command(payload: payload, embeddedPayload: embeddedPayload, toolName: resolvedToolName)
            let exitCode = JSONLineSupport.firstInteger(in: embeddedPayload ?? payload, keys: ["exit_code", "exitCode", "code"])
            let kind = Self.kind(for: eventType, role: role, payload: payload, text: text, command: command)
            let hasError = eventType.contains("error")
                || JSONLineSupport.isTruthyError(payload["error"])
                || JSONLineSupport.isTruthyError(embeddedPayload?["error"])
                || JSONLineSupport.isTruthyError(embeddedPayload?["isError"])
                || exitCode.map { $0 != 0 } == true
                || kind == .error
            let stepTitle = Self.title(for: kind, eventType: eventType, path: path, toolName: resolvedToolName, payload: payload)

            events.append(RawEvent(
                lineIndex: lineIndex,
                digest: StableTraceIdentity.payloadDigest(rawPayload),
                baseIdentity: StableTraceIdentity.baseIdentity(record: record, rawPayload: rawPayload),
                outerType: outerType ?? "event",
                eventType: eventType,
                role: role,
                date: eventDate,
                kind: kind,
                title: stepTitle,
                text: text,
                path: path,
                error: hasError,
                command: command,
                exitCode: exitCode,
                tokenCount: JSONLineSupport.tokenCount(in: payload),
                fileChanges: JSONLineSupport.fileChanges(in: payload, eventType: eventType)
            ))
        }

        if firstStats.isMalformedOnly {
            throw TraceParserError.malformedOnly(fileURL)
        }
        if hasCanonicalUserMessage {
            events.removeAll {
                $0.outerType == "response_item"
                    && $0.eventType == "message"
                    && ($0.role == "user" || $0.role == "assistant")
            }
        } else {
            events.removeAll {
                $0.eventType == "message" && Self.isInjectedContext($0.text)
            }
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
        let title = canonicalTitle
            ?? events.first(where: { $0.kind == .user && !$0.text.isEmpty })?.text
            ?? fileURL.deletingPathExtension().lastPathComponent
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
        let projectPath = TraceLimits.required(metadataWorkingDirectory.isEmpty ? contextualWorkingDirectory : metadataWorkingDirectory, to: TraceLimits.path)
        let sourceState: SessionSourceState = (firstStats.hasProblems || capped) ? .degraded : .scanned
        return ParsedSession(
            sourceKey: sourceKey,
            agentType: .codex,
            title: title,
            startDate: metadataStartDate ?? steps.first?.timestamp ?? modificationDate,
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
        let toolLeaf = toolName?.split(separator: ".").last.map(String.init)
        if eventType.contains("shell") || eventType.contains("command_execution") || ["shell", "exec", "terminal", "run_command"].contains(toolLeaf) { return .shellCommand }
        if eventType.contains("function_call") || eventType.contains("custom_tool_call") || eventType.contains("tool_call") || eventType.contains("tool_use") { return .toolCall }
        if command != nil && eventType.contains("command") { return .shellCommand }
        if eventType.contains("reasoning") || eventType.contains("thought") { return .thought }
        if eventType.contains("file") || eventType.contains("patch") { return .fileChange }
        if role == "user" || eventType == "user_message" { return .user }
        if role == "assistant" || eventType == "agent_message" || (!text.isEmpty && eventType == "assistant_message") { return .assistant }
        return .system
    }

    private static func title(
        for kind: StepKind,
        eventType: String,
        path: String?,
        toolName: String?,
        payload: [String: Any]
    ) -> String {
        switch kind {
        case .user: return "User request"
        case .assistant:
            return JSONLineSupport.firstString(in: payload, keys: ["phase"]) == "commentary" ? "Agent update" : "Agent response"
        case .thought: return "Agent reasoning"
        case .shellCommand: return toolName.map { "Run \(displayName(for: $0))" } ?? "Run shell command"
        case .toolCall: return toolName.map { "Call \(displayName(for: $0))" } ?? "Tool call"
        case .toolResult: return toolName.map { "\(displayName(for: $0)) result" } ?? "Tool result"
        case .fileChange: return path ?? "File change"
        case .error: return "Error"
        case .system: return eventType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func isContextOnly(eventType: String, role: String?) -> Bool {
        if eventType == "message", role == "developer" || role == "system" { return true }
        return ["task_started", "task_complete", "turn_context", "world_state", "token_count"].contains(eventType)
    }

    private static func isInjectedContext(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "# agents.md instructions",
            "<instructions>",
            "<environment_context>",
            "<app-context>",
            "<multi_agent_mode>",
            "you are `/root`"
        ].contains { normalized.hasPrefix($0) }
    }

    private static func embeddedPayload(in payload: [String: Any]) -> [String: Any]? {
        for key in ["arguments", "input", "output"] {
            if let dictionary = payload[key] as? [String: Any] { return dictionary }
            guard let string = payload[key] as? String,
                  let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any]
            else { continue }
            return dictionary
        }
        return nil
    }

    private static func summary(payload: [String: Any], embeddedPayload: [String: Any]?, eventType: String) -> String {
        let primary = JSONLineSupport.compactText(from: payload)
        if !primary.isEmpty, primary != JSONLineSupport.firstString(in: payload, keys: ["name"]) { return primary }
        if let embeddedPayload {
            let embedded = JSONLineSupport.compactText(from: embeddedPayload)
            if !embedded.isEmpty { return embedded }
        }
        return primary.isEmpty ? eventType.replacingOccurrences(of: "_", with: " ") : primary
    }

    private static func command(payload: [String: Any], embeddedPayload: [String: Any]?, toolName: String?) -> String? {
        if let embeddedPayload,
           let command = JSONLineSupport.firstString(in: embeddedPayload as Any, keys: ["command", "cmd", "input"]) {
            return TraceLimits.bounded(command, to: TraceLimits.command)
        }
        if ["shell", "exec", "terminal", "run_command"].contains(toolName?.lowercased()),
           let input = JSONLineSupport.firstString(in: payload, keys: ["input", "arguments"]) {
            return TraceLimits.bounded(input, to: TraceLimits.command)
        }
        return TraceLimits.bounded(JSONLineSupport.firstString(in: payload, keys: ["command", "cmd"]), to: TraceLimits.command)
    }

    private static func displayName(for toolName: String) -> String {
        let leaf = toolName.split(separator: ".").last.map(String.init) ?? toolName
        return leaf.replacingOccurrences(of: "_", with: " ")
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
