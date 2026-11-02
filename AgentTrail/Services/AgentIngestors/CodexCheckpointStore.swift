import CryptoKit
import Darwin
import Foundation

struct CodexIncrementalParseResult: Sendable {
    let session: ParsedSession?
    let resumedFromOffset: UInt64?
    let bytesRead: UInt64
    let checkpointWasReset: Bool
    let hadTrailingPartialRecord: Bool
}

private struct CodexIngestionCheckpoint: Codable, Sendable {
    static let currentVersion = 4

    let version: Int
    let sourceKey: String
    let device: UInt64
    let inode: UInt64
    let processedOffset: UInt64
    let observedFileSize: UInt64
    let modificationNanoseconds: Int64
    let leadingDigest: String
    let boundaryDigest: String
    let session: ParsedSession
}

actor CodexCheckpointStore {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootURL = (rootURL ?? applicationSupport
            .appendingPathComponent("AgentTrail", isDirectory: true)
            .appendingPathComponent("Checkpoints", isDirectory: true)).standardizedFileURL
    }

    fileprivate func load(sourceKey: String) -> CodexIngestionCheckpoint? {
        let url = checkpointURL(for: sourceKey)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 256 * 1024 * 1024,
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(CodexIngestionCheckpoint.self, from: data),
              checkpoint.version == CodexIngestionCheckpoint.currentVersion,
              checkpoint.sourceKey == sourceKey
        else { return nil }
        return checkpoint
    }

    fileprivate func save(_ checkpoint: CodexIngestionCheckpoint) throws {
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        let destination = checkpointURL(for: checkpoint.sourceKey)
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func ensureRoot() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    }

    private func checkpointURL(for sourceKey: String) -> URL {
        let digest = SHA256.hash(data: Data(sourceKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent("\(digest).json", isDirectory: false)
    }
}

private struct CodexFileSnapshot: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationNanoseconds: Int64
    let modificationDate: Date

    static func capture(_ url: URL) throws -> CodexFileSnapshot {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG
        else { throw TraceParserError.unavailable(url) }
        let seconds = Int64(information.st_mtimespec.tv_sec)
        let nanoseconds = Int64(information.st_mtimespec.tv_nsec)
        return CodexFileSnapshot(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: UInt64(max(information.st_size, 0)),
            modificationNanoseconds: seconds &* 1_000_000_000 &+ nanoseconds,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
        )
    }
}

extension CodexSessionParser {
    func parseIncrementally(
        fileURL: URL,
        payloadStore: PayloadStore,
        checkpointStore: CodexCheckpointStore
    ) async throws -> CodexIncrementalParseResult {
        let sourceURL = fileURL.standardizedFileURL
        let sourceKey = "codex:\(sourceURL.path)"
        let before = try CodexFileSnapshot.capture(sourceURL)
        let completeOffset = try Self.lastCompleteRecordOffset(in: sourceURL, fileSize: before.size)
        let hasTrailingPartial = completeOffset < before.size
        let checkpoint = await checkpointStore.load(sourceKey: sourceKey)
        let canResume = try checkpoint.map {
            try Self.canResume($0, sourceURL: sourceURL, snapshot: before, completeOffset: completeOffset)
        } ?? false
        let startOffset = canResume ? checkpoint?.processedOffset ?? 0 : 0

        if canResume, let checkpoint, completeOffset == checkpoint.processedOffset {
            let unchanged = Self.updatedSession(
                checkpoint.session,
                modificationDate: before.modificationDate
            )
            let refreshed = try Self.makeCheckpoint(
                sourceKey: sourceKey,
                snapshot: before,
                processedOffset: completeOffset,
                sourceURL: sourceURL,
                session: unchanged
            )
            try await checkpointStore.save(refreshed)
            return CodexIncrementalParseResult(
                session: unchanged,
                resumedFromOffset: startOffset,
                bytesRead: 0,
                checkpointWasReset: false,
                hadTrailingPartialRecord: hasTrailingPartial
            )
        }

        guard completeOffset > startOffset else {
            return CodexIncrementalParseResult(
                session: nil,
                resumedFromOffset: nil,
                bytesRead: 0,
                checkpointWasReset: false,
                hadTrailingPartialRecord: hasTrailingPartial || before.size > 0
            )
        }
        let priorSession = canResume ? checkpoint?.session : nil
        let parsed = try await parse(
            fileURL: sourceURL,
            payloadStore: payloadStore,
            byteRange: startOffset..<completeOffset,
            sourceIdentityURL: sourceURL,
            sourceModificationDate: before.modificationDate,
            knownToolNamesByCallID: Self.toolNamesByCallID(in: priorSession),
            hasPriorCanonicalUserMessage: Self.hasCanonicalUserMessage(in: priorSession),
            knownCanonicalEventTypes: Self.canonicalConversationEventTypes(in: priorSession)
        )
        let after = try CodexFileSnapshot.capture(sourceURL)
        guard after == before else { throw TraceParserError.sourceChanged(sourceURL) }

        let session: ParsedSession?
        if canResume, let existing = checkpoint?.session {
            session = Self.merge(existing: existing, appended: parsed, modificationDate: before.modificationDate)
        } else {
            session = parsed
        }
        guard let session else {
            throw TraceParserError.malformedOnly(sourceURL)
        }

        let saved = try Self.makeCheckpoint(
            sourceKey: sourceKey,
            snapshot: before,
            processedOffset: completeOffset,
            sourceURL: sourceURL,
            session: session
        )
        try await checkpointStore.save(saved)
        return CodexIncrementalParseResult(
            session: session,
            resumedFromOffset: canResume ? startOffset : nil,
            bytesRead: completeOffset - startOffset,
            checkpointWasReset: checkpoint != nil && !canResume,
            hadTrailingPartialRecord: hasTrailingPartial
        )
    }

