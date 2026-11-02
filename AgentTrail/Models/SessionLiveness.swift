import Foundation

struct LiveSessionMenuItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let projectName: String
    let eventCount: Int

    var displayTitle: String {
        "\(title) — \(projectName) · \(eventCount) events"
    }
}

enum SessionLiveness {
    static let recency: TimeInterval = 180
    static let tickInterval: TimeInterval = 15
    static let menuLimit = 20

    static func isRecentlyWriting(
        sourceModifiedAt: Date,
        isBranch: Bool,
        agentType: AgentType,
        sourceState: SessionSourceState,
        now: Date
    ) -> Bool {
        guard agentType == .codex, !isBranch, sourceState != .unavailable else { return false }
        let age = now.timeIntervalSince(sourceModifiedAt)
        return age >= 0 && age < recency
    }

    static func isRecentlyWriting(_ session: SessionRecord, now: Date) -> Bool {
        isRecentlyWriting(
            sourceModifiedAt: session.sourceModifiedAt,
            isBranch: session.isBranch,
            agentType: session.agentType,
            sourceState: session.sourceState,
            now: now
        )
    }

    static func slice(from sessions: [SessionRecord], now: Date) -> (sessions: [SessionRecord], overflowCount: Int) {
        let live = sessions
            .filter { isRecentlyWriting($0, now: now) }
            .sorted { lhs, rhs in
                if lhs.sourceModifiedAt != rhs.sourceModifiedAt {
                    return lhs.sourceModifiedAt > rhs.sourceModifiedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        if live.count <= menuLimit {
            return (live, 0)
        }
        return (Array(live.prefix(menuLimit)), live.count - menuLimit)
    }

    static func extraSymbolName(liveCount: Int) -> String {
        liveCount == 0 ? "circle.dashed" : "record.circle"
    }

    static func extraAccessibilityLabel(liveCount: Int) -> String {
        switch liveCount {
        case 0: "No live Codex sessions"
        case 1: "1 live Codex session"
        default: "\(liveCount) live Codex sessions"
        }
    }
}
