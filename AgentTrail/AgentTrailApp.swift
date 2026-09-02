import Foundation
import SwiftData
import SwiftUI

enum AgentTrailRuntime {
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func directories() -> AgentDirectories {
        if isTestHost {
            return AgentDirectories(homeDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("AgentTrail-TestHost", isDirectory: true))
        }
        return AgentDirectories()
    }

    static func payloadStore() -> PayloadStore {
        if isTestHost {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentTrail-TestHost", isDirectory: true)
                .appendingPathComponent("Blobs", isDirectory: true)
            return PayloadStore(rootURL: root)
        }
        return PayloadStore()
    }
}

enum PersistenceMode: Sendable, Equatable {
    case disk
    case recoveredFromBackup
    case emergencyInMemory
    case unavailable
}

struct AgentTrailPersistenceResult {
    let container: ModelContainer?
    let mode: PersistenceMode
    let startupMessage: String?
}

enum AgentTrailPersistence {
    static let storeFileName = "AgentTrail.store"
    static let maximumBackups = 5

    static func makeContainer(isTestHost: Bool) -> AgentTrailPersistenceResult {
        if isTestHost {
            do {
                return AgentTrailPersistenceResult(container: try makeInMemoryContainer(), mode: .disk, startupMessage: nil)
            } catch {
                return AgentTrailPersistenceResult(
                    container: makeEmergencyContainer(),
                    mode: .emergencyInMemory,
                    startupMessage: "Test storage unavailable; using an empty in-memory store."
                )
            }
        }

        return openDiskStore(supportDirectory: applicationSupportURL)
    }

    /// Opens a versioned disk store under `supportDirectory`.
    /// When `AgentTrail.store` already exists, a successful pre-open backup is
    /// required before open/migrate. Failure leaves the original store untouched.
    static func openDiskStore(supportDirectory: URL) -> AgentTrailPersistenceResult {
        let storeURL = supportDirectory.appendingPathComponent(storeFileName)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: storeURL.path) {
            do {
                try backupStore(at: storeURL, supportDirectory: supportDirectory, label: "pre-open")
            } catch {
                return AgentTrailPersistenceResult(
                    container: makeEmergencyContainer(),
                    mode: .emergencyInMemory,
                    startupMessage: "Could not back up the local store before opening it; AgentTrail is using an empty in-memory store. The existing store was left untouched."
                )
            }
        }

