import Foundation

/// Extracts only the requested file from the original JSON event. A storage key
/// points to that event, not to a standalone diff blob.
struct FileChangeDiff: Equatable, Sendable {
    enum Format: Equatable, Sendable { case unifiedDiff, addedContent }
    let text: String
    let format: Format
    let isTruncated: Bool

    static func extract(from data: Data, path: String, maximumCharacters: Int = 128_000) -> FileChangeDiff? {
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let payload = record["payload"] as? [String: Any] ?? record
        let item = payload["item"] as? [String: Any] ?? payload
        var candidate: [String: Any]?
        for key in ["changes", "file_changes", "fileChanges", "files"] {
            if let changes = item[key] as? [String: Any], let change = changes[path] as? [String: Any] {
                candidate = change
                break
            }
            if let changes = item[key] as? [[String: Any]] {
                candidate = changes.first { filePath(in: $0) == path }
                if candidate != nil { break }
            }
        }
        if candidate == nil, filePath(in: item) == path { candidate = item }
        guard let candidate else { return nil }

        for key in ["unified_diff", "diff", "patch"] {
            if let text = candidate[key] as? String,
                text.contains("@@") || text.hasPrefix("diff --git ") || text.hasPrefix("*** Begin Patch")
            {
                return bounded(text, format: .unifiedDiff, maximumCharacters: maximumCharacters)
            }
        }
        let operation = (candidate["type"] ?? candidate["change_type"] ?? candidate["operation"]) as? String
        if ["add", "added", "create"].contains(operation?.lowercased() ?? ""), let text = candidate["content"] as? String {
            return bounded(text, format: .addedContent, maximumCharacters: maximumCharacters)
        }
        return nil
    }

    private static func filePath(in candidate: [String: Any]) -> String? {
        for key in ["path", "file_path", "filePath", "filename"] {
            if let path = candidate[key] as? String { return path }
        }
        return nil
    }

    private static func bounded(_ text: String, format: Format, maximumCharacters: Int) -> FileChangeDiff {
        let prefix = String(text.prefix(max(maximumCharacters, 1)))
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        let preview = lines.prefix(2_000).joined(separator: "\n")
        return FileChangeDiff(text: preview, format: format, isTruncated: prefix.count < text.count || lines.count > 2_000)
    }
}

enum FileChangeDiffPreview: Equatable, Sendable {
    case available(FileChangeDiff)
    case unavailable(String)

    static func load(key: String?, path: String, store: PayloadStore, maximumBytes: Int = 4 * 1024 * 1024) async -> FileChangeDiffPreview {
        guard let key else { return .unavailable("No diff was recorded for this file.") }
        do {
            let result = try await store.read(key: key, maximumBytes: maximumBytes)
            try Task.checkCancellation()
            guard !result.isTruncated else { return .unavailable("Original data exceeds the diff preview limit (4 MB).") }
            guard let diff = FileChangeDiff.extract(from: result.data, path: path) else {
                return .unavailable("The original data does not contain a supported diff for this file.")
            }
            return .available(diff)
        } catch is CancellationError {
            return .unavailable("Diff loading was cancelled.")
        } catch {
            return .unavailable((error as? LocalizedError)?.errorDescription ?? "The original data could not be loaded.")
        }
    }
}
