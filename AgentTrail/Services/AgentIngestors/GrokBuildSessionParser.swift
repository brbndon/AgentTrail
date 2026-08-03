import Foundation

struct GrokBuildSessionParser {
    private static let recognizedFiles = ["events.jsonl", "chat_history.jsonl", "prompt_history.jsonl", "rewind_points.jsonl"]

    func discover(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: Set<URL> = []
        for case let url as URL in enumerator {
            guard Self.recognizedFiles.contains(url.lastPathComponent), Self.isRegularNonSymlink(url) else { continue }
            sessions.insert(url.deletingLastPathComponent().standardizedFileURL)
        }
        return sessions.sorted { $0.path < $1.path }
    }

    func parse(directory: URL, payloadStore: PayloadStore) async throws -> ParsedSession? {
        let files = Self.recognizedFiles.compactMap { name -> URL? in
            let url = directory.appendingPathComponent(name)
            guard Self.isRegularNonSymlink(url) else { return nil }
            return url
        }
        guard !files.isEmpty else { throw TraceParserError.unavailable(directory) }

        struct RawEvent {
            let filePath: String
            let lineIndex: Int
            let digest: String
            let baseIdentity: String
            let eventType: String
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

        let sourcePath = directory.standardizedFileURL.path
        let sourceKey = "grok:\(sourcePath)"
        var records: [RawEvent] = []
        var title = ""
        var terminalStatus: String?
        var totalValidRecords = 0
        var hasProblems = false
        var capped = false
        var sawAnyContent = false
        var malformedOnly = true

        for file in files {
            try Task.checkCancellation()
            let modificationDate = file.modificationDate
            let stats = try await JSONLineSupport.forEachDictionary(at: file) { lineIndex, record, rawPayload in
                try Task.checkCancellation()
                sawAnyContent = true
                malformedOnly = false
                let eventType = TraceLimits.required(
                    (JSONLineSupport.firstString(in: record, keys: ["type", "event_type", "eventType"]) ?? file.deletingPathExtension().lastPathComponent).lowercased(),
                    to: TraceLimits.eventType
                )
                let date = JSONLineSupport.firstDate(in: record as Any, keys: ["ts", "timestamp", "created_at", "createdAt", "time"]) ?? modificationDate
                let role = JSONLineSupport.firstString(in: record, keys: ["role", "sender", "author"])?.lowercased()
                let prompt = JSONLineSupport.firstString(in: record, keys: ["prompt", "user_prompt"])
                let text = JSONLineSupport.compactText(from: record)
                let command = TraceLimits.bounded(JSONLineSupport.firstString(in: record, keys: ["command", "cmd", "input"]), to: TraceLimits.command)
                let kind: StepKind
                if eventType.contains("error") || JSONLineSupport.isTruthyError(record["error"]) || role == "error" {
                    kind = .error
                } else if file.lastPathComponent == "prompt_history.jsonl" || prompt != nil || role == "user" || role == "human" || eventType.contains("prompt") {
                    kind = .user
                } else if role == "assistant" || role == "model" || role == "grok" {
                    kind = .assistant
                } else if eventType.contains("rewind") {
                    kind = .fileChange
                } else if eventType.contains("tool_result") || eventType.contains("result") {
                    kind = .toolResult
                } else if eventType.contains("tool") || eventType.contains("function") {
                    kind = .toolCall
                } else if eventType.contains("command") || command != nil {
                    kind = .shellCommand
                } else {
                    kind = .system
                }
                let status = JSONLineSupport.firstString(in: record, keys: ["status", "state"])?.lowercased()
                if let status, ["completed", "complete", "success", "succeeded", "failed", "failure", "error"].contains(status) {
                    terminalStatus = status
                }
                if title.isEmpty, kind == .user, !text.isEmpty { title = text }
                guard records.count < TraceLimits.maxSteps else {
                    capped = true
                    return
                }
                records.append(RawEvent(
                    filePath: file.path,
                    lineIndex: lineIndex,
                    digest: StableTraceIdentity.payloadDigest(rawPayload),
                    baseIdentity: StableTraceIdentity.baseIdentity(record: record, rawPayload: rawPayload),
                    eventType: eventType,
                    date: date,
                    kind: kind,
                    title: text.isEmpty ? kind.displayName : text,
                    text: text,
                    path: TraceLimits.bounded(JSONLineSupport.firstPath(in: record), to: TraceLimits.path),
                    error: kind == .error,
                    command: command,
                    exitCode: JSONLineSupport.firstInteger(in: record as Any, keys: ["exit_code", "exitCode", "code"]),
                    tokenCount: JSONLineSupport.tokenCount(in: record),
                    fileChanges: JSONLineSupport.fileChanges(in: record, eventType: eventType)
                ))
            }
            totalValidRecords += stats.validRecords
            if stats.hasProblems { hasProblems = true }
            if stats.isMalformedOnly { /* keep malformedOnly if no valid files */ }
            else if stats.validRecords > 0 { malformedOnly = false }
        }

        if totalValidRecords == 0 {
            if sawAnyContent || hasProblems {
                throw TraceParserError.malformedOnly(directory)
            }
            // All empty files: treat as empty source.
            if malformedOnly && hasProblems {
                throw TraceParserError.malformedOnly(directory)
            }
            return nil
        }
        guard !records.isEmpty else { return nil }

        let identities = StableTraceIdentity.assignIdentities(to: records.map(\.baseIdentity))
        for index in records.indices { records[index].identity = identities[index] }
        let expectedLocations = Set(records.map { "\($0.filePath)#\($0.lineIndex)" })
        var seenLocations = Set<String>()
        var secondValidTotal = 0
        let recordsByLocation = Dictionary(uniqueKeysWithValues: records.map { ("\($0.filePath)#\($0.lineIndex)", $0) })
        let indexByLocation = Dictionary(uniqueKeysWithValues: records.enumerated().map { ("\($0.element.filePath)#\($0.element.lineIndex)", $0.offset) })

        for file in files {
            let stats = try await JSONLineSupport.forEachDictionary(at: file) { lineIndex, _, rawPayload in
                try Task.checkCancellation()
                let location = "\(file.path)#\(lineIndex)"
                guard let record = recordsByLocation[location] else { return }
                guard StableTraceIdentity.payloadDigest(rawPayload) == record.digest else { throw TraceParserError.sourceChanged(file) }
                seenLocations.insert(location)
                let reference = try await payloadStore.write(
                    rawPayload,
                    key: StableTraceIdentity.payloadKey(for: "\(sourceKey)#\(record.identity)")
                )
                guard let index = indexByLocation[location] else { return }
                records[index].payloadReference = reference
            }
            secondValidTotal += stats.validRecords
        }
        guard secondValidTotal == totalValidRecords,
              seenLocations == expectedLocations,
              records.allSatisfy({ $0.payloadReference != nil })
        else {
            throw TraceParserError.sourceChanged(directory)
        }

        records.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.filePath != $1.filePath { return $0.filePath < $1.filePath }
            if $0.identity != $1.identity { return $0.identity < $1.identity }
            return $0.lineIndex < $1.lineIndex
        }
        let encodedProject = directory.deletingLastPathComponent().lastPathComponent
        let decodedProject = encodedProject.removingPercentEncoding ?? encodedProject
        let projectPath = decodedProject.hasPrefix("/") ? TraceLimits.required(decodedProject, to: TraceLimits.path) : ""
        let projectName = projectPath.isEmpty
            ? TraceLimits.required(encodedProject.replacingOccurrences(of: "-", with: " "), to: TraceLimits.projectName, fallback: "Unknown project")
            : TraceLimits.required(URL(fileURLWithPath: projectPath).lastPathComponent, to: TraceLimits.projectName, fallback: "Unknown project")
        let steps = records.enumerated().map { index, record in
            ParsedStep(
                identity: record.identity,
                index: index,
                kind: record.kind,
                timestamp: record.date,
                title: record.title,
                summary: record.text.isEmpty ? record.title : record.text,
                searchText: [record.title, record.text, record.path, record.eventType].compactMap { $0 }.joined(separator: " "),
                payloadReference: record.payloadReference,
                hasError: record.error,
                commandText: record.command,
                filePath: record.path,
                exitCode: record.exitCode,
                tokenCount: record.tokenCount,
                fileChanges: record.fileChanges
            )
        }
        let sourceModifiedAt = files.map(\.modificationDate).max() ?? directory.modificationDate
        let sourceState: SessionSourceState = (hasProblems || capped) ? .degraded : .scanned
        return ParsedSession(
            sourceKey: sourceKey,
            agentType: .grokBuild,
            title: title.isEmpty ? projectName : title,
            startDate: steps.first?.timestamp ?? sourceModifiedAt,
            endDate: steps.last?.timestamp,
            workingDirectory: projectPath,
            sourcePath: sourcePath,
            sourceModifiedAt: sourceModifiedAt,
            status: JSONLineSupport.sessionStatus(for: sourceModifiedAt, terminalStatus: terminalStatus),
            sourceState: sourceState,
            projectIdentity: projectPath.isEmpty ? "grok:\(encodedProject)" : "path:\(projectPath)",
            projectPath: projectPath,
            projectName: projectName,
            steps: steps
        )
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