        do {
            let container = try makeDiskContainer(at: storeURL)
            try? pruneBackups(in: supportDirectory.appendingPathComponent("Backups", isDirectory: true))
            return AgentTrailPersistenceResult(container: container, mode: .disk, startupMessage: nil)
        } catch {
            do {
                try restoreLatestBackup(to: storeURL, supportDirectory: supportDirectory)
                let container = try makeDiskContainer(at: storeURL)
                return AgentTrailPersistenceResult(
                    container: container,
                    mode: .recoveredFromBackup,
                    startupMessage: "AgentTrail recovered its local store from the latest backup."
                )
            } catch {
                return AgentTrailPersistenceResult(
                    container: makeEmergencyContainer(),
                    mode: .emergencyInMemory,
                    startupMessage: "The local store could not be opened; AgentTrail is using an empty in-memory store. Existing data was left untouched for recovery."
                )
            }
        }
    }

    static var applicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AgentTrail", isDirectory: true)
    }

    static func makeDiskContainer(at url: URL) throws -> ModelContainer {
        let applicationSupport = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationSupport.path)
        return try ModelContainer(
            for: Schema(versionedSchema: AgentTrailSchemaV2.self),
            migrationPlan: AgentTrailMigrationPlan.self,
            configurations: ModelConfiguration(url: url)
        )
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: AgentTrailSchemaV2.self),
            migrationPlan: AgentTrailMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    static func makeEmergencyContainer() -> ModelContainer? {
        try? makeInMemoryContainer()
    }

    /// Best-effort pre-open copy of the store family into a staged backup.
    ///
    /// Call only when this process does not hold the store open. Concurrent
    /// writers (another app instance) or a crash mid-copy can still yield an
    /// inconsistent snapshot — this is not SQLite online backup.
    static func backupStore(at storeURL: URL, supportDirectory: URL, label: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        let backupsURL = supportDirectory.appendingPathComponent("Backups", isDirectory: true)
        try fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupsURL.path)
        let stamp = "\(storeFileName).\(label).\(Int(Date.now.timeIntervalSince1970)).\(UUID().uuidString.lowercased())"
        let backupURL = backupsURL.appendingPathComponent(stamp, isDirectory: true)
        let stagingURL = backupsURL.appendingPathComponent(".\(stamp).staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingURL.path)

        // Coordinated read of the main store; copy store → wal → shm for a
        // best-effort consistent family snapshot while no local connection is open.
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: storeURL, options: [.withoutChanges], error: &coordinationError) { coordinatedURL in
            do {
                var copied = 0
                for url in storeFamily(for: coordinatedURL) where fileManager.fileExists(atPath: url.path) {
                    let destination = stagingURL.appendingPathComponent(url.lastPathComponent)
                    try fileManager.copyItem(at: url, to: destination)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    copied += 1
                }
                guard copied > 0,
                      fileManager.fileExists(atPath: stagingURL.appendingPathComponent(storeFileName).path)
                else {
                    try? fileManager.removeItem(at: stagingURL)
                    throw CocoaError(.fileNoSuchFile)
                }
                try fileManager.moveItem(at: stagingURL, to: backupURL)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        try pruneBackups(in: backupsURL)
    }

    static func pruneBackups(in backupsURL: URL, keeping maximum: Int = maximumBackups) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupsURL.path) else { return }
        let backups = try fileManager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix(storeFileName + ".") }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
        for stale in backups.dropFirst(max(maximum, 0)) {
            try? fileManager.removeItem(at: stale)
        }
    }

    static func restoreLatestBackup(to storeURL: URL, supportDirectory: URL) throws {
        let fileManager = FileManager.default
        let backupsURL = supportDirectory.appendingPathComponent("Backups", isDirectory: true)
        let backups = try fileManager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix(storeFileName + ".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let backup = backups.first else { throw CocoaError(.fileNoSuchFile) }
        let backupStore = backup.appendingPathComponent(storeFileName)
        guard fileManager.fileExists(atPath: backupStore.path) else { throw CocoaError(.fileNoSuchFile) }

        let parent = storeURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".restore-\(UUID().uuidString.lowercased())", isDirectory: true)
        let recoveryURL = supportDirectory.appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent("failed-\(Int(Date.now.timeIntervalSince1970))", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)

        for url in try fileManager.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            try fileManager.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))
        }
        guard fileManager.fileExists(atPath: staging.appendingPathComponent(storeFileName).path) else {
            try? fileManager.removeItem(at: staging)
            throw CocoaError(.fileNoSuchFile)
        }

        try fileManager.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryURL.path)
        for url in storeFamily(for: storeURL) where fileManager.fileExists(atPath: url.path) {
            try fileManager.moveItem(at: url, to: recoveryURL.appendingPathComponent(url.lastPathComponent))
        }
        for url in try fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            try fileManager.moveItem(at: url, to: parent.appendingPathComponent(url.lastPathComponent))
        }
        try? fileManager.removeItem(at: staging)
    }

    static func storeFamily(for url: URL) -> [URL] {
        [url, url.appendingPathExtension("wal"), url.appendingPathExtension("shm")]
    }
}

@main
struct AgentTrailApp: App {
    @State private var appStore: AppStore
    private let modelContainer: ModelContainer?
    private let directories: AgentDirectories
    private let payloadStore: PayloadStore
    private let persistenceMode: PersistenceMode
    private let applicationSupportLease: ApplicationSupportLease?
    private let libraryAccessIssue: LibraryAccessIssue?

