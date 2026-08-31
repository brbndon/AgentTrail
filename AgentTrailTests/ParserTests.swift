import Foundation
import SwiftData
import XCTest
@testable import AgentTrail

final class ParserTests: XCTestCase {
    func testCodexIncrementalCheckpointReadsOnlyGrowthAndDefersTrailingPartialRecord() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("active.jsonl")
        let initial = #"{"type":"event_msg","payload":{"type":"user_message","message":"Sanitized request"}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"agent_message","message":"Initial response"}}"# + "\n"
        try initial.write(to: file, atomically: true, encoding: .utf8)
        let payloadStore = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let checkpointStore = CodexCheckpointStore(rootURL: root.appendingPathComponent("Checkpoints"))
        let parser = CodexSessionParser()

        let first = try await parser.parseIncrementally(fileURL: file, payloadStore: payloadStore, checkpointStore: checkpointStore)
        XCTAssertNil(first.resumedFromOffset)
        XCTAssertEqual(first.bytesRead, UInt64(Data(initial.utf8).count))
        XCTAssertEqual(first.session?.steps.count, 2)

        let unchanged = try await parser.parseIncrementally(fileURL: file, payloadStore: payloadStore, checkpointStore: checkpointStore)
        XCTAssertEqual(unchanged.bytesRead, 0)
        XCTAssertEqual(unchanged.resumedFromOffset, UInt64(Data(initial.utf8).count))
        XCTAssertEqual(unchanged.session?.steps.map(\.identity), first.session?.steps.map(\.identity))

        let completeGrowth = #"{"type":"event_msg","payload":{"type":"agent_message","message":"Appended response"}}"# + "\n"
        try Self.append(Data((completeGrowth + #"{"type":"event_msg","payload":{"type":"agent_"#).utf8), to: file)
        let partial = try await parser.parseIncrementally(fileURL: file, payloadStore: payloadStore, checkpointStore: checkpointStore)
        XCTAssertTrue(partial.hadTrailingPartialRecord)
        XCTAssertEqual(partial.bytesRead, UInt64(Data(completeGrowth.utf8).count))
        XCTAssertEqual(partial.session?.steps.count, 3)

        let completedTail = #"message","message":"Completed later"}}"# + "\n"
        try Self.append(Data(completedTail.utf8), to: file)
        let completed = try await parser.parseIncrementally(fileURL: file, payloadStore: payloadStore, checkpointStore: checkpointStore)
        XCTAssertFalse(completed.hadTrailingPartialRecord)
        XCTAssertEqual(completed.session?.steps.count, 4)
        XCTAssertEqual(Set(completed.session?.steps.map(\.identity) ?? []).count, 4)
    }

    func testCodexIncrementalCheckpointResetsAfterTruncationAndSameInodeRewrite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rewritten.jsonl")
        let original = #"{"type":"message","role":"user","content":"Original request"}"# + "\n"
            + #"{"type":"message","role":"assistant","content":"Original response"}"# + "\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let payloadStore = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let checkpointStore = CodexCheckpointStore(rootURL: root.appendingPathComponent("Checkpoints"))
        let parser = CodexSessionParser()
        _ = try await parser.parseIncrementally(fileURL: file, payloadStore: payloadStore, checkpointStore: checkpointStore)

        let replacement = #"{"type":"message","role":"user","content":"Replacement"}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()

        let truncated = try await parser.parseIncrementally(fileURL: file, payloadStore: payloadStore, checkpointStore: checkpointStore)
        XCTAssertTrue(truncated.checkpointWasReset)
        XCTAssertNil(truncated.resumedFromOffset)
        XCTAssertEqual(truncated.session?.steps.map(\.summary), ["Replacement"])

        let sameSizeRewrite = #"{"type":"message","role":"user","content":"Other value"}"# + "\n"
        XCTAssertEqual(Data(replacement.utf8).count, Data(sameSizeRewrite.utf8).count)
        let rewriteHandle = try FileHandle(forWritingTo: file)
        try rewriteHandle.seek(toOffset: 0)
        try rewriteHandle.write(contentsOf: Data(sameSizeRewrite.utf8))
        try rewriteHandle.close()
        let rewritten = try await parser.parseIncrementally(fileURL: file, payloadStore: payloadStore, checkpointStore: checkpointStore)
        XCTAssertTrue(rewritten.checkpointWasReset)
        XCTAssertEqual(rewritten.session?.steps.map(\.summary), ["Other value"])
    }

    func testCodexIncrementalCheckpointDoesNotAdvanceWhenFileChangesDuringImport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("changing.jsonl")
        let firstLine = #"{"type":"message","role":"user","content":"First"}"# + "\n"
        let secondLine = #"{"type":"message","role":"assistant","content":"Second"}"# + "\n"
        try firstLine.write(to: file, atomically: true, encoding: .utf8)
        let checkpointStore = CodexCheckpointStore(rootURL: root.appendingPathComponent("Checkpoints"))
        let payloadStore = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let changingParser = CodexSessionParser(betweenPasses: {
            try Self.append(Data(secondLine.utf8), to: file)
        })

        await assertThrowsAsync {
            _ = try await changingParser.parseIncrementally(fileURL: file, payloadStore: payloadStore, checkpointStore: checkpointStore)
        }

        let recovered = try await CodexSessionParser().parseIncrementally(
            fileURL: file,
            payloadStore: payloadStore,
            checkpointStore: checkpointStore
        )
        XCTAssertNil(recovered.resumedFromOffset)
        XCTAssertEqual(recovered.session?.steps.count, 2)
    }

    func testApplicationSupportLeaseExcludesConcurrentOwnersAndReleasesCleanly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstResult = ApplicationSupportLease.acquire(in: root)
        guard case .acquired(let firstLease) = firstResult else {
            return XCTFail("Expected the first process lease to be acquired")
        }