    private static func canResume(
        _ checkpoint: CodexIngestionCheckpoint,
        sourceURL: URL,
        snapshot: CodexFileSnapshot,
        completeOffset: UInt64
    ) throws -> Bool {
        guard checkpoint.device == snapshot.device,
              checkpoint.inode == snapshot.inode,
              checkpoint.processedOffset <= completeOffset,
              checkpoint.processedOffset <= snapshot.size
        else { return false }
        let signatures = try contentSignatures(in: sourceURL, boundary: checkpoint.processedOffset)
        return signatures.leading == checkpoint.leadingDigest
            && signatures.boundary == checkpoint.boundaryDigest
    }

    private static func makeCheckpoint(
        sourceKey: String,
        snapshot: CodexFileSnapshot,
        processedOffset: UInt64,
        sourceURL: URL,
        session: ParsedSession
    ) throws -> CodexIngestionCheckpoint {
        let signatures = try contentSignatures(in: sourceURL, boundary: processedOffset)
        return CodexIngestionCheckpoint(
            version: CodexIngestionCheckpoint.currentVersion,
            sourceKey: sourceKey,
            device: snapshot.device,
            inode: snapshot.inode,
            processedOffset: processedOffset,
            observedFileSize: snapshot.size,
            modificationNanoseconds: snapshot.modificationNanoseconds,
            leadingDigest: signatures.leading,
            boundaryDigest: signatures.boundary,
            session: session
        )
    }

