import Foundation

enum TimelineElapsedTime {
    static func label(timestamp: Date, sessionStart: Date) -> String {
        let seconds = max(0, Int(timestamp.timeIntervalSince(sessionStart)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "+\(hours)h \(minutes)m \(remainder)s" }
        if minutes > 0 { return "+\(minutes)m \(remainder)s" }
        return "+\(remainder)s"
    }
}
