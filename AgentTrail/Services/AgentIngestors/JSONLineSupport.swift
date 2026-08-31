import Foundation
import os

struct JSONLScanStats: Sendable, Equatable {
    var validRecords = 0
    var malformedLines = 0
    var oversizedLines = 0
    var nonObjectLines = 0
    var emptyLines = 0

    var skippedLines: Int { malformedLines + oversizedLines + nonObjectLines }
    var hasProblems: Bool { skippedLines > 0 }
    var isMalformedOnly: Bool { validRecords == 0 && skippedLines > 0 }
}

enum JSONLineSupport {
    private static let logger = Logger(subsystem: "com.brandon.AgentTrail", category: "ingestion")
    private static let readChunkSize = 64 * 1024
    private static let maximumLineBytes = 64 * 1024 * 1024

    /// Streams JSONL records so one large session does not occupy memory as a whole file.
    /// Malformed JSON records are skipped and counted; I/O and parser callback failures
    /// are propagated so a source cannot be reported as healthy after partial work.
    @discardableResult
    static func forEachDictionary(
        at url: URL,
        byteRange: Range<UInt64>? = nil,
        body: (Int, [String: Any], Data) async throws -> Void
    ) async throws -> JSONLScanStats {
        let handle = try FileHandle(forReadingFrom: url)
        let startOffset = byteRange?.lowerBound ?? 0
        let endOffset = byteRange?.upperBound
        try handle.seek(toOffset: startOffset)

        var line = Data()
        line.reserveCapacity(min(readChunkSize, maximumLineBytes))
        var lineNumber = 0
        var stats = JSONLScanStats()
        var lineIsTooLarge = false

        func processCurrentLine() async throws {
            lineNumber += 1
            defer {
                line.removeAll(keepingCapacity: true)
                lineIsTooLarge = false
            }
            guard !line.isEmpty else {
                stats.emptyLines += 1
                return
            }
            guard !lineIsTooLarge else {
                stats.oversizedLines += 1
                logger.warning("Skipping oversized JSONL record at line \(lineNumber, privacy: .public)")
                return
            }

            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: line)
            } catch {
                stats.malformedLines += 1
                logger.debug("Skipping malformed JSONL record at line \(lineNumber, privacy: .public)")
                return
            }
            guard let dictionary = object as? [String: Any] else {
                stats.nonObjectLines += 1
                logger.warning("Skipping non-object JSONL record at line \(lineNumber, privacy: .public)")
                return
            }
            stats.validRecords += 1
            try await body(lineNumber - 1, dictionary, line)
        }

        var operationError: Error?
        do {
            var offset = startOffset
            while endOffset.map({ offset < $0 }) ?? true {
                try Task.checkCancellation()
                let requestedCount = endOffset.map { min(readChunkSize, Int($0 - offset)) } ?? readChunkSize
                guard requestedCount > 0,
                      let chunk = try handle.read(upToCount: requestedCount),
                      !chunk.isEmpty
                else { break }
                offset += UInt64(chunk.count)
                for byte in chunk {
                    if byte == 0x0A {
                        try await processCurrentLine()
                        continue
                    }
                    guard !lineIsTooLarge else { continue }
                    if line.count >= maximumLineBytes {
                        lineIsTooLarge = true
                    } else {
                        line.append(byte)
                    }
                }
            }

            if !line.isEmpty || lineIsTooLarge {
                try await processCurrentLine()
            }
        } catch {
            operationError = error
        }

        do {
            try handle.close()
        } catch {
            operationError = operationError ?? error
        }
        if let operationError {
            throw operationError
        }
        return stats
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? String { return TraceLimits.required(value, to: TraceLimits.summary) }
        if let value = value as? NSNumber { return TraceLimits.required(value.stringValue, to: TraceLimits.summary) }
        return nil
    }

    /// Signed integer within `TraceLimits` (exit codes may be negative).
    static func integer(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? Int { return TraceLimits.boundedInteger(value) }
        if let value = value as? NSNumber { return TraceLimits.boundedInteger(value.intValue) }
        if let value = value as? String, let value = Int(value) { return TraceLimits.boundedInteger(value) }
        return nil
    }

    /// Non-negative integer within `TraceLimits` (token counts, indexes).
    static func nonNegativeInteger(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? Int { return TraceLimits.boundedNonNegative(value) }
        if let value = value as? NSNumber { return TraceLimits.boundedNonNegative(value.intValue) }
        if let value = value as? String, let value = Int(value) { return TraceLimits.boundedNonNegative(value) }
        return nil
    }

    /// True when an `error` field represents a real failure (`true`, non-empty
    /// string/object). `false`, `0`, and null are not errors.
    static func isTruthyError(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber {
            // Distinguish real booleans from numeric zeros.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number != 0
        }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && normalized != "false" && normalized != "0" && normalized != "null" && normalized != "nil"
        }
        if value is [Any] || value is [String: Any] { return true }
        return true
    }

    static func hasFailure(in value: Any, depth: Int = 0) -> Bool {
        guard depth < 5, let dictionary = value as? [String: Any] else { return false }
        if isTruthyError(dictionary["error"]) || isTruthyError(dictionary["isError"]) { return true }
        if let success = dictionary["success"] as? Bool, !success { return true }
        if let status = string(dictionary["status"])?.lowercased(),
           ["failed", "failure", "error", "errored", "cancelled", "canceled", "timed_out", "timeout"].contains(status) {
            return true
        }
        for key in ["item", "result", "execution"] {
            if let nested = dictionary[key], hasFailure(in: nested, depth: depth + 1) { return true }
        }
        return false
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber {
            return date(fromUnixTimestamp: seconds.doubleValue)
        }
        if let string = value as? String,
           let raw = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return date(fromUnixTimestamp: raw)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func date(fromUnixTimestamp raw: Double) -> Date? {
        guard raw.isFinite else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
        guard seconds > -62_135_596_800, seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    static func nonNull(_ value: Any?) -> Any? {
        isNull(value) ? nil : value
    }

    static func compactText(from value: Any, limit: Int = 180, maximumCharacters: Int = TraceLimits.summary) -> String {
        var result = ""

        func append(_ value: String) {
            guard !value.isEmpty, result.count < maximumCharacters else { return }
            let remaining = maximumCharacters - result.count
            if !result.isEmpty { result.append(" ") }
            result.append(contentsOf: value.prefix(remaining))
        }

        func visit(_ value: Any, depth: Int) {
            guard depth < 5, result.count < maximumCharacters else { return }
            if let string = value as? String {
                append(string)
                return
            }
            if let array = value as? [Any] {
                for child in array {
                    visit(child, depth: depth + 1)
                    if result.count >= maximumCharacters { return }
                }
                return
            }
            guard let dictionary = value as? [String: Any] else { return }
            for key in preferredTextKeys {
                if let child = dictionary[key] {
                    visit(child, depth: depth + 1)
                    if result.count >= maximumCharacters { return }
                }
            }
        }

        visit(value, depth: 0)
        return compact(result, limit: limit)
    }

    private static let preferredTextKeys = [
        "text", "message", "content", "summary", "reasoning", "command", "output",
        "result", "error", "path", "file_path", "filePath", "name", "query"
    ]

    static func firstValue(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary[key], let value = nonNull(value) { return value }
            if let (_, value) = dictionary.first(where: { candidate, _ in
                candidate.caseInsensitiveCompare(key) == .orderedSame
            }), let value = nonNull(value) {
                return value
            }
        }
        return nil
    }

    static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        string(firstValue(in: dictionary, keys: keys))
    }

    static func firstString(in value: Any, keys: [String], depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let result = firstString(in: dictionary, keys: keys) { return result }
            for key in dictionary.keys.sorted() {
                if let result = firstString(in: dictionary[key] as Any, keys: keys, depth: depth + 1) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = firstString(in: child, keys: keys, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    static func firstInteger(in dictionary: [String: Any], keys: [String]) -> Int? {
        integer(firstValue(in: dictionary, keys: keys))
    }

    static func firstInteger(in value: Any, keys: [String], depth: Int = 0) -> Int? {
        guard depth < 6 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let result = firstInteger(in: dictionary, keys: keys) { return result }
            for key in dictionary.keys.sorted() {
                if let result = firstInteger(in: dictionary[key] as Any, keys: keys, depth: depth + 1) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = firstInteger(in: child, keys: keys, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    static func firstNonNegativeInteger(in dictionary: [String: Any], keys: [String]) -> Int? {
        nonNegativeInteger(firstValue(in: dictionary, keys: keys))
    }

    static func firstNonNegativeInteger(in value: Any, keys: [String], depth: Int = 0) -> Int? {
        guard depth < 6 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let result = firstNonNegativeInteger(in: dictionary, keys: keys) { return result }
            for key in dictionary.keys.sorted() {
                if let result = firstNonNegativeInteger(in: dictionary[key] as Any, keys: keys, depth: depth + 1) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = firstNonNegativeInteger(in: child, keys: keys, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    static func firstDate(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys where !isNull(dictionary[key]) {
            if let date = date(dictionary[key]) { return date }
        }
        return nil
    }

    static func firstDate(in value: Any, keys: [String], depth: Int = 0) -> Date? {
        guard depth < 6 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let result = firstDate(in: dictionary, keys: keys) { return result }
            for key in dictionary.keys.sorted() {
                if let result = firstDate(in: dictionary[key] as Any, keys: keys, depth: depth + 1) {
                    return result
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = firstDate(in: child, keys: keys, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    static func firstPath(in value: Any, depth: Int = 0) -> String? {
        guard depth < 5 else { return nil }
        if let dictionary = value as? [String: Any] {
            for key in ["path", "file_path", "filePath", "filename"] {
                if let path = string(firstValue(in: dictionary, keys: [key])), !path.isEmpty {
                    return TraceLimits.required(path, to: TraceLimits.path)
                }
            }
            for key in dictionary.keys.sorted() {
                if let path = firstPath(in: dictionary[key] as Any, depth: depth + 1) { return path }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let path = firstPath(in: child, depth: depth + 1) { return path }
            }
        }
        return nil
    }

    static func compact(_ value: String, limit: Int = 180) -> String {
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let safeLimit = min(max(limit, 1), 1_024)
        guard normalized.count > safeLimit else { return normalized }
        guard safeLimit > 1 else { return String(normalized.prefix(safeLimit)) }
        return String(normalized.prefix(safeLimit - 1)) + "…"
    }

    static func sessionStatus(for modifiedAt: Date, terminalStatus: String? = nil) -> SessionStatus {
        let terminalStatus = terminalStatus?.lowercased()
        if ["failed", "failure", "error"].contains(terminalStatus) { return .failed }
        if ["completed", "complete", "success", "succeeded", "done"].contains(terminalStatus) {
            return .historical
        }
        let age = Date.now.timeIntervalSince(modifiedAt)
        return age >= 0 && age < 10 ? .recording : .historical
    }

    static func tokenCount(in value: Any) -> Int? {
        if let total = firstNonNegativeInteger(in: value, keys: ["token_count", "tokenCount", "total_tokens", "totalTokens"]) {
            return total
        }
        let input = firstNonNegativeInteger(in: value, keys: ["input_tokens", "inputTokens", "prompt_tokens", "promptTokens"]) ?? 0
        let output = firstNonNegativeInteger(in: value, keys: ["output_tokens", "outputTokens", "completion_tokens", "completionTokens"]) ?? 0
        let total = input.addingReportingOverflow(output)
        return total.overflow ? 1_000_000_000 : (input + output == 0 ? nil : total.partialValue)
    }

    static func fileChanges(in value: Any, eventType: String? = nil) -> [ParsedFileChange] {
        guard let dictionary = value as? [String: Any] else { return [] }
        var candidates: [[String: Any]] = []
        for key in ["file_changes", "fileChanges", "changes", "files"] {
            let changes = firstValue(in: dictionary, keys: [key])
            candidates.append(contentsOf: array(changes).compactMap { $0 as? [String: Any] })
            if let mappedChanges = changes as? [String: Any] {
                for path in mappedChanges.keys.sorted() {
                    guard var change = mappedChanges[path] as? [String: Any] else { continue }
                    change["path"] = path
                    candidates.append(change)
                }
            }
        }
        if candidates.isEmpty, firstPath(in: dictionary) != nil,
           eventType?.contains("file") == true || eventType?.contains("patch") == true ||
           firstValue(in: dictionary, keys: ["change_type", "changeType", "before_hash", "after_hash", "diff"]) != nil {
            candidates = [dictionary]
        }

        return candidates.prefix(TraceLimits.maxFileChanges).compactMap { candidate in
            guard let path = firstPath(in: candidate) else { return nil }
            let changeType = firstString(in: candidate, keys: ["change_type", "changeType", "operation", "status", "type"]) ?? "modified"
            let hasDiff = nonNull(firstValue(in: candidate, keys: ["diff", "patch", "unified_diff", "content"])) != nil
            return ParsedFileChange(
                path: path,
                changeType: changeType,
                beforeHash: firstString(in: candidate, keys: ["before_hash", "beforeHash", "old_hash", "oldHash"]),
                afterHash: firstString(in: candidate, keys: ["after_hash", "afterHash", "new_hash", "newHash"]),
                hasDiff: hasDiff
            )
        }
    }
}