    init() {
        let directories = AgentTrailRuntime.directories()
        let payloadStore = AgentTrailRuntime.payloadStore()
        let persistence: AgentTrailPersistenceResult
        let applicationSupportLease: ApplicationSupportLease?
        let libraryAccessIssue: LibraryAccessIssue?

        if AgentTrailRuntime.isTestHost {
            persistence = AgentTrailPersistence.makeContainer(isTestHost: true)
            applicationSupportLease = nil
            libraryAccessIssue = nil
        } else {
            switch ApplicationSupportLease.acquire(in: AgentTrailPersistence.applicationSupportURL) {
            case .acquired(let lease):
                applicationSupportLease = lease
                libraryAccessIssue = nil
                persistence = AgentTrailPersistence.makeContainer(isTestHost: false)
            case .ownedByAnotherProcess(let owner):
                applicationSupportLease = nil
                libraryAccessIssue = .ownedByAnotherProcess(owner)
                persistence = AgentTrailPersistenceResult(
                    container: nil,
                    mode: .unavailable,
                    startupMessage: "Another AgentTrail copy currently owns the local library."
                )
            case .unavailable(let message):
                applicationSupportLease = nil
                libraryAccessIssue = .unavailable(message)
                persistence = AgentTrailPersistenceResult(
                    container: nil,
                    mode: .unavailable,
                    startupMessage: message
                )
            }
        }
        self.directories = directories
        self.payloadStore = payloadStore
        self.modelContainer = persistence.container
        self.persistenceMode = persistence.mode
        self.applicationSupportLease = applicationSupportLease
        self.libraryAccessIssue = libraryAccessIssue
        // Sticky warning for any degraded durable-store outcome so refresh cannot
        // overwrite “you may not be on the primary healthy store” messaging.
        let stickyWarning: String? = {
            switch persistence.mode {
            case .emergencyInMemory, .recoveredFromBackup:
                return persistence.startupMessage
            case .disk, .unavailable:
                return nil
            }
        }()
        let startup: String? = stickyWarning ?? persistence.startupMessage
        _appStore = State(initialValue: AppStore(
            agentDirectories: directories,
            payloadStore: payloadStore,
            startupMessage: startup,
            persistenceWarning: stickyWarning
        ))
    }

    var body: some Scene {
        WindowGroup {
            if let libraryAccessIssue {
                LibraryUnavailableView(issue: libraryAccessIssue)
            } else if let modelContainer {
                RootView()
                    .environment(appStore)
                    .modelContainer(modelContainer)
                    .safeAreaInset(edge: .top) {
                        if let warning = appStore.persistenceWarning {
                            PersistenceWarningBanner(message: warning)
                        }
                    }
            } else {
                PersistenceFailureView(message: appStore.statusMessage)
            }
        }
        .defaultSize(width: 1_240, height: 760)
        .commands {
            AgentTrailCommands()
        }

        Settings {
            if let libraryAccessIssue {
                LibraryUnavailableView(issue: libraryAccessIssue)
                    .frame(minWidth: 440, idealWidth: 520, minHeight: 300, idealHeight: 360)
            } else {
                SettingsView(directories: directories, payloadStore: payloadStore)
                    .frame(minWidth: 440, idealWidth: 520, minHeight: 300, idealHeight: 360)
            }
        }

        liveSessionsExtra
    }

    @SceneBuilder
    private var liveSessionsExtra: some Scene {
        MenuBarExtra(isInserted: .constant(!AgentTrailRuntime.isTestHost)) {
            liveSessionsMenuContent
        } label: {
            liveSessionsStatusLabel
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var liveSessionsMenuContent: some View {
        if AgentTrailRuntime.isTestHost {
            EmptyView()
        } else if let libraryAccessIssue {
            LiveSessionsUnavailableMenu(
                explanation: libraryAccessIssue.menuExplanation,
                onOpen: { appStore.bringMainWindowForward() }
            )
        } else if let modelContainer {
            LiveSessionsMenu(limit: appStore.loadedSessionLimit)
                .environment(appStore)
                .modelContainer(modelContainer)
        } else {
            LiveSessionsUnavailableMenu(
                explanation: appStore.statusMessage,
                onOpen: { appStore.bringMainWindowForward() }
            )
        }
    }

    @ViewBuilder
    private var liveSessionsStatusLabel: some View {
        if AgentTrailRuntime.isTestHost {
            Image(systemName: SessionLiveness.extraSymbolName(liveCount: 0))
                .accessibilityLabel(SessionLiveness.extraAccessibilityLabel(liveCount: 0))
        } else if let modelContainer {
            LiveSessionsStatusLabel(limit: appStore.loadedSessionLimit)
                .environment(appStore)
                .modelContainer(modelContainer)
        } else {
            Image(systemName: SessionLiveness.extraSymbolName(liveCount: 0))
                .accessibilityLabel(SessionLiveness.extraAccessibilityLabel(liveCount: 0))
        }
    }
}

private struct PersistenceWarningBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Storage recovery warning")
        .accessibilityValue(message)
    }
}

private struct PersistenceFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Local storage unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
            Text("Quit and try again after checking the AgentTrail recovery folder in Application Support.")
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
