import Darwin
import AppKit
import Foundation

/// A process-lifetime exclusive lease for AgentTrail's shared Application Support library.
///
/// Installed, disk-image, and Xcode builds share the same bundle identifier and support
/// directory. The lease must be acquired before backup, migration, SwiftData open, or
/// payload writes so only one process can mutate that directory at a time.
final class ApplicationSupportLease {
    static let lockFileName = ".library-owner.lock"

    private var fileDescriptor: Int32?

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        release()
    }

    static func acquire(in supportDirectory: URL) -> ApplicationSupportLeaseResult {
        acquire(in: supportDirectory, runningCopies: liveRunningCopies())
    }

    /// Test seam for same-bundle peers. Production uses `acquire(in:)`, which
    /// enumerates live `NSRunningApplication` copies.
    static func acquire(
        in supportDirectory: URL,
        runningCopies: [ApplicationSupportPeerCopy]
    ) -> ApplicationSupportLeaseResult {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
        } catch {
            return .unavailable("AgentTrail could not prepare its private Application Support folder.")
        }

        let lockURL = supportDirectory.appendingPathComponent(lockFileName)
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                return .ownedByAnotherProcess(readOwner(from: lockURL))
            }
            return .unavailable("AgentTrail could not open its library ownership file.")
        }

        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            return .unavailable("AgentTrail could not protect its library ownership file.")
        }

        // Keep exclusive ownership once O_EXLOCK succeeds. Same-bundle copies that
        // already dropped the lock (including equal launchDate peers still listed
        // by NSRunningApplication) must not poison later launches.
        _ = runningCopies

        let lease = ApplicationSupportLease(fileDescriptor: descriptor)
        do {
            try lease.writeOwnerMetadata()
            return .acquired(lease)
        } catch {
            lease.release()
            return .unavailable("AgentTrail could not record ownership of its local library.")
        }
    }

    /// Explicit release is primarily useful for deterministic lease tests.
    func release() {
        guard let descriptor = fileDescriptor else { return }
        fileDescriptor = nil
        Darwin.close(descriptor)
    }

    private func writeOwnerMetadata() throws {
        guard let descriptor = fileDescriptor else { throw POSIXError(.EBADF) }
        let metadata = ApplicationSupportOwner(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            copyDescription: Self.copyDescription(for: Bundle.main.bundleURL),
            acquiredAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)

        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), data.count - written)
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func readOwner(from lockURL: URL) -> ApplicationSupportOwner? {
        guard let data = try? Data(contentsOf: lockURL), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ApplicationSupportOwner.self, from: data)
    }

    private static func liveRunningCopies() -> [ApplicationSupportPeerCopy] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map {
            ApplicationSupportPeerCopy(
                processIdentifier: $0.processIdentifier,
                launchDate: $0.launchDate,
                bundleURL: $0.bundleURL,
                isTerminated: $0.isTerminated
            )
        }
    }

    private static func copyDescription(for bundleURL: URL) -> String {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/DerivedData/") || path.contains("/Build/Products/Debug/") {
            return "Xcode development build"
        }
        if path.hasPrefix("/Volumes/") {
            return "disk image copy"
        }
        return "installed copy"
    }
}

struct ApplicationSupportPeerCopy: Sendable, Equatable {
    let processIdentifier: pid_t
    let launchDate: Date?
    let bundleURL: URL?
    let isTerminated: Bool
}

struct ApplicationSupportOwner: Codable, Sendable, Equatable {
    let processIdentifier: Int32
    let copyDescription: String
    let acquiredAt: Date
}

enum ApplicationSupportLeaseResult {
    case acquired(ApplicationSupportLease)
    case ownedByAnotherProcess(ApplicationSupportOwner?)
    case unavailable(String)
}

enum LibraryAccessIssue: Sendable, Equatable {
    case ownedByAnotherProcess(ApplicationSupportOwner?)
    case unavailable(String)
}
