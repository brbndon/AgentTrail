@testable import AgentTrail
import Foundation
import XCTest

final class FileChangeDiffTests: XCTestCase {
    func testStoredCodexFixturesContainRenderablePerFileDiffs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentTrail-DiffTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PayloadStore(rootURL: root.appendingPathComponent("Blobs"))
        for (name, path) in [("direct-diagnostics", "Sources/Sample.swift"), ("item-completed", "Sources/Item.swift")] {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Codex/\(name).jsonl")
            let copy = root.appendingPathComponent("\(name).jsonl")
            try FileManager.default.copyItem(at: fixture, to: copy)
            let parsed = try await CodexSessionParser().parse(fileURL: copy, payloadStore: store)
            let session = try XCTUnwrap(parsed)
            let step = try XCTUnwrap(session.steps.first { $0.kind == .fileChange })
            XCTAssertTrue(step.fileChanges.first { $0.path == path }?.hasDiff == true)
            let preview = await FileChangeDiffPreview.load(key: step.payloadReference, path: path, store: store)
            guard case .available(let diff) = preview else { return XCTFail("Expected fixture diff: \(preview)") }
            XCTAssertEqual(diff.text, "@@ -1 +1 @@\n-old\n+new")
            XCTAssertEqual(diff.format, .unifiedDiff)
            XCTAssertFalse(diff.isTruncated)
            let wrongFile = await FileChangeDiffPreview.load(key: step.payloadReference, path: "Other.swift", store: store)
            guard case .unavailable = wrongFile else { return XCTFail("Must not display another file's diff") }
        }
    }

    func testAddedContentsAreLabeledHonestlyAndUnknownContentIsUnavailable() throws {
        let data = Data(
            #"{"payload":{"changes":{"New.swift":{"type":"add","content":"struct New {}"},"Other.swift":{"type":"update","content":"unknown"}}}}"#.utf8)
        let added = try XCTUnwrap(FileChangeDiff.extract(from: data, path: "New.swift"))
        XCTAssertEqual(added.format, .addedContent)
        XCTAssertEqual(added.text, "struct New {}")
        XCTAssertNil(FileChangeDiff.extract(from: data, path: "Other.swift"))
        XCTAssertNil(FileChangeDiff.extract(from: Data("not JSON".utf8), path: "New.swift"))
    }

    func testArrayChangesAndTruncation() throws {
        let text = "@@ -1 +1 @@\n" + String(repeating: "+line\n", count: 2_100)
        let data = try JSONSerialization.data(withJSONObject: ["file_changes": [["path": "App.swift", "unified_diff": text]]])
        let limitedLines = try XCTUnwrap(FileChangeDiff.extract(from: data, path: "App.swift"))
        XCTAssertTrue(limitedLines.isTruncated)
        XCTAssertEqual(limitedLines.text.split(separator: "\n").count, 2_000)
        let limitedText = try XCTUnwrap(FileChangeDiff.extract(from: data, path: "App.swift", maximumCharacters: 40))
        XCTAssertTrue(limitedText.isTruncated)
        XCTAssertLessThanOrEqual(limitedText.text.count, 40)
    }

    func testMissingAndOversizedPreviewsAreUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentTrail-DiffLimits-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PayloadStore(rootURL: root)
        let absent = await FileChangeDiffPreview.load(key: nil, path: "App.swift", store: store)
        guard case .unavailable = absent else { return XCTFail("Missing reference should be unavailable") }
        let missing = await FileChangeDiffPreview.load(key: String(repeating: "a", count: 64), path: "App.swift", store: store)
        guard case .unavailable = missing else { return XCTFail("Missing payload should be unavailable") }
        let data = Data(#"{"path":"App.swift","diff":"@@ -1 +1 @@\n-old\n+new"}"#.utf8)
        let key = try await store.write(data)
        let oversized = await FileChangeDiffPreview.load(key: key, path: "App.swift", store: store, maximumBytes: 8)
        guard case .unavailable(let reason) = oversized else { return XCTFail("Truncated JSON must not be guessed") }
        XCTAssertTrue(reason.contains("preview limit"))
    }

    func testStepNavigationRespectsFilteredOrderAndBoundaries() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertNil(TimelineStepNavigation(orderedIDs: ids, selection: ids[0]).previous)
        XCTAssertEqual(TimelineStepNavigation(orderedIDs: ids, selection: ids[0]).next, ids[1])
        XCTAssertEqual(TimelineStepNavigation(orderedIDs: ids, selection: ids[1]).previous, ids[0])
        XCTAssertEqual(TimelineStepNavigation(orderedIDs: ids, selection: ids[1]).next, ids[2])
        XCTAssertNil(TimelineStepNavigation(orderedIDs: ids, selection: ids[2]).next)
        XCTAssertNil(TimelineStepNavigation(orderedIDs: [ids[1]], selection: ids[1]).next)
        XCTAssertNil(TimelineStepNavigation(orderedIDs: [], selection: nil).previous)
        XCTAssertNil(TimelineStepNavigation(orderedIDs: ids, selection: UUID()).next)
    }
}
