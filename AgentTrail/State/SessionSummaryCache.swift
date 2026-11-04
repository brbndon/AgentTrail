import Foundation
import Observation

/// Transient snapshots for the dashboard's fetch-limited page. Reconciliation
/// explicitly invalidates changed sessions, including edits with unchanged mtime.
@MainActor
@Observable
final class SessionSummaryCache {
    struct Stamp: Hashable {
        let id: UUID
        let modified: Date
        let started: Date
        let ended: Date?

        init(_ session: SessionRecord) {
            id = session.id
            modified = session.sourceModifiedAt
            started = session.startDate
            ended = session.endDate
        }
    }

    struct Request: Hashable {
        let stamps: [Stamp]
        let revision: UInt64
    }

    private struct Entry {
        let stamp: Stamp
        let summary: SessionSummary
    }

    private var entries: [UUID: Entry] = [:]
    private var revision: UInt64 = 0
    private let summarize: (SessionRecord) -> SessionSummary

    init(
        summarize: @escaping (SessionRecord) -> SessionSummary = {
            SessionSummary(session: $0, steps: $0.steps, now: .distantFuture)
        }
    ) {
        self.summarize = summarize
    }

    func request(for sessions: [SessionRecord]) -> Request {
        Request(stamps: sessions.map(Stamp.init), revision: revision)
    }

    func invalidate(_ id: UUID) {
        entries.removeValue(forKey: id)
        revision &+= 1
    }

    func prepare(_ sessions: [SessionRecord]) async {
        let ids = Set(sessions.map(\.id))
        if entries.keys.contains(where: { !ids.contains($0) }) {
            entries = entries.filter { ids.contains($0.key) }
        }
        for session in sessions {
            guard !Task.isCancelled else { return }
            let stamp = Stamp(session)
            if entries[session.id]?.stamp != stamp {
                entries[session.id] = Entry(stamp: stamp, summary: summarize(session))
                await Task.yield()
            }
        }
    }

    func summary(for session: SessionRecord, now: Date) -> SessionSummary? {
        guard let entry = entries[session.id], entry.stamp == Stamp(session) else { return nil }
        return entry.summary.updatingLiveness(session: session, now: now)
    }

    func needsAttention(in sessions: [SessionRecord]) -> Int? {
        guard sessions.allSatisfy({ entries[$0.id]?.stamp == Stamp($0) }) else { return nil }
        return sessions.filter { entries[$0.id]?.summary.errorCount ?? 0 > 0 }.count
    }
}