    private static func merge(
        existing: ParsedSession,
        appended: ParsedSession?,
        modificationDate: Date
    ) -> ParsedSession {
        guard let appended else { return updatedSession(existing, modificationDate: modificationDate) }
        var steps = suppressConversationDuplicates(in: existing.steps + appended.steps)
        let identities = StableTraceIdentity.assignIdentities(to: steps.map(\.identityBase))
        steps = zip(steps, identities).map { step, identity in step.copy(identity: identity) }
        steps.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.identity < $1.identity
        }
        steps = steps.enumerated().map { index, step in step.copy(index: index) }
        let projectPath = appended.workingDirectory.isEmpty ? existing.workingDirectory : appended.workingDirectory
        let title = steps.first(where: {
            CodexSessionParser.isCanonicalUserMessage(
                eventType: $0.eventType,
                searchText: $0.searchText
            ) && !$0.summary.isEmpty
        })?.summary
            ?? steps.first(where: { $0.kind == .user && !$0.summary.isEmpty })?.summary
            ?? existing.title
        return ParsedSession(
            sourceKey: existing.sourceKey,
            agentType: .codex,
            title: title,
            startDate: min(existing.startDate, appended.startDate),
            endDate: steps.last?.timestamp,
            workingDirectory: projectPath,
            sourcePath: existing.sourcePath,
            sourceModifiedAt: modificationDate,
            status: JSONLineSupport.sessionStatus(for: modificationDate),
            sourceState: existing.sourceState == .degraded || appended.sourceState == .degraded ? .degraded : .scanned,
            projectIdentity: projectPath.isEmpty ? "codex:unknown" : "path:\(projectPath)",
            projectPath: projectPath,
            projectName: projectPath.isEmpty ? existing.projectName : URL(fileURLWithPath: projectPath).lastPathComponent,
            steps: steps
        )
    }

    private static func updatedSession(_ session: ParsedSession, modificationDate: Date) -> ParsedSession {
        ParsedSession(
            sourceKey: session.sourceKey,
            agentType: session.agentType,
            title: session.title,
            startDate: session.startDate,
            endDate: session.endDate,
            workingDirectory: session.workingDirectory,
            sourcePath: session.sourcePath,
            sourceModifiedAt: modificationDate,
            status: JSONLineSupport.sessionStatus(for: modificationDate),
            sourceState: session.sourceState,
            projectIdentity: session.projectIdentity,
            projectPath: session.projectPath,
            projectName: session.projectName,
            steps: session.steps
        )
    }

    private static func toolNamesByCallID(in session: ParsedSession?) -> [String: String] {
        guard let session else { return [:] }
        return session.steps.reduce(into: [:]) { names, step in
            if let callID = step.toolCallID, let toolName = step.toolName {
                names[callID] = toolName
            }
        }
    }

    private static func hasCanonicalUserMessage(in session: ParsedSession?) -> Bool {
        session?.steps.contains {
            CodexSessionParser.isCanonicalUserMessage(
                eventType: $0.eventType,
                searchText: $0.searchText
            )
        } == true
    }

    private static func canonicalConversationEventTypes(in session: ParsedSession?) -> Set<String> {
        guard let session else { return [] }
        return Set(session.steps.filter { !$0.isCompletedItem }.map(\.eventType))
    }

    private static func suppressConversationDuplicates(in steps: [ParsedStep]) -> [ParsedStep] {
        var steps = steps
        let hasCanonical = steps.contains {
            CodexSessionParser.isCanonicalUserMessage(
                eventType: $0.eventType,
                searchText: $0.searchText
            )
        }
        if hasCanonical {
            steps.removeAll {
                CodexSessionParser.isMirroredConversationEnvelope(
                    outerType: $0.outerType,
                    eventType: $0.eventType,
                    role: $0.role
                )
            }
        } else {
            steps.removeAll {
                $0.eventType == "message" && CodexSessionParser.isInjectedContext($0.summary)
            }
        }
        let canonicalTypes = Set(steps.filter { !$0.isCompletedItem }.map(\.eventType))
        steps.removeAll {
            $0.isCompletedItem
                && CodexSessionParser.conversationItemTypes.contains($0.eventType)
                && canonicalTypes.contains($0.eventType)
        }
        return steps
    }

    private static func lastCompleteRecordOffset(in url: URL, fileSize: UInt64) throws -> UInt64 {
        guard fileSize > 0 else { return 0 }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var cursor = fileSize
        var trailingRecordStart: UInt64 = 0
        while cursor > 0 {
            let start = cursor > 64 * 1024 ? cursor - 64 * 1024 : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(cursor - start)) ?? Data()
            if cursor == fileSize, data.last == 0x0A { return fileSize }
            if let newline = data.lastIndex(of: 0x0A) {
                trailingRecordStart = start + UInt64(newline + 1)
                break
            }
            cursor = start
        }

        let trailingBytes = fileSize - trailingRecordStart
        guard trailingBytes <= UInt64(PayloadStore.maximumPayloadBytes) else {
            return trailingRecordStart
        }
        try handle.seek(toOffset: trailingRecordStart)
        let trailing = try handle.read(upToCount: Int(trailingBytes)) ?? Data()
        guard let object = try? JSONSerialization.jsonObject(with: trailing), object is [String: Any] else {
            return trailingRecordStart
        }
        return fileSize
    }

    private static func contentSignatures(in url: URL, boundary: UInt64) throws -> (leading: String, boundary: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let leadingCount = Int(min(boundary, 4_096))
        try handle.seek(toOffset: 0)
        let leading = try handle.read(upToCount: leadingCount) ?? Data()
        let boundaryStart = boundary > 4_096 ? boundary - 4_096 : 0
        try handle.seek(toOffset: boundaryStart)
        let tail = try handle.read(upToCount: Int(boundary - boundaryStart)) ?? Data()
        return (StableTraceIdentity.payloadDigest(leading), StableTraceIdentity.payloadDigest(tail))
    }
}
