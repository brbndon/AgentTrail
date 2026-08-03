import CoreServices
import Foundation
import os

/// Bridges FSEvents into a debounced callback without polling watched folders.
/// Stream state and callback generation are serialized so callbacks from a
/// stopped or replaced stream cannot refresh a newer watcher.
final class FSEventWatcher {
    private final class CallbackGate: @unchecked Sendable {
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var active = false

        func begin() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            active = true
            return generation
        }

        func invalidate() {
            lock.lock()
            generation &+= 1
            active = false
            lock.unlock()
        }

        func accepts(_ callbackGeneration: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return active && generation == callbackGeneration
        }
    }

    private final class CallbackBox: @unchecked Sendable {
        let gate: CallbackGate
        let handler: @Sendable () -> Void

        init(gate: CallbackGate, handler: @escaping @Sendable () -> Void) {
            self.gate = gate
            self.handler = handler
        }
    }

    private final class StreamCallbackContext {
        let box: CallbackBox
        let generation: UInt64

        init(box: CallbackBox, generation: UInt64) {
            self.box = box
            self.generation = generation
        }
    }

    private let callbackGate = CallbackGate()
    private let callbackBox: CallbackBox
    private let queue = DispatchQueue(label: "com.brandon.AgentTrail.fsevents", qos: .utility)
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.brandon.AgentTrail", category: "fsevents")
    private var watchedPaths: [URL]
    private var stream: FSEventStreamRef?
    private var streamStarted = false
    private var contextPointer: UnsafeMutablePointer<FSEventStreamContext>?

    init(paths: [URL], handler: @escaping @Sendable () -> Void) {
        watchedPaths = Self.normalized(paths)
        callbackBox = CallbackBox(gate: callbackGate, handler: handler)
    }

    /// Starts watching the current path set. Calling this more than once is safe.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return streamStarted }
        return createStreamLocked()
    }

    /// Replaces the watched roots, preserving the current running state.
    func update(paths: [URL]) {
        lock.lock()
        let wasRunning = streamStarted
        if stream != nil { disposeStreamLocked(callStop: streamStarted) }
        watchedPaths = Self.normalized(paths)
        if wasRunning { _ = createStreamLocked() }
        lock.unlock()
    }

    /// Stops and releases the underlying FSEventStream.
    func stop() {
        lock.lock()
        if stream != nil { disposeStreamLocked(callStop: streamStarted) }
        callbackGate.invalidate()
        lock.unlock()
    }

    deinit {
        stop()
    }

    private func createStreamLocked() -> Bool {
        guard !watchedPaths.isEmpty else {
            logger.debug("No filesystem paths are available to watch")
            return false
        }
        let paths = watchedPaths.map(\.path) as CFArray
        let generation = callbackGate.begin()
        let callbackContext = StreamCallbackContext(box: callbackBox, generation: generation)
        let callbackInfo = Unmanaged.passRetained(callbackContext).toOpaque()
        contextPointer = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        contextPointer?.initialize(to: FSEventStreamContext(
            version: 0,
            info: callbackInfo,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<StreamCallbackContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        ))

        guard let contextPointer,
              let newStream = FSEventStreamCreate(
                nil,
                Self.eventCallback,
                contextPointer,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.35,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
              )
        else {
            logger.error("Unable to create the FSEventStream")
            Unmanaged<StreamCallbackContext>.fromOpaque(callbackInfo).release()
            contextPointer?.deinitialize(count: 1)
            contextPointer?.deallocate()
            self.contextPointer = nil
            callbackGate.invalidate()
            return false
        }

        stream = newStream
        streamStarted = false
        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            logger.error("Unable to start the FSEventStream")
            // FSEventStreamStop is only valid after a successful start.
            disposeStreamLocked(callStop: false)
            callbackGate.invalidate()
            return false
        }
        streamStarted = true
        return true
    }

    private func disposeStreamLocked(callStop: Bool) {
        guard let stream else { return }
        if callStop { FSEventStreamStop(stream) }
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        streamStarted = false
        contextPointer?.deinitialize(count: 1)
        contextPointer?.deallocate()
        contextPointer = nil
        callbackGate.invalidate()
    }

    private static let eventCallback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
        guard let clientCallBackInfo else { return }
        let context = Unmanaged<StreamCallbackContext>
            .fromOpaque(clientCallBackInfo)
            .takeUnretainedValue()
        // The stream context keeps the gate alive through the watcher, and the
        // generation check rejects callbacks queued before stop/update.
        guard context.box.gate.accepts(context.generation) else { return }
        context.box.handler()
    }

    private static func normalized(_ paths: [URL]) -> [URL] {
        var seen = Set<String>()
        return paths.compactMap { url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }.sorted { $0.path < $1.path }
    }
}
