import Foundation

struct CursorSessionParser {
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
                  url.pathComponents.contains("agent-transcripts"),
                  url.deletingLastPathComponent().lastPathComponent == url.deletingPathExtension().lastPathComponent,
                  Self.isRegularNonSymlink(url)
            else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    func parse(fileURL: URL, payloadStore: PayloadStore) async throws -> ParsedSession? {
        guard Self.isRegularNonSymlink(fileURL) else { throw TraceParserError.unavailable(fileURL) }
        let sourcePath = fileURL.standardizedFileURL.path
        let sourceKey = "cursor:\(sourcePath)"
        let modificationDate = fileURL.modificationDate

        struct RawEvent {
            let lineIndex: Int
            let digest: String
            let baseIdentity: String
            let role: String?
            let contentTypes: String
            let text: String
            let status: String?
            let eventType: String
            let timestamp: Date
            let kind: StepKind
            let hasError: Bool
            let command: String?
            let filePath: String?
            let exitCode: Int?
            let tokenCount: Int?
            let fileChanges: [ParsedFileChange]
            var identity: String = ""
            var payloadReference: String?
        }

        var events: [RawEvent] = []
        var terminalStatus: String?
        var capped = false
        let firstStats = try await JSONLineSupport.forEachDictionary(at: fileURL) { lineIndex, record, rawPayload in
            try Task.checkCancellation()
            let message = JSONLineSupport.dictionary(JSONLineSupport.firstValue(in: record, keys: ["message"]))
            let role = TraceLimits.bounded(
                JSONLineSupport.firstString(in: message ?? [:], keys: ["role", "sender", "author"])
                    ?? JSONLineSupport.firstString(in: record, keys: ["role", "sender", "author"]),
                to: TraceLimits.role,
                trim: true
            )?.lowercased()
            let content = JSONLineSupport.array(JSONLineSupport.firstValue(in: message ?? record, keys: ["content"]))
            let text = JSONLineSupport.compactText(from: message ?? record)
            let contentTypes = TraceLimits.required(
                content.compactMap { JSONLineSupport.string(JSONLineSupport.dictionary($0)?["type"]) }.joined(separator: " ").lowercased(),
                to: TraceLimits.eventType
            )
            let status = TraceLimits.bounded(JSONLineSupport.firstString(in: record, keys: ["status", "state"]), to: TraceLimits.eventType, trim: true)?.lowercased()
            if let status, ["completed", "complete", "success", "succeeded", "failed", "failure", "error"].contains(status) {
                terminalStatus = status
            }
            let eventType = TraceLimits.required(JSONLineSupport.firstString(in: record, keys: ["type", "event_type", "eventType"])?.lowercased() ?? "", to: TraceLimits.eventType)
            let hasError = ["error", "failed", "failure"].contains(status) || JSONLineSupport.isTruthyError(record["error"]) || contentTypes.contains("error")
            let command = TraceLimits.bounded(JSONLineSupport.firstString(in: message ?? record, keys: ["command", "cmd", "input"]), to: TraceLimits.command)
            let toolName = JSONLineSupport.firstString(in: message ?? record, keys: ["name", "tool_name", "toolName"])?.lowercased()
            let kind: StepKind
            if hasError { kind = .error }
            else if contentTypes.contains("tool-result") || contentTypes.contains("tool_result") || eventType.contains("tool_result") { kind = .toolResult }
            else if ["shell", "exec", "terminal", "run_command"].contains(toolName) || (command != nil && contentTypes.contains("tool")) { kind = .shellCommand }
            else if contentTypes.contains("tool") || contentTypes.contains("function") || eventType.contains("tool_call") { kind = .toolCall }
            else if role == "user" { kind = .user }
            else if role == "assistant" { kind = .assistant }
            else { kind = .system }

            // Empty status-only records are bookkeeping, not timeline events.
            guard Self.isEventEligible(text: text, hasError: hasError, kind: kind) else { return }
            guard events.count < TraceLimits.maxSteps else {
                capped = true
                return
            }
            let timestamp = JSONLineSupport.firstDate(in: record as Any, keys: ["timestamp", "ts", "created_at", "createdAt", "time"]) ?? modificationDate
            let filePath = TraceLimits.bounded(JSONLineSupport.firstPath(in: record), to: TraceLimits.path)
            events.append(RawEvent(
                lineIndex: lineIndex,
                digest: StableTraceIdentity.payloadDigest(rawPayload),
                baseIdentity: StableTraceIdentity.baseIdentity(record: record, rawPayload: rawPayload),
                role: role,
                contentTypes: contentTypes,
                text: text,
                status: status,
                eventType: eventType,
                timestamp: timestamp,
                kind: kind,
                hasError: hasError,
                command: command,
                filePath: filePath,
                exitCode: JSONLineSupport.firstInteger(in: record as Any, keys: ["exit_code", "exitCode", "code"]),
                tokenCount: JSONLineSupport.tokenCount(in: record),
                fileChanges: JSONLineSupport.fileChanges(in: message ?? record, eventType: eventType)
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

        // Second pass: re-derive event eligibility so a filtered bookkeeping line
        // that mutates into a real event (or the reverse) is treated as sourceChanged
        // even when valid-record counts still match.
        let secondStats = try await JSONLineSupport.forEachDictionary(at: fileURL) { lineIndex, record, rawPayload in
            try Task.checkCancellation()
            let isEligible = Self.isEventEligible(record: record)
            if let event = eventsByLine[lineIndex] {
                guard isEligible else { throw TraceParserError.sourceChanged(fileURL) }
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
            } else if isEligible {
                throw TraceParserError.sourceChanged(fileURL)
            }
        }
        guard secondStats.validRecords == firstStats.validRecords,
              seenLines == expectedLines,
              events.allSatisfy({ $0.payloadReference != nil })
        else {
            throw TraceParserError.sourceChanged(fileURL)
        }

        events.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.identity != $1.identity { return $0.identity < $1.identity }
            return $0.lineIndex < $1.lineIndex
        }
        let title = events.first(where: { $0.kind == .user && !$0.text.isEmpty })?.text ?? fileURL.deletingPathExtension().lastPathComponent
        let steps = events.enumerated().map { index, event in
            ParsedStep(
                identity: event.identity,
                index: index,
                kind: event.kind,
                timestamp: event.timestamp,
                title: event.text.isEmpty ? (event.status ?? event.kind.displayName) : event.text,
                summary: event.text.isEmpty ? (event.status ?? event.kind.displayName) : event.text,
                searchText: [event.role, event.contentTypes, event.eventType, event.text, event.status, event.command].compactMap { $0 }.joined(separator: " "),
                payloadReference: event.payloadReference,
                hasError: event.hasError,
                commandText: event.command,
                filePath: event.filePath,
                exitCode: event.exitCode,
                tokenCount: event.tokenCount,
                fileChanges: event.fileChanges
            )
        }
        let projectDirectory = fileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let projectKey = TraceLimits.required(projectDirectory.lastPathComponent, to: TraceLimits.projectName, fallback: "Unknown project")
        let sourceState: SessionSourceState = (firstStats.hasProblems || capped) ? .degraded : .scanned
        return ParsedSession(
            sourceKey: sourceKey,
            agentType: .cursor,
            title: title,
            startDate: steps.first?.timestamp ?? modificationDate,
            endDate: steps.last?.timestamp,
            workingDirectory: "",
            sourcePath: sourcePath,
            sourceModifiedAt: modificationDate,
            status: JSONLineSupport.sessionStatus(for: modificationDate, terminalStatus: terminalStatus),
            sourceState: sourceState,
            projectIdentity: "cursor:\(projectKey)",
            projectPath: "",
            projectName: projectKey.replacingOccurrences(of: "-", with: " "),
            steps: steps
        )
    }

    /// Same eligibility used in both passes so filtered bookkeeping lines cannot
    /// silently become timeline events between scans.
    private static func isEventEligible(record: [String: Any]) -> Bool {
        let message = JSONLineSupport.dictionary(JSONLineSupport.firstValue(in: record, keys: ["message"]))
        let role = TraceLimits.bounded(
            JSONLineSupport.firstString(in: message ?? [:], keys: ["role", "sender", "author"])
                ?? JSONLineSupport.firstString(in: record, keys: ["role", "sender", "author"]),
            to: TraceLimits.role,
            trim: true
        )?.lowercased()
        let content = JSONLineSupport.array(JSONLineSupport.firstValue(in: message ?? record, keys: ["content"]))
        let text = JSONLineSupport.compactText(from: message ?? record)
        let contentTypes = TraceLimits.required(
            content.compactMap { JSONLineSupport.string(JSONLineSupport.dictionary($0)?["type"]) }.joined(separator: " ").lowercased(),
            to: TraceLimits.eventType
        )
        let status = TraceLimits.bounded(JSONLineSupport.firstString(in: record, keys: ["status", "state"]), to: TraceLimits.eventType, trim: true)?.lowercased()
        let eventType = TraceLimits.required(JSONLineSupport.firstString(in: record, keys: ["type", "event_type", "eventType"])?.lowercased() ?? "", to: TraceLimits.eventType)
        let hasError = ["error", "failed", "failure"].contains(status) || JSONLineSupport.isTruthyError(record["error"]) || contentTypes.contains("error")
        let command = TraceLimits.bounded(JSONLineSupport.firstString(in: message ?? record, keys: ["command", "cmd", "input"]), to: TraceLimits.command)
        let toolName = JSONLineSupport.firstString(in: message ?? record, keys: ["name", "tool_name", "toolName"])?.lowercased()
        let kind: StepKind
        if hasError { kind = .error }
        else if contentTypes.contains("tool-result") || contentTypes.contains("tool_result") || eventType.contains("tool_result") { kind = .toolResult }
        else if ["shell", "exec", "terminal", "run_command"].contains(toolName) || (command != nil && contentTypes.contains("tool")) { kind = .shellCommand }
        else if contentTypes.contains("tool") || contentTypes.contains("function") || eventType.contains("tool_call") { kind = .toolCall }
        else if role == "user" { kind = .user }
        else if role == "assistant" { kind = .assistant }
        else { kind = .system }
        return isEventEligible(text: text, hasError: hasError, kind: kind)
    }

    private static func isEventEligible(text: String, hasError: Bool, kind: StepKind) -> Bool {
        !text.isEmpty || hasError || kind != .system
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
