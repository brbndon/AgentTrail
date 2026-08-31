import CryptoKit
import Darwin
import Foundation
import os

enum PayloadStoreError: LocalizedError, Sendable {
    case invalidKey
    case invalidRoot
    case invalidPayload
    case oversized(Int)
    case missing
    case symlink
    case nonRegularFile
    case insecurePermissions
    case incomplete
    case corrupted
    case keyCollision(String)
    case fileSystem

    var errorDescription: String? {
        switch self {
        case .invalidKey: "The payload reference is invalid."
        case .invalidRoot: "Payload storage is not a private directory."
        case .invalidPayload: "The payload is not a valid JSON object."
        case .oversized(let bytes): "The payload exceeds the " + String(bytes) + "-byte storage limit."
        case .missing: "The payload file is unavailable."
        case .symlink: "The payload path is a symbolic link and was refused."
        case .nonRegularFile: "The payload path is not a regular file."
        case .insecurePermissions: "The payload file permissions are too permissive."
        case .incomplete: "The payload write was interrupted."
        case .corrupted: "The payload integrity check failed."
        case .keyCollision: "A payload reference already contains different data."
        case .fileSystem: "Payload storage failed."
        }
    }
}

/// Stores large trace payloads outside the SwiftData store.
actor PayloadStore {
    struct ReadResult: Sendable {
        let data: Data
        let isTruncated: Bool
    }

    static let maximumPayloadBytes = 64 * 1024 * 1024
    static let maximumReadBytes = 64 * 1024 * 1024

    nonisolated let rootURL: URL
    private let logger = Logger(subsystem: "com.brandon.AgentTrail", category: "payload-store")
    private var liveReferences: Set<String> = []
    private var protectedBranchReferences: Set<String> = []

    init(rootURL: URL? = nil) {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        self.rootURL = (rootURL ?? applicationSupport
            .appendingPathComponent("AgentTrail", isDirectory: true)
            .appendingPathComponent("Blobs", isDirectory: true)).standardizedFileURL
    }

    /// Writes a JSON payload without ever replacing an existing key. This is
    /// what makes a branch's shared payload immutable across source refreshes.
    ///
    /// Integrity sidecars are per-blob. Sidecar-less blobs remain readable as
    /// legacy data; a directory-wide format marker is never used.
    func write(_ data: Data, key requestedKey: String? = nil) throws -> String {
        let key = try Self.canonicalKey(requestedKey ?? UUID().uuidString.lowercased())
        guard data.count <= Self.maximumPayloadBytes else { throw PayloadStoreError.oversized(Self.maximumPayloadBytes) }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw PayloadStoreError.invalidPayload
        }
        try ensureRoot()

        let destination = payloadURL(for: key)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try readRegularFile(at: destination, maximumBytes: Self.maximumPayloadBytes + 1)
            guard existing.count <= Self.maximumPayloadBytes else {
                throw PayloadStoreError.oversized(Self.maximumPayloadBytes)
            }
            guard existing == data else { throw PayloadStoreError.keyCollision(key) }
            try ensureIntegrityMetadata(for: destination, data: existing)
            return key
        }

        let temporaryPayload = rootURL.appendingPathComponent(".\(key).\(UUID().uuidString).tmp")
        let temporaryMeta = rootURL.appendingPathComponent(".\(key).\(UUID().uuidString).sha256.tmp")
        let metadataURL = integrityURL(for: destination)
        do {
            try writeExclusive(data, to: temporaryPayload)
            try setPrivatePermissions(temporaryPayload)
            let digest = Self.hexSHA256(data)
            try writeExclusive(Data(digest.utf8), to: temporaryMeta)
            try setPrivatePermissions(temporaryMeta)
            // Payload first, then sidecar. A crash between these renames leaves a
            // sidecar-less blob that remains readable as legacy-compatible data.
            try FileManager.default.moveItem(at: temporaryPayload, to: destination)
            try setPrivatePermissions(destination)
            try FileManager.default.moveItem(at: temporaryMeta, to: metadataURL)
            try setPrivatePermissions(metadataURL)
            return key
        } catch {
            try? FileManager.default.removeItem(at: temporaryPayload)
            try? FileManager.default.removeItem(at: temporaryMeta)
            // If the payload landed without a sidecar, leave it; reads still work.
            if let payloadError = error as? PayloadStoreError { throw payloadError }
            throw PayloadStoreError.fileSystem
        }
    }

    /// Reads a payload by storage key for the detail inspector. Caller limits
    /// are clamped to the store's hard upper bound.
    func read(key requestedKey: String, maximumBytes requestedMaximumBytes: Int = 4 * 1024 * 1024) throws -> ReadResult {
        let key = try Self.canonicalKey(requestedKey)
        let maximumBytes = min(max(requestedMaximumBytes, 1), Self.maximumReadBytes)
        try ensureRoot()
        let url = payloadURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PayloadStoreError.missing }

        let fullData = try readRegularFile(at: url, maximumBytes: Self.maximumPayloadBytes + 1)
        guard fullData.count <= Self.maximumPayloadBytes else {
            throw PayloadStoreError.oversized(Self.maximumPayloadBytes)
        }
        try verifyIntegrity(for: url, data: fullData)
        guard (try? JSONSerialization.jsonObject(with: fullData)) != nil else {
            throw PayloadStoreError.corrupted
        }

        let data = fullData.prefix(maximumBytes)
        return ReadResult(data: Data(data), isTruncated: fullData.count > maximumBytes)
    }

    /// Keeps live model references current. Branch references are protected
    /// separately because a source refresh must never make them collectible.
    func setLiveReferences(_ references: Set<String>) {
        liveReferences = references.compactMap(Self.normalizedKey)
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    /// Replaces the in-memory branch protection set. Call after a successful
    /// SwiftData save using references recomputed from durable branch records.
    func replaceProtectedBranchReferences(_ references: Set<String>) {
        protectedBranchReferences = references.compactMap(Self.normalizedKey)
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    /// Removes old blobs not referenced by any current or branched record. A
    /// filesystem error is returned to the caller instead of being hidden.
    func removeUnreferenced(keeping references: Set<String>, olderThan age: TimeInterval = 86_400) throws {
        try ensureRoot()
        let activeReferences = liveReferences
            .union(protectedBranchReferences)
            .union(references.compactMap(Self.normalizedKey))
        var firstError: Error?
        let files: [URL]
        do {
            // Include hidden files so interrupted `.*.tmp` writes are collected.
            files = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw PayloadStoreError.fileSystem
        }

        let now = Date.now
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix(".") || file.pathExtension == "tmp" || name.hasSuffix(".tmp") {
                let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(modifiedAt) > age {
                    do {
                        try FileManager.default.removeItem(at: file)
                    } catch {
                        firstError = firstError ?? PayloadStoreError.fileSystem
                        logger.error("Unable to collect temporary payload file")
                    }
                }
                continue
            }
            if name.hasSuffix(".json.sha256") || file.pathExtension == "sha256" {
                // Orphan sidecars without a matching payload are collectible.
                let payloadName = name.replacingOccurrences(of: ".sha256", with: "")
                let payload = rootURL.appendingPathComponent(payloadName)
                if !FileManager.default.fileExists(atPath: payload.path) {
                    let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                    if now.timeIntervalSince(modifiedAt) > age {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
                continue
            }
            guard file.pathExtension == "json" else { continue }
            let key = file.deletingPathExtension().lastPathComponent.lowercased()
            guard Self.normalizedKey(key) != nil, !activeReferences.contains(key) else { continue }
            do {
                try assertSafeRegularFile(file)
                let modifiedAt = (try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                guard now.timeIntervalSince(modifiedAt) > age else { continue }
                try FileManager.default.removeItem(at: file)
                let metadata = integrityURL(for: file)
                if FileManager.default.fileExists(atPath: metadata.path) {
                    do {
                        try FileManager.default.removeItem(at: metadata)
                    } catch {
                        firstError = firstError ?? PayloadStoreError.fileSystem
                        logger.error("Unable to collect payload integrity metadata")
                    }
                }
            } catch {
                firstError = firstError ?? error
                logger.error("Unable to collect payload blob")
            }
        }
        if let firstError {
            if let payloadError = firstError as? PayloadStoreError { throw payloadError }
            throw PayloadStoreError.fileSystem
        }
    }

    /// The user-visible location used by Settings and diagnostics.
    nonisolated var location: URL { rootURL }

    private func ensureRoot() throws {
        let fileManager = FileManager.default
        guard rootURL.resolvingSymlinksInPath().path == rootURL.path else {
            throw PayloadStoreError.symlink
        }
        if fileManager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true else { throw PayloadStoreError.invalidRoot }
            guard values.isSymbolicLink != true else { throw PayloadStoreError.symlink }
            try setPrivatePermissions(rootURL)
        } else {
            do {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                try setPrivatePermissions(rootURL)
            } catch {
                throw PayloadStoreError.fileSystem
            }
        }
    }

    private func payloadURL(for key: String) -> URL {
        rootURL.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func integrityURL(for payloadURL: URL) -> URL {
        payloadURL.appendingPathExtension("sha256")
    }

    private func ensureIntegrityMetadata(for url: URL, data: Data) throws {
        let metadataURL = integrityURL(for: url)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let expected = try String(data: readRegularFile(at: metadataURL, maximumBytes: 128), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = Self.hexSHA256(data)
            guard expected == actual else { throw PayloadStoreError.corrupted }
            return
        }
        let digest = Self.hexSHA256(data)
        let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString).sha256.tmp")
        do {
            try writeExclusive(Data(digest.utf8), to: temporary)
            try setPrivatePermissions(temporary)
            try FileManager.default.moveItem(at: temporary, to: metadataURL)
            try setPrivatePermissions(metadataURL)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PayloadStoreError.fileSystem
        }
    }

    /// Sidecar present → verify. Sidecar absent → legacy blob, still readable.
    private func verifyIntegrity(for url: URL, data: Data) throws {
        let metadataURL = integrityURL(for: url)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return
        }
        let expected = try String(data: readRegularFile(at: metadataURL, maximumBytes: 128), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = Self.hexSHA256(data)
        guard expected == actual else { throw PayloadStoreError.corrupted }
    }

    /// Opens with `O_NOFOLLOW`, then `fstat`s and reads through the descriptor
    /// so a TOCTOU replacement of the path cannot redirect the read.
    private func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        let path = url.path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP || errno == EMLINK { throw PayloadStoreError.symlink }
            if errno == ENOENT { throw PayloadStoreError.missing }
            throw PayloadStoreError.fileSystem
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw PayloadStoreError.fileSystem }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw PayloadStoreError.nonRegularFile }
        guard info.st_size >= 0, info.st_size <= off_t(maximumBytes) else {
            throw PayloadStoreError.oversized(Self.maximumPayloadBytes)
        }

        let size = Int(info.st_size)
        var data = Data(count: size)
        if size > 0 {
            let readCount: Int = data.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(fd, base, size)
            }
            guard readCount == size else { throw PayloadStoreError.fileSystem }
        }
        try setPrivatePermissions(url)
        return data
    }

    private func writeExclusive(_ data: Data, to url: URL) throws {
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == ELOOP || errno == EMLINK { throw PayloadStoreError.symlink }
            throw PayloadStoreError.fileSystem
        }
        defer { close(fd) }
        if !data.isEmpty {
            let written: Int = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base, data.count)
            }
            guard written == data.count else { throw PayloadStoreError.fileSystem }
        }
        guard fsync(fd) == 0 else { throw PayloadStoreError.fileSystem }
    }

    private func assertSafeRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw PayloadStoreError.symlink }
        guard values.isRegularFile == true else { throw PayloadStoreError.nonRegularFile }
        try setPrivatePermissions(url)
    }

    private func setPrivatePermissions(_ url: URL) throws {
        do {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            try FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
        } catch {
            throw PayloadStoreError.insecurePermissions
        }
    }

    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalKey(_ key: String) throws -> String {
        guard let normalized = normalizedKey(key) else { throw PayloadStoreError.invalidKey }
        return normalized
    }

    private static func normalizedKey(_ key: String) -> String? {
        guard key.count <= TraceLimits.identity,
              let uuid = UUID(uuidString: key),
              uuid.uuidString.lowercased() == key.lowercased()
        else { return nil }
        return uuid.uuidString.lowercased()
    }
}
