import Foundation
import Observation

/// Transient snapshots for the dashboard's fetch-limited page. Reconciliation
/// explicitly invalidates changed sessions, including edits with unchanged mtime.
/// A changed or invalidated entry keeps serving its previous summary until the
/// rebuild lands, so live sessions never fall back to a placeholder.
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
        var isDirty = false
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
        entries[id]?.isDirty = true
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
            if let entry = entries[session.id], entry.stamp == stamp, !entry.isDirty { continue }
            entries[session.id] = Entry(stamp: stamp, summary: summarize(session))
            await Task.yield()
        }
    }

    /// Whether the stored summary reflects the session's current stamp and has not been invalidated.
    func isCurrent(_ session: SessionRecord) -> Bool {
        guard let entry = entries[session.id] else { return false }
        return entry.stamp == Stamp(session) && !entry.isDirty
    }

    /// Nil only before the first summary exists; afterwards possibly stale, never a placeholder.
    func summary(for session: SessionRecord, now: Date) -> SessionSummary? {
        entries[session.id]?.summary.updatingLiveness(session: session, now: now)
    }

    func needsAttention(in sessions: [SessionRecord]) -> Int? {
        guard sessions.allSatisfy({ entries[$0.id] != nil }) else { return nil }
        return sessions.filter { entries[$0.id]?.summary.errorCount ?? 0 > 0 }.count
    }
}