        let secondResult = ApplicationSupportLease.acquire(in: root)
        guard case .ownedByAnotherProcess(let owner) = secondResult else {
            return XCTFail("Expected a second owner to be rejected")
        }
        XCTAssertEqual(owner?.processIdentifier, ProcessInfo.processInfo.processIdentifier)

        let lockURL = root.appendingPathComponent(ApplicationSupportLease.lockFileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        firstLease.release()
        guard case .acquired(let replacementLease) = ApplicationSupportLease.acquire(in: root) else {
            return XCTFail("Expected the lease to be available after release")
        }
        replacementLease.release()
    }

    func testApplicationSupportLeaseFailsClosedWhenSupportPathIsAFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportFile = root.appendingPathComponent("AgentTrail")
        try Data("occupied".utf8).write(to: supportFile)

        guard case .unavailable(let message) = ApplicationSupportLease.acquire(in: supportFile) else {
            return XCTFail("Expected an unusable support path to fail closed")
        }
        XCTAssertTrue(message.contains("Application Support"))
    }

    func testCodexParserNormalizesMessagesAndMalformedTrailingLines() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = #"""
        {"timestamp":"2026-01-01T10:00:00Z","type":"session_meta","payload":{"id":"abc","cwd":"/tmp/demo"}}
        {"timestamp":"2026-01-01T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the parser"}]}}
        not-json
        {"timestamp":"2026-01-01T10:00:02Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":{"command":"swift test"}}}
        {"timestamp":"2026-01-01T10:00:03Z","type":"response_item","payload":{"type":"function_call_output","output":"Tests passed","exit_code":0}}
        {"timestamp":"2026-01-01T10:00:04Z","type":"response_item","payload":{"type":"error","error":"failed"}}
        {"timestamp":"2026-01-01T10:00:05Z"}
        {"timestamp":"2026-01-01T10:00:06Z"
        """#
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let session = try require(try await CodexSessionParser().parse(fileURL: file, payloadStore: store))
        XCTAssertEqual(session.agentType, .codex)
        XCTAssertEqual(session.workingDirectory, "/tmp/demo")
        XCTAssertEqual(session.steps.count, 5)
        XCTAssertTrue(session.steps.contains(where: { $0.kind == .shellCommand }))
        XCTAssertTrue(session.steps.contains(where: { $0.kind == .error && $0.hasError }))
        XCTAssertTrue(session.steps.allSatisfy { $0.payloadReference != nil })

        let secondParse = try require(try await CodexSessionParser().parse(fileURL: file, payloadStore: store))
        XCTAssertEqual(session.steps.map(\.identity), secondParse.steps.map(\.identity))
        XCTAssertEqual(session.steps.map(\.payloadReference), secondParse.steps.map(\.payloadReference))
    }

    func testCodexParserUsesCanonicalConversationMetadataAndToolDiagnostics() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = #"""
        {"timestamp":"2026-08-30T10:00:00Z","type":"session_meta","payload":{"timestamp":"2026-08-30T10:00:00Z","cwd":"/Users/example/Code/AgentTrail"}}
        {"timestamp":"2026-08-30T10:00:01Z","type":"response_item","payload":{"type":"message","role":"developer","content":"Internal instructions"}}
        {"timestamp":"2026-08-30T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":"# AGENTS.md instructions"}}
        {"timestamp":"2026-08-30T10:00:03Z","type":"event_msg","payload":{"type":"user_message","message":"Fix the current app"}}
        {"timestamp":"2026-08-30T10:00:04Z","type":"response_item","payload":{"type":"function_call","name":"functions.exec","call_id":"call-1","arguments":"{\"cmd\":\"swift test\"}"}}
        {"timestamp":"2026-08-30T10:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"Tests passed","exit_code":0}}
        {"timestamp":"2026-08-30T10:00:06Z","type":"turn_context","payload":{"cwd":"/tmp/wrong","summary":"internal context"}}
        {"timestamp":"2026-08-30T10:00:07Z","type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"I found the root cause"}}
        """#
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let session = try require(try await CodexSessionParser().parse(
            fileURL: file,
            payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        ))

        XCTAssertEqual(session.title, "Fix the current app")
        XCTAssertEqual(session.workingDirectory, "/Users/example/Code/AgentTrail")
        XCTAssertEqual(session.projectName, "AgentTrail")
        XCTAssertEqual(session.steps.count, 4)
        XCTAssertEqual(session.steps.map(\.kind), [.user, .shellCommand, .toolResult, .assistant])
        XCTAssertEqual(session.steps.map(\.title), ["User request", "Run exec", "exec result", "Agent update"])
        XCTAssertEqual(session.steps[1].commandText, "swift test")
        XCTAssertFalse(session.steps.contains { $0.summary.contains("Internal instructions") })
        XCTAssertFalse(session.steps.contains { $0.summary.contains("AGENTS.md") })
    }

    func testCodexParserKeepsFallbackUserMessageWhenOnlyCanonicalAgentMessagesExist() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = #"""
        {"timestamp":"2026-08-24T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/example/Code/Legacy"}}
        {"timestamp":"2026-08-24T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions <INSTRUCTIONS>internal</INSTRUCTIONS>"}]}}
        {"timestamp":"2026-08-24T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Repair the legacy parser"}]}}
        {"timestamp":"2026-08-24T10:00:03Z","type":"response_item","payload":{"type":"agent_message","content":[{"type":"output_text","text":"I will inspect it"}]}}
        """#
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let session = try require(try await CodexSessionParser().parse(
            fileURL: file,
            payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        ))

        XCTAssertEqual(session.title, "Repair the legacy parser")
        XCTAssertEqual(session.steps.map(\.kind), [.user, .assistant])
        XCTAssertFalse(session.steps.contains { $0.summary.contains("AGENTS.md") })
    }

    func testCursorParserHandlesStatusTimestampsAndTokenCounts() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("Users-brandon-Code-Demo/agent-transcripts/session", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let file = root.appendingPathComponent("session.jsonl")
        let jsonl = #"""
        {"id":"user-1","timestamp":"2026-01-01T10:00:02Z","role":"user","message":{"content":[{"type":"text","text":"Inspect this"}]}}
        {"id":"tool-1","timestamp":"2026-01-01T10:00:03Z","role":"assistant","message":{"content":[{"type":"tool-call","name":"read","input":{"path":"Sources/App.swift"}}]},"usage":{"input_tokens":2,"output_tokens":3}}
        {"type":"status","status":"completed","timestamp":"2026-01-01T10:00:04Z","error":null}
        """#
        try jsonl.write(to: file, atomically: true, encoding: .utf8)
        let session = try require(try await CursorSessionParser().parse(fileURL: file, payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs"))))
        XCTAssertEqual(session.steps.count, 2)
        XCTAssertEqual(session.steps.first?.kind, .user)
        XCTAssertEqual(session.steps.last?.kind, .toolCall)
        XCTAssertEqual(session.steps.last?.tokenCount, 5)
        XCTAssertEqual(session.status, .historical)
    }

    func testGrokParserSortsBoundedMetadataWithoutChangingIdentity() async throws {
        let root = try makeTemporaryDirectory()
        let sessionDirectory = root.appendingPathComponent("%2FUsers%2Fbrandon%2FCode%2FDemo/session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = #"""
        {"id":"server","type":"server_connected","ts":"2026-01-01T10:00:00Z"}
        {"id":"assistant","type":"assistant_message","ts":"2026-01-01T10:00:02Z","role":"assistant","content":"I will inspect the build","usage":{"total_tokens":7}}
        """#
        try events.write(to: sessionDirectory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        try #"{"id":"user","ts":"2026-01-01T10:00:01Z","role":"user","content":"Build the project","files":[{"path":"Sources/App.swift","change_type":"modified","diff":"@@"}]}"#.write(to: sessionDirectory.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let session = try require(try await GrokBuildSessionParser().parse(directory: sessionDirectory, payloadStore: store))
        XCTAssertEqual(session.steps.count, 3)
        XCTAssertEqual(session.steps.first?.kind, .system)
        XCTAssertEqual(session.steps.dropFirst().first?.kind, .user)
        XCTAssertEqual(session.steps.last?.kind, .assistant)
        XCTAssertEqual(session.steps[1].fileChanges.first?.path, "Sources/App.swift")
        XCTAssertEqual(session.steps.last?.tokenCount, 7)
        XCTAssertEqual(session.workingDirectory, "/Users/brandon/Code/Demo")
    }

    func testIdentitySurvivesInsertionDeletionReorderingButNotRewriteOrMove() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let first = #"{"id":"a","type":"message","role":"assistant","content":"A"}"#
        let second = #"{"id":"b","type":"message","role":"assistant","content":"B"}"#
        try (first + "\n" + second).write(to: file, atomically: true, encoding: .utf8)
        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let initial = try require(try await CodexSessionParser().parse(fileURL: file, payloadStore: store))
        let initialIDs = Dictionary(uniqueKeysWithValues: initial.steps.map { ($0.summary, $0.identity) })

        let inserted = #"{"id":"x","type":"message","role":"assistant","content":"Inserted"}"#
        try (second + "\n" + inserted + "\n" + first).write(to: file, atomically: true, encoding: .utf8)
        let changed = try require(try await CodexSessionParser().parse(fileURL: file, payloadStore: store))
        XCTAssertEqual(changed.steps.first(where: { $0.summary == "A" })?.identity, initialIDs["A"])
        XCTAssertEqual(changed.steps.first(where: { $0.summary == "B" })?.identity, initialIDs["B"])
        XCTAssertNotEqual(changed.steps.first(where: { $0.summary == "Inserted" })?.identity, initialIDs["A"])

        try #"{"id":"a","type":"message","role":"assistant","content":"A rewritten"}"#.write(to: file, atomically: true, encoding: .utf8)
        let rewritten = try require(try await CodexSessionParser().parse(fileURL: file, payloadStore: store))
        XCTAssertNotEqual(rewritten.steps.first?.identity, initialIDs["A"])
        let moved = root.appendingPathComponent("moved.jsonl")
        try FileManager.default.moveItem(at: file, to: moved)
        let movedSession = try require(try await CodexSessionParser().parse(fileURL: moved, payloadStore: store))
        XCTAssertNotEqual(movedSession.sourceKey, initial.sourceKey)
    }

    func testDuplicateRecordsGetStableDistinctIdentities() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let duplicate = #"{"type":"message","role":"assistant","content":"same"}"#
        try (duplicate + "\n" + duplicate).write(to: file, atomically: true, encoding: .utf8)
        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let first = try require(try await CodexSessionParser().parse(fileURL: file, payloadStore: store))
        let second = try require(try await CodexSessionParser().parse(fileURL: file, payloadStore: store))
        XCTAssertEqual(Set(first.steps.map(\.identity)).count, 2)
        XCTAssertEqual(first.steps.map(\.identity), second.steps.map(\.identity))
        XCTAssertTrue(first.steps.allSatisfy { $0.identity.hasPrefix("dup:") })
    }

    func testLongExplicitIDsPreserveDistinctDigests() {
        let longID = String(repeating: "a", count: 600)
        let first = Data(#"{"id":"\#(longID)","content":"one"}"#.utf8)
        let second = Data(#"{"id":"\#(longID)","content":"two"}"#.utf8)
        let record: [String: Any] = ["id": longID]
        let identityA = StableTraceIdentity.baseIdentity(record: record, rawPayload: first)
        let identityB = StableTraceIdentity.baseIdentity(record: record, rawPayload: second)
        XCTAssertNotEqual(identityA, identityB)
        XCTAssertLessThanOrEqual(identityA.count, TraceLimits.identity)
        XCTAssertTrue(identityA.hasPrefix("event:"))
    }

    func testErrorFalseIsNotTreatedAsError() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try #"{"type":"message","role":"assistant","content":"ok","error":false}"#.write(to: file, atomically: true, encoding: .utf8)
        let session = try require(try await CodexSessionParser().parse(fileURL: file, payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs"))))
        XCTAssertEqual(session.steps.count, 1)
        XCTAssertFalse(session.steps[0].hasError)
        XCTAssertNotEqual(session.steps[0].kind, .error)
    }

    func testMalformedOnlySourceFailsInsteadOfHealthyEmpty() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try "not-json\n{]\n".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try await CodexSessionParser().parse(fileURL: file, payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs")))
            XCTFail("Expected malformed-only failure")
        } catch TraceParserError.malformedOnly {
            // expected
        }
    }

    func testLegacyPayloadRemainsReadableAfterNewWrite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeRoot = root.appendingPathComponent("Blobs")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        let legacyKey = UUID().uuidString.lowercased()
        let legacyURL = storeRoot.appendingPathComponent("\(legacyKey).json")
        let legacyData = Data(#"{"legacy":true}"#.utf8)
        try legacyData.write(to: legacyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyURL.path)

        let store = PayloadStore(rootURL: storeRoot)
        _ = try await store.write(Data(#"{"new":true}"#.utf8))
        let legacy = try await store.read(key: legacyKey)
        XCTAssertEqual(legacy.data, legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent(".format-v2").path))
    }

    func testPayloadGCCollectsHiddenTemporaryFiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PayloadStore(rootURL: root)
        let key = try await store.write(Data(#"{"keep":true}"#.utf8))
        let temp = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        try Data("stale".utf8).write(to: temp)
        let old = Date.now.addingTimeInterval(-200_000)
        try FileManager.default.setAttributes([.modificationDate: old, .posixPermissions: 0o600], ofItemAtPath: temp.path)
        try await store.removeUnreferenced(keeping: [key], olderThan: 86_400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        _ = try await store.read(key: key)
    }

    func testJSONLineSupportPropagatesCallbackErrors() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        try #"{"ok":true}"#.write(to: file, atomically: true, encoding: .utf8)
        enum Expected: Error { case callback }
        do {
            _ = try await JSONLineSupport.forEachDictionary(at: file) { _, _, _ in throw Expected.callback }
            XCTFail("Expected callback error")
        } catch Expected.callback {
            // expected
        }
    }

    func testPayloadStoreBoundsIntegrityImmutabilityAndPermissions() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PayloadStore(rootURL: root)
        let key = try await store.write(Data(#"{"payload":"value"}"#.utf8))
        let result = try await store.read(key: key, maximumBytes: Int.max)
        XCTAssertEqual(result.data, Data(#"{"payload":"value"}"#.utf8))
        XCTAssertFalse(result.isTruncated)
        await assertThrowsAsync { _ = try await store.write(Data(#"{"payload":"changed"}"#.utf8), key: key) }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("\(key).json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try Data("corrupt".utf8).write(to: root.appendingPathComponent("\(key).json"), options: .atomic)
        await assertThrowsAsync { _ = try await store.read(key: key) }
        await assertThrowsAsync { _ = try await store.read(key: "../../outside") }
    }

    func testPayloadStoreRejectsSymlinkRootAndFile() async throws {
        let root = try makeTemporaryDirectory()
        let target = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let rootLink = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: target)
        await assertThrowsAsync { _ = try await PayloadStore(rootURL: rootLink).write(Data(#"{"ok":true}"#.utf8)) }

        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let key = try await store.write(Data(#"{"ok":true}"#.utf8))
        let payload = root.appendingPathComponent("Blobs/\(key).json")
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: target.appendingPathComponent("outside.json"))
        await assertThrowsAsync { _ = try await store.read(key: key) }
    }

    @MainActor
    func testBranchCopiesImmutableLineageAndFileChanges() async throws {
        let container = try makeContainer(inMemory: true)
        let context = ModelContext(container)
        let project = ProjectRecord(identity: "preview", path: "/tmp/preview", name: "Preview")
        let session = SessionRecord(sourceKey: "codex:preview", agentType: .codex, title: "Original trace", startDate: .now.addingTimeInterval(-100), endDate: .now, workingDirectory: "/tmp/preview", sourcePath: "/tmp/preview/session.jsonl", sourceModifiedAt: .now, project: project)
        let steps = (0..<3).map { index in
            StepRecord(stepIndex: index, kind: index == 0 ? .user : .assistant, timestamp: .now.addingTimeInterval(TimeInterval(index)), title: "Step \(index)", contentSummary: "Summary \(index)", searchText: "Summary \(index)", fullPayloadRef: StableTraceIdentity.payloadKey(for: "payload-\(index)"), hasError: false, traceIdentity: "event:\(index)", session: session)
        }
        let fileChange = FileChangeRecord(path: "Sources/App.swift", changeType: "modified", diffStorageKey: steps[1].fullPayloadRef, step: steps[1])
        session.steps = steps
        steps[1].fileChanges = [fileChange]
        context.insert(project)
        context.insert(session)
        steps.forEach(context.insert)
        context.insert(fileChange)
        try context.save()

        let appStore = AppStore(modelContext: context)
        let branch = try await appStore.createBranch(from: steps[1], named: "Known good state")
        XCTAssertEqual(branch.parentSessionID, session.id)
        XCTAssertEqual(branch.forkStepID, steps[1].id)
        XCTAssertEqual(branch.steps.count, 2)
        let orderedBranchSteps = branch.steps.sorted { $0.stepIndex < $1.stepIndex }
        XCTAssertEqual(orderedBranchSteps[1].fileChanges.first?.diffStorageKey, steps[1].fileChanges.first?.diffStorageKey)

        let firstBranchStep = try XCTUnwrap(branch.steps.min { $0.stepIndex < $1.stepIndex })
        let grandchild = try await appStore.createBranch(from: firstBranchStep, named: "Nested branch")
        XCTAssertEqual(grandchild.parentSessionID, branch.id)
        XCTAssertEqual(grandchild.forkStepID, firstBranchStep.id)
        XCTAssertEqual(grandchild.steps.first?.parentStepID, firstBranchStep.id)
    }

    @MainActor
    func testRefreshPreservesSafeStepIdentityAndNeverReplacesBranches() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AgentDirectories(homeDirectory: root)
        for directory in directories.defaultWatchPaths { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let file = directories.codexSessions.appendingPathComponent("session.jsonl")
        let initial = #"""
        {"type":"message","role":"user","content":"First"}
        {"type":"message","role":"assistant","content":"Second"}
        """#
        try initial.write(to: file, atomically: true, encoding: .utf8)
        let context = ModelContext(try makeContainer(inMemory: true))
        let appStore = AppStore(modelContext: context, agentDirectories: directories, payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs")))
        appStore.refresh()
        try await waitForRefresh(appStore)
        let firstSession = try XCTUnwrap(try context.fetch(FetchDescriptor<SessionRecord>()).first { !$0.isBranch })
        let firstIDs = Dictionary(uniqueKeysWithValues: firstSession.steps.map { ($0.contentSummary, ($0.id, $0.traceIdentity)) })

        try ("{" + "\"type\":\"message\",\"role\":\"assistant\",\"content\":\"Second\"}" + "\n" + "{" + "\"type\":\"message\",\"role\":\"user\",\"content\":\"Inserted\"}" + "\n" + "{" + "\"type\":\"message\",\"role\":\"user\",\"content\":\"First\"}").write(to: file, atomically: true, encoding: .utf8)
        appStore.refresh()
        try await waitForRefresh(appStore)
        let secondSession = try XCTUnwrap(try context.fetch(FetchDescriptor<SessionRecord>()).first { !$0.isBranch })
        XCTAssertEqual(secondSession.steps.first(where: { $0.contentSummary == "First" })?.id, firstIDs["First"]?.0)
        XCTAssertEqual(secondSession.steps.first(where: { $0.contentSummary == "Second" })?.id, firstIDs["Second"]?.0)
        let branch = try await appStore.createBranch(from: try XCTUnwrap(secondSession.steps.first), named: "Immutable")
        let branchID = branch.id
        appStore.refresh()
        try await waitForRefresh(appStore)
        XCTAssertNotNil(try context.fetch(FetchDescriptor<SessionRecord>()).first { $0.id == branchID })
        XCTAssertEqual(try context.fetch(FetchDescriptor<SessionRecord>()).filter(\.isBranch).count, 1)
        appStore.stopWatching()
    }

    @MainActor
    func testRefreshMarksDisappearedSourcesUnavailableWithoutDeletingBranches() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AgentDirectories(homeDirectory: root)
        for directory in directories.defaultWatchPaths { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let file = directories.codexSessions.appendingPathComponent("session.jsonl")
        try #"{"type":"message","role":"user","content":"Keep this history"}"#.write(to: file, atomically: true, encoding: .utf8)
        let context = ModelContext(try makeContainer(inMemory: true))
        let appStore = AppStore(modelContext: context, agentDirectories: directories, payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs")))
        appStore.refresh()
        try await waitForRefresh(appStore)
        let sourceSession = try XCTUnwrap(try context.fetch(FetchDescriptor<SessionRecord>()).first { !$0.isBranch })
        let branch = try await appStore.createBranch(from: try XCTUnwrap(sourceSession.steps.first), named: "History")

        try FileManager.default.removeItem(at: directories.codexSessions)
        appStore.refresh()
        try await waitForRefresh(appStore)
        let sessions = try context.fetch(FetchDescriptor<SessionRecord>())
        let unavailable = try XCTUnwrap(sessions.first { $0.id == sourceSession.id })
        XCTAssertEqual(unavailable.sourceState, .unavailable)
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertNotNil(sessions.first { $0.id == branch.id })
        appStore.stopWatching()
    }

    @MainActor
    func testDiskModelContainerUsesVersionedSchemaAndPersistsLineageFields() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ModelConfiguration(url: root.appendingPathComponent("AgentTrail.store"))
        let container = try ModelContainer(for: Schema(versionedSchema: AgentTrailSchemaV2.self), migrationPlan: AgentTrailMigrationPlan.self, configurations: configuration)
        let context = ModelContext(container)
        let parent = SessionRecord(sourceKey: "branch:test", agentType: .codex, title: "Branch", startDate: .now, endDate: nil, workingDirectory: "", sourcePath: "", sourceModifiedAt: .now)
        parent.forkStepID = UUID()
        context.insert(parent)
        try context.save()
        let reopened = try ModelContext(ModelContainer(for: Schema(versionedSchema: AgentTrailSchemaV2.self), migrationPlan: AgentTrailMigrationPlan.self, configurations: configuration))
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<SessionRecord>()).first?.forkStepID, parent.forkStepID)
    }

    func testTimestampHelpersAcceptISO8601SecondsAndMilliseconds() {
        let expected = Date(timeIntervalSince1970: 1_700_000_000.125)
        for value: Any in ["2023-11-14T22:13:20.125Z", "2023-11-14T22:13:20Z", 1_700_000_000.125, 1_700_000_000_125] {
            let parsed = JSONLineSupport.date(value)
            XCTAssertNotNil(parsed)
            XCTAssertLessThan(abs((parsed ?? .distantPast).timeIntervalSince(expected)), 1.0)
        }
    }

    func testTimelineFilterMatchesSearchPathKindAndErrors() {
        let step = StepRecord(stepIndex: 2, kind: .shellCommand, timestamp: .now, title: "Run the focused tests", contentSummary: "swift test --filter ParserTests", searchText: "run focused tests swift test filter ParserTests", fullPayloadRef: nil, hasError: true, commandText: "swift test --filter ParserTests", filePath: "Tests/ParserTests.swift", exitCode: 1)
        var filter = TimelineFilter(query: "focused tests", kindRawValue: StepKind.shellCommand.rawValue, errorsOnly: true, filePathQuery: "ParserTests")
        XCTAssertTrue(filter.matches(step))
        filter.filePathQuery = "Missing.swift"
        XCTAssertFalse(filter.matches(step))
    }

    @MainActor
    func testDeletingStepCascadesToFileChanges() throws {
        let context = ModelContext(try makeContainer(inMemory: true))
        let step = StepRecord(stepIndex: 0, kind: .fileChange, timestamp: .now, title: "Updated file", contentSummary: "Updated Sources/App.swift", searchText: "Updated Sources/App.swift", fullPayloadRef: nil, hasError: false)
        let fileChange = FileChangeRecord(path: "Sources/App.swift", changeType: "modified", step: step)
        context.insert(step)
        context.insert(fileChange)
        try context.save()
        context.delete(step)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FileChangeRecord>()), 0)
    }

    @MainActor
    func testFSEventWatcherIgnoresCallbacksAfterStop() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expectation = XCTestExpectation(description: "FSEvents callback")
        let watcher = FSEventWatcher(paths: [root]) { expectation.fulfill() }
        XCTAssertTrue(watcher.start())
        try Data(#"{"event":true}"#.utf8).write(to: root.appendingPathComponent("session.jsonl"))
        await fulfillment(of: [expectation], timeout: 5)
        watcher.stop()
        watcher.update(paths: [root])
        watcher.stop()
    }

    // MARK: - C1 / H6 migration

    func testLightweightMigrationFromV1RetainsRows() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent(AgentTrailPersistence.storeFileName)

        do {
            let v1Container = try ModelContainer(
                for: Schema(versionedSchema: AgentTrailSchemaV1.self),
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(v1Container)
            let project = AgentTrailSchemaV1.ProjectRecord(
                identity: "path:/tmp/migrate",
                path: "/tmp/migrate",
                name: "Migrate"
            )
            let session = AgentTrailSchemaV1.SessionRecord(
                sourceKey: "codex:/tmp/migrate/session.jsonl",
                agentTypeRawValue: AgentType.codex.rawValue,
                title: "V1 session",
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                endDate: Date(timeIntervalSince1970: 1_700_000_100),
                workingDirectory: "/tmp/migrate",
                sourcePath: "/tmp/migrate/session.jsonl",
                sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                statusRawValue: SessionStatus.historical.rawValue
            )
            session.project = project
            let step = AgentTrailSchemaV1.StepRecord(
                stepIndex: 0,
                kindRawValue: StepKind.user.rawValue,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                title: "Hello",
                contentSummary: "Hello from V1",
                searchText: "Hello from V1",
                fullPayloadRef: nil,
                hasError: false
            )
            step.session = session
            let change = AgentTrailSchemaV1.FileChangeRecord(
                path: "Sources/App.swift",
                changeTypeRawValue: "modified"
            )
            change.step = step
            context.insert(project)
            context.insert(session)
            context.insert(step)
            context.insert(change)
            project.sessions = [session]
            session.steps = [step]
            step.fileChanges = [change]
            try context.save()
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentTrailSchemaV1.SessionRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentTrailSchemaV1.StepRecord>()), 1)
        }

        let v2Container = try ModelContainer(
            for: Schema(versionedSchema: AgentTrailSchemaV2.self),
            migrationPlan: AgentTrailMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let migrated = ModelContext(v2Container)
        let sessions = try migrated.fetch(FetchDescriptor<SessionRecord>())
        let steps = try migrated.fetch(FetchDescriptor<StepRecord>())
        let projects = try migrated.fetch(FetchDescriptor<ProjectRecord>())
        let changes = try migrated.fetch(FetchDescriptor<FileChangeRecord>())
        XCTAssertEqual(projects.count, 1, "V1 projects must survive lightweight migration")
        XCTAssertEqual(sessions.count, 1, "V1 sessions must survive lightweight migration (entity rename would zero this)")
        XCTAssertEqual(steps.count, 1, "V1 steps must survive lightweight migration")
        XCTAssertEqual(changes.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.title, "V1 session")
        XCTAssertEqual(session.sourceState, .scanned)
        XCTAssertNil(session.parentSessionID)
        XCTAssertNil(session.forkStepID)
        let step = try XCTUnwrap(steps.first)
        XCTAssertEqual(step.contentSummary, "Hello from V1")
        XCTAssertNil(step.traceIdentity)
        XCTAssertNil(step.parentStepID)
    }

    func testUnversionedRecordStoreOpensUnderV2() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent(AgentTrailPersistence.storeFileName)

        do {
            let container = try ModelContainer(
                for: ProjectRecord.self, SessionRecord.self, StepRecord.self, FileChangeRecord.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(container)
            context.insert(SessionRecord(
                sourceKey: "codex:unversioned",
                agentType: .codex,
                title: "Unversioned",
                startDate: .now,
                endDate: nil,
                workingDirectory: "/tmp",
                sourcePath: "/tmp/s.jsonl",
                sourceModifiedAt: .now
            ))
            try context.save()
        }

        let reopened = try ModelContainer(
            for: Schema(versionedSchema: AgentTrailSchemaV2.self),
            migrationPlan: AgentTrailMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        XCTAssertEqual(try ModelContext(reopened).fetchCount(FetchDescriptor<SessionRecord>()), 1)
    }

    // MARK: - H1 / H2 / H6 backup

    func testPreOpenBackupFailureDoesNotOpenExistingStore() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent(AgentTrailPersistence.storeFileName)
        try Data("not-a-real-store".utf8).write(to: storeURL)

        // Make Backups a file so createDirectory(Backups) fails.
        let backupsAsFile = root.appendingPathComponent("Backups")
        try Data().write(to: backupsAsFile)

        let result = AgentTrailPersistence.openDiskStore(supportDirectory: root)
        XCTAssertEqual(result.mode, .emergencyInMemory)
        XCTAssertNotNil(result.startupMessage)
        XCTAssertTrue(result.startupMessage?.contains("back up") == true)
        // Original store must remain untouched (not opened/migrated/replaced).
        let original = try Data(contentsOf: storeURL)
        XCTAssertEqual(original, Data("not-a-real-store".utf8))
    }

    func testBackupRetentionCapAndRestoreRejectsIncomplete() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent(AgentTrailPersistence.storeFileName)
        try Data("store-v1".utf8).write(to: storeURL)

        for index in 0..<7 {
            try AgentTrailPersistence.backupStore(at: storeURL, supportDirectory: root, label: "cap-\(index)")
            // Distinct mtimes so prune ordering is stable.
            try awaitTaskSleep(milliseconds: 15)
        }
        let backupsURL = root.appendingPathComponent("Backups", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix(AgentTrailPersistence.storeFileName + ".") }
        XCTAssertLessThanOrEqual(backups.count, AgentTrailPersistence.maximumBackups)

        let incomplete = backupsURL.appendingPathComponent("\(AgentTrailPersistence.storeFileName).incomplete.1", isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("wal-only".utf8).write(to: incomplete.appendingPathComponent("\(AgentTrailPersistence.storeFileName).wal"))
        // Point restore at only incomplete by clearing complete backups.
        for backup in backups {
            try FileManager.default.removeItem(at: backup)
        }
        XCTAssertThrowsError(try AgentTrailPersistence.restoreLatestBackup(to: storeURL, supportDirectory: root))
    }

    func testBackupThenRestoreOpensMigratedContainer() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent(AgentTrailPersistence.storeFileName)

        try autoreleasepool {
            let container = try AgentTrailPersistence.makeDiskContainer(at: storeURL)
            let context = ModelContext(container)
            context.insert(SessionRecord(
                sourceKey: "codex:backup-restore",
                agentType: .codex,
                title: "Backup me",
                startDate: .now,
                endDate: nil,
                workingDirectory: "/tmp",
                sourcePath: "/tmp/b.jsonl",
                sourceModifiedAt: .now
            ))
            try context.save()
        }

        try AgentTrailPersistence.backupStore(at: storeURL, supportDirectory: root, label: "fixture")
        try FileManager.default.removeItem(at: storeURL)
        for ext in ["wal", "shm"] {
            let side = storeURL.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: side.path) {
                try FileManager.default.removeItem(at: side)
            }
        }
        try AgentTrailPersistence.restoreLatestBackup(to: storeURL, supportDirectory: root)
        let restored = try AgentTrailPersistence.makeDiskContainer(at: storeURL)
        XCTAssertEqual(try ModelContext(restored).fetchCount(FetchDescriptor<SessionRecord>()), 1)
    }

    // MARK: - H3 / M2 / M4 parsers

    func testCodexThrowsSourceChangedWhenMutatedBetweenPasses() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let original = #"{"type":"message","role":"user","content":"stable"}"# + "\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        var parser = CodexSessionParser()
        parser.betweenPasses = {
            try (#"{"type":"message","role":"user","content":"mutated"}"# + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
        }
        do {
            _ = try await parser.parse(fileURL: file, payloadStore: store)
            XCTFail("Expected sourceChanged")
        } catch TraceParserError.sourceChanged {
            // expected
        }
    }

    func testCursorThrowsSourceChangedWhenFilteredLineBecomesEvent() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("Users-brandon-Code-Demo/agent-transcripts/session", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let file = root.appendingPathComponent("session.jsonl")
        let original = #"""
        {"id":"user-1","timestamp":"2026-01-01T10:00:02Z","role":"user","message":{"content":[{"type":"text","text":"Inspect this"}]}}
        {"type":"status","status":"completed","timestamp":"2026-01-01T10:00:04Z","error":null}
        """#
        try original.write(to: file, atomically: true, encoding: .utf8)
        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        var parser = CursorSessionParser()
        parser.betweenPasses = {
            let mutated = #"""
            {"id":"user-1","timestamp":"2026-01-01T10:00:02Z","role":"user","message":{"content":[{"type":"text","text":"Inspect this"}]}}
            {"id":"sneak","timestamp":"2026-01-01T10:00:04Z","role":"assistant","message":{"content":[{"type":"text","text":"I snuck in"}]}}
            """#
            try mutated.write(to: file, atomically: true, encoding: .utf8)
        }
        do {
            _ = try await parser.parse(fileURL: file, payloadStore: store)
            XCTFail("Expected sourceChanged when a filtered status line becomes an event")
        } catch TraceParserError.sourceChanged {
            // expected
        }
    }

    func testDiscoverAndParseReportsProgressForEachAgentPhase() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AgentDirectories(homeDirectory: root)
        for directory in directories.defaultWatchPaths {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try #"{"type":"message","role":"user","content":"Hello"}"#
            .write(to: directories.codexSessions.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let service = IngestionService(directories: directories, payloadStore: store)
        let collector = ProgressCollector()
        let report = try await service.discoverAndParse { progress in
            await collector.record(progress)
        }
        let phases = await collector.phases
        let sawCodexParse = await collector.sawCodexParse
        XCTAssertFalse(phases.isEmpty)
        XCTAssertTrue(phases.contains(.scanning))
        XCTAssertTrue(phases.contains(.parsing))
        XCTAssertTrue(sawCodexParse)
        XCTAssertEqual(report.sessions.count, 1)
        let sample = IngestionProgress(
            phase: .parsing,
            agentType: .codex,
            processed: 2,
            total: 10,
            sessionsImported: 1,
            sessionsSkipped: 0,
            failures: 0,
            currentName: "session.jsonl"
        )
        XCTAssertTrue(sample.userFacingMessage.contains("2 of 10"))
        XCTAssertEqual(try XCTUnwrap(sample.fractionCompleted), 0.2, accuracy: 0.001)
    }

    func testCodexDiscoveryLoadsNewestThirtyAndReportsOlderPages() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AgentDirectories(homeDirectory: root)
        try FileManager.default.createDirectory(at: directories.codexSessions, withIntermediateDirectories: true)
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<35 {
            let file = directories.codexSessions.appendingPathComponent("session-\(index).jsonl")
            try #"{"type":"message","role":"user","content":"Thread \#(index)"}"#
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: file.path
            )
        }

        let service = IngestionService(
            directories: directories,
            payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        )
        let firstPage = try await service.discoverAndParse(codexSessionLimit: 30)

        XCTAssertEqual(firstPage.sessions.count, 30)
        XCTAssertEqual(firstPage.totalDiscoveredSessionCount, 35)
        XCTAssertTrue(firstPage.hasMoreSessions)
        XCTAssertEqual(firstPage.sessions.first?.title, "Thread 34")
        XCTAssertEqual(firstPage.sessions.last?.title, "Thread 5")
    }

    @MainActor
    func testAppStoreLoadsNextCodexPageOnDemand() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AgentDirectories(homeDirectory: root)
        for directory in directories.defaultWatchPaths {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<35 {
            let file = directories.codexSessions.appendingPathComponent("session-\(index).jsonl")
            try #"{"type":"message","role":"user","content":"Thread \#(index)"}"#
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: baseDate.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: file.path
            )
        }

        let context = ModelContext(try makeContainer(inMemory: true))
        let appStore = AppStore(
            modelContext: context,
            agentDirectories: directories,
            payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        )
        appStore.refresh()
        try await waitForRefresh(appStore)
        XCTAssertEqual(appStore.loadedSessionLimit, 30)
        XCTAssertEqual(appStore.totalAvailableSessionCount, 35)
        XCTAssertTrue(appStore.hasMoreSessions)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 30)

        appStore.loadMoreSessions()
        try await waitForRefresh(appStore)
        XCTAssertEqual(appStore.loadedSessionLimit, 35)
        XCTAssertFalse(appStore.hasMoreSessions)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 35)
        appStore.stopWatching()
    }

    func testUnchangedSourcesAreSkippedOnSecondImport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AgentDirectories(homeDirectory: root)
        for directory in directories.defaultWatchPaths {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let file = directories.codexSessions.appendingPathComponent("session.jsonl")
        try #"{"type":"message","role":"user","content":"Hello"}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        let service = IngestionService(directories: directories, payloadStore: store)
        let first = try await service.discoverAndParse()
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.skippedUnchangedCount, 0)
        let key = try XCTUnwrap(first.sessions.first?.sourceKey)
        let modified = try XCTUnwrap(first.sessions.first?.sourceModifiedAt)
        let second = try await service.discoverAndParse(knownSourceModifiedAt: [key: modified])
        XCTAssertEqual(second.sessions.count, 0)
        XCTAssertEqual(second.skippedUnchangedCount, 1)
        XCTAssertEqual(second.sources.first(where: { $0.agentType == .codex })?.discoveredSourcePaths.count, 1)
    }

    func testSignedExitCodesArePreserved() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try #"{"type":"response_item","payload":{"type":"function_call_output","output":"killed","exit_code":-15}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let session = try require(try await CodexSessionParser().parse(
            fileURL: file,
            payloadStore: PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        ))
        XCTAssertEqual(session.steps.first?.exitCode, -15)
        XCTAssertEqual(JSONLineSupport.integer(-3), -3)
        XCTAssertEqual(JSONLineSupport.nonNegativeInteger(-3), 0)
        XCTAssertEqual(JSONLineSupport.firstInteger(in: ["exit_code": -9] as [String: Any], keys: ["exit_code"]), -9)
    }

    @MainActor
    func testRecoveredFromBackupSetsStickyPersistenceWarning() {
        let store = AppStore(
            startupMessage: "AgentTrail recovered its local store from the latest backup.",
            persistenceWarning: "AgentTrail recovered its local store from the latest backup."
        )
        XCTAssertEqual(store.persistenceWarning, "AgentTrail recovered its local store from the latest backup.")
        store.statusMessage = "Discovering local sessions…"
        XCTAssertEqual(store.persistenceWarning, "AgentTrail recovered its local store from the latest backup.")
    }

    @MainActor
    private func waitForRefresh(_ appStore: AppStore) async throws {
        for _ in 0..<200 {
            if !appStore.isLoading { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for refresh")
    }

    private func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let configuration = inMemory ? ModelConfiguration(isStoredInMemoryOnly: true) : ModelConfiguration()
        return try ModelContainer(for: Schema(versionedSchema: AgentTrailSchemaV2.self), migrationPlan: AgentTrailMigrationPlan.self, configurations: configuration)
    }

    private func require(_ session: ParsedSession?) throws -> ParsedSession {
        try XCTUnwrap(session)
    }

    private func assertThrowsAsync(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected an error")
        } catch {
            // expected
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentTrailTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func awaitTaskSleep(milliseconds: UInt64) throws {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds))) {
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

private actor ProgressCollector {
    private(set) var phases: [IngestionProgress.Phase] = []
    private(set) var sawCodexParse = false

    func record(_ progress: IngestionProgress) {
        phases.append(progress.phase)
        if progress.agentType == .codex, progress.phase == .parsing, progress.total >= 1 {
            sawCodexParse = true
        }
    }
}
