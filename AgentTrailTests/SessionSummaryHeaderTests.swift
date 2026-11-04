@testable import AgentTrail
import AppKit
import SwiftUI
import XCTest

final class SessionSummaryHeaderTests: XCTestCase {
    @MainActor
    func testHeaderRendersInLightAndDarkWithIsolatedPreferences() async throws {
        let suiteName = "AgentTrailTests.SummaryHeader.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "timeline.sessionSummaryExpanded")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTrail-SummaryPreviews-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date.now
        let session = SessionRecord(
            sourceKey: "test:header", agentType: .codex, title: "Repair ingestion",
            startDate: now.addingTimeInterval(-1_800), endDate: now.addingTimeInterval(-600),
            workingDirectory: "/tmp/AgentTrail", sourcePath: "/tmp/header.jsonl",
            sourceModifiedAt: now.addingTimeInterval(-600)
        )
        let request = StepRecord(
            stepIndex: 0, kind: .user, timestamp: session.startDate,
            title: "Repair ingestion", contentSummary: "Find why the live session stopped importing events.",
            searchText: "", fullPayloadRef: nil, hasError: false)
        let error = StepRecord(
            stepIndex: 1, kind: .toolResult, timestamp: now.addingTimeInterval(-900),
            title: "Tests failed", contentSummary: "An incomplete record interrupted importing.",
            searchText: "", fullPayloadRef: nil, hasError: true, filePath: "Tests/ParserTests.swift")
        let reply = StepRecord(
            stepIndex: 2, kind: .assistant, timestamp: now.addingTimeInterval(-600),
            title: "Fixed ingestion", contentSummary: "Updated the parser to resume after incomplete records. All tests now pass.",
            searchText: "", fullPayloadRef: nil, hasError: false, filePath: "Sources/Parser.swift")
        let summary = SessionSummary(session: session, steps: [request, error, reply], now: now)
        session.steps = [request, error, reply]

        for (name, scheme) in [("Light", ColorScheme.light), ("Dark", ColorScheme.dark)] {
            let view = SessionSummaryHeader(summary: summary, filePathQuery: .constant(""))
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, scheme)
            try await capture(
                view, size: NSSize(width: 850, height: 330), scheme: scheme,
                name: "Summary-\(name)", directory: directory)
            let preferences = BrowsePreferences(defaults: defaults)
            let timeline = TimelineView(
                session: session, payloadStore: PayloadStore(rootURL: directory.appendingPathComponent("Blobs")), preferences: preferences
            )
            .modelContainer(try AgentTrailPersistence.makeInMemoryContainer())
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, scheme)
            try await capture(
                timeline, size: NSSize(width: 970, height: 700), scheme: scheme,
                name: "Timeline-\(name)", directory: directory)
            preferences.viewMode = .technical
            try await capture(
                timeline, size: NSSize(width: 970, height: 700), scheme: scheme,
                name: "Timeline-Technical-\(name)", directory: directory)
            preferences.viewMode = .simple
        }
        print("Session summary renderings: \(directory.path)")
    }

    @MainActor
    private func capture(_ view: some View, size: NSSize, scheme: ColorScheme, name: String, directory: URL) async throws {
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = hostingView
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        hostingView.layoutSubtreeIfNeeded()
        window.display()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
