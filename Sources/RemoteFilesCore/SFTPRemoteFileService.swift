import Foundation
import Citadel
import Crypto
import Logging
import NIOCore
import NIOPosix
import NIOSSH

/// Read-only SFTP adapter. The SSH connection is reused, and listings, metadata and document
/// reads share one SFTP channel per session. Streaming downloads own a child channel, so
/// cancelling one also releases all of its remote file handles.
public actor SFTPRemoteFileService: RemoteFileService {
    private let identityStore: IdentityStore
    private let trustStore: HostTrustStore
    private let metadataStore: MetadataStore
    private let timeoutSeconds: UInt64
    private var active: LiveSession?
    private var pending: Task<LiveSession, Error>?
    private var pendingProfile: ConnectionProfile?
    private var pendingControl: SocketControl?
    private var generation: UInt64 = 0
    private var measurements = TransportMetrics()

    public init(identityStore: IdentityStore, trustStore: HostTrustStore,
                metadataStore: MetadataStore, timeoutSeconds: UInt64 = 15) {
        self.identityStore = identityStore
        self.trustStore = trustStore
        self.metadataStore = metadataStore
        self.timeoutSeconds = max(1, timeoutSeconds)
    }

    public func metrics() -> TransportMetrics { measurements }

    public func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        let started = Date()
        let session = try await session(for: profile)
        let result = try await perform(session: session) { sftp in
            let canonical = try await sftp.getRealPath(atPath: Self.validated(path))
            let groups = try await sftp.listDirectory(atPath: canonical, resolvingPath: false)
            let entries = groups.flatMap(\.components).filter {
                $0.filename != "." && $0.filename != ".."
            }.map { component in
                Self.entry(name: component.filename,
                           path: RemotePath.appending(component.filename, to: canonical),
                           attributes: component.attributes)
            }
            return DirectorySnapshot(path: canonical, entries: entries)
        }
        measurements.directoryOperations += 1
        measurements.lastDirectorySeconds = Date().timeIntervalSince(started)
        return result
    }

    public func readFile(profile: ConnectionProfile, path: String, limit: Int = 2 * 1024 * 1024) async throws -> Data {
        // Without `since`, bytes are always transferred.
        try await boundedRead(profile: profile, path: path, allowedRoot: nil, limit: limit, since: nil).0 ?? Data()
    }

    public func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data {
        try await boundedRead(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit, since: nil).0 ?? Data()
    }

    public func readFileIfChanged(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int,
                                  since: RemoteFileVersion?) async throws -> RemoteFileRead {
        let (bytes, version) = try await boundedRead(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit, since: since)
        return bytes.map { .contents($0, version) } ?? .unchanged
    }

    /// Returns nil bytes only when `since` matches the current file. Root confinement is
    /// checked before that comparison, so an unchanged answer never skips the boundary.
    private func boundedRead(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int,
                             since: RemoteFileVersion?) async throws -> (Data?, RemoteFileVersion?) {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        let started = Date()
        let session = try await session(for: profile)
        let result = try await perform(session: session) { sftp -> (Data?, RemoteFileVersion?, Int) in
            var target = try Self.validated(path)
            if let allowedRoot {
                let root = try await sftp.getRealPath(atPath: Self.validated(allowedRoot))
                target = try await sftp.getRealPath(atPath: target)
                guard RemoteResourcePath.contains(target, in: root) else { throw RemoteDocumentLinkError.outsideConnection }
            }
            if let since, RemoteFileVersion(attributes: try await sftp.getAttributes(at: target)) == since {
                return (nil, since, 0)
            }
            let file = try await sftp.openFile(filePath: target, flags: .read)
            do {
                // The version is taken before the bytes, so a concurrent write reads as changed next time.
                let attributes = try await file.readAttributes()
                let (bytes, requests) = try await BoundedPreviewReader.read(initialSize: attributes.size, limit: limit) { offset, amount in
                    try await file.read(from: offset, length: amount)
                }
                try await file.close()
                return (bytes, RemoteFileVersion(attributes: attributes), requests)
            } catch {
                // The failure also retires the shared channel, releasing this handle
                // if a failed/cancelled network request prevents SFTP CLOSE.
                try? await file.close()
                throw error
            }
        }
        measurements.fileOperations += 1
        measurements.readRequests += result.2
        measurements.bytesReceived += result.0?.count ?? 0
        measurements.lastReadSeconds = Date().timeIntervalSince(started)
        return (result.0, result.1)
    }

    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                             destination: URL, limit: Int) async throws -> RemoteEntry {
        try await downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit, progress: { _ in })
    }
    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                             destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        guard limit > 0, limit < Int.max else { throw RemoteFileError.tooLarge(limit) }
        let session = try await session(for: profile)
        let result = try await performOnDedicatedChannel(session: session, timeout: 180) { sftp in
            let root = try await sftp.getRealPath(atPath: Self.validated(allowedRoot))
            let canonical = try await sftp.getRealPath(atPath: Self.validated(path))
            guard RemoteResourcePath.contains(canonical, in: root) else { throw RemoteResourceError.outsideDocument }
            let file = try await sftp.openFile(filePath: canonical, flags: .read)
            let attributes = try await file.readAttributes()
            let entry = Self.entry(name: RemotePath.name(of: canonical), path: canonical, attributes: attributes)
            guard entry.kind == .file else { throw RemoteFileError.unsupportedFile }
            if let size = attributes.size, size > UInt64(limit) { throw RemoteFileError.tooLarge(limit) }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var count = 0
            await progress(.init(totalBytes: attributes.size))
            _ = try await BoundedPreviewReader.stream(initialSize: attributes.size, limit: limit, window: 16, readChunk: { offset, amount in
                try await file.read(from: offset, length: amount)
            }) { chunk in
                try handle.write(contentsOf: Data(chunk.readableBytesView))
                count += chunk.readableBytes
                await progress(.init(receivedBytes: UInt64(count), totalBytes: attributes.size))
            }
            try await file.close()
            try Task.checkCancellation()
            await progress(.init(receivedBytes: UInt64(count), totalBytes: UInt64(count), isComplete: true))
            return (entry, count)
        }
        measurements.fileOperations += 1; measurements.bytesReceived += result.1
        return result.0
    }

    /// User-tapped document links are bounded by the connection's canonical starting folder.
    /// Canonicalizing both source and destination also rejects symlinks escaping that root.
    public func resolveDocumentLink(profile: ConnectionProfile, documentPath: String, reference: String) async throws -> RemoteEntry {
        try Task.checkCancellation()
        let session = try await session(for: profile)
        return try await perform(session: session) { sftp in
            let root = try await sftp.getRealPath(atPath: Self.validated(profile.startingDirectory))
            let document = try await sftp.getRealPath(atPath: Self.validated(documentPath))
            guard RemoteResourcePath.contains(document, in: root) else { throw RemoteDocumentLinkError.outsideConnection }
            let requested = try RemoteDocumentLinkPath.resolve(reference, relativeTo: document, connectionRoot: root)
            let canonical = try await sftp.getRealPath(atPath: Self.validated(requested))
            guard RemoteResourcePath.contains(canonical, in: root) else { throw RemoteDocumentLinkError.outsideConnection }
            let attributes = try await sftp.getAttributes(at: canonical)
            let entry = Self.entry(name: RemotePath.name(of: canonical), path: canonical, attributes: attributes)
            guard entry.kind == .file, DocumentPolicy.kind(filename: entry.name) != .unsupported else {
                throw RemoteDocumentLinkError.unsupportedFile
            }
            try Task.checkCancellation()
            return RemoteEntry(name: entry.name, path: entry.path, kind: entry.kind, size: entry.size,
                               modifiedAt: entry.modifiedAt, navigationRoot: root, exportFilename: RemotePath.name(of: requested))
        }
    }

    public func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        let session = try await session(for: profile)
        return try await perform(session: session) { sftp in
            let canonical = try await sftp.getRealPath(atPath: Self.validated(path))
            let attributes = try await sftp.getAttributes(at: canonical)
            return Self.entry(name: RemotePath.name(of: canonical), path: canonical, attributes: attributes)
        }
    }

    public func disconnect() async {
        generation &+= 1
        pending?.cancel()
        pendingControl?.close()
        pending = nil
        pendingControl = nil
        pendingProfile = nil
        let old = active
        active = nil
        old?.control.close()
        await identityStore.clearSession()
    }

    private func session(for profile: ConnectionProfile) async throws -> LiveSession {
        try Task.checkCancellation()
        guard (1...65535).contains(profile.port),
              !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.host.contains("\0"), !profile.username.isEmpty else {
            throw RemoteFileError.unavailable("Enter a valid hostname, username, and port from 1 to 65535.")
        }
        if let active, active.profile == profile, !active.control.isCancelled, active.client.isConnected { return active }
        if let pending, pendingProfile == profile, !pending.isCancelled {
            let joinedGeneration = generation
            let joinedControl = pendingControl
            let session = try await withTaskCancellationHandler { try await pending.value } onCancel: {
                pending.cancel()
                joinedControl?.close()
            }
            guard generation == joinedGeneration, !Task.isCancelled else { throw CancellationError() }
            return session
        }
        // Retire a previous endpoint without clearing an identity the UI has just
        // unlocked for this attempt. Explicit disconnect/backgrounding clears it.
        generation &+= 1
        pending?.cancel()
        pendingControl?.close()
        active?.control.close()
        active = nil
        pending = nil
        pendingProfile = nil
        pendingControl = nil
        let requestGeneration = generation
        let control = SocketControl()
        let identityStore = self.identityStore
        let metadataStore = self.metadataStore
        let trustStore = self.trustStore
        let timeout = timeoutSeconds
        let started = Date()
        let task = Task<LiveSession, Error> {
            let metadata = try await metadataStore.identity(id: profile.identityID)
            let privateKey = try await identityStore.unlock(metadata)
            return try await Self.deadline(seconds: timeout, close: { control.close() }) {
                try Task.checkCancellation()
                var settings = SSHClientSettings(
                    host: profile.host, port: profile.port,
                    authenticationMethod: { .ed25519(username: profile.username, privateKey: privateKey) },
                    hostKeyValidator: .custom(TrustValidator(store: trustStore,
                                                            endpoint: HostEndpoint(host: profile.host, port: profile.port)))
                )
                settings.connectTimeout = .seconds(Int64(timeout))
                // NIOSSH sizes each channel's receive window to this value. Its 128 KiB default
                // capped transfers near 64 KiB per round trip regardless of pipelined reads.
                settings.protocolOptions = [.maximumPacketSize(1 << 21)]
                settings.onChannelCreated = { control.install($0) }
                do {
                    try Task.checkCancellation()
                    let client = try await SSHClient.connect(to: settings)
                    try Task.checkCancellation()
                    return LiveSession(profile: profile, client: client, control: control)
                } catch {
                    control.close()
                    throw error
                }
            }
        }
        pending = task
        pendingProfile = profile
        pendingControl = control
        do {
            let session = try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel()
                control.close()
            }
            guard generation == requestGeneration, !Task.isCancelled else {
                control.close()
                throw CancellationError()
            }
            active = session
            pending = nil; pendingProfile = nil; pendingControl = nil
            measurements.connections += 1
            measurements.lastConnectionSeconds = Date().timeIntervalSince(started)
            return session
        } catch {
            control.close()
            if generation == requestGeneration {
                pending = nil; pendingProfile = nil; pendingControl = nil
            }
            if Task.isCancelled { throw CancellationError() }
            if error is NIOConnectionError {
                throw RemoteFileError.unavailable("Couldn't connect to this server. Check its address and network. For local Wi-Fi, allow RemoteFiles in iPhone Settings → Privacy & Security → Local Network, then try again.")
            }
            throw error
        }
    }

    /// Short operations share the session's SFTP channel, saving the channel-open, subsystem and
    /// version round trips on every tap. A cancelled caller returns at once while its operation
    /// drains the in-flight request. Any failure retires the channel once its other users finish,
    /// so an interrupted operation cannot leave a handle open on a reused channel.
    private func perform<T: Sendable>(session: LiveSession,
                                     operation: @escaping @Sendable (SFTPClient) async throws -> T) async throws -> T {
        let channel = SFTPChannelControl()
        do {
            return try await Self.detachedDeadline(seconds: timeoutSeconds, onTimeout: {
                channel.close()
                if !channel.hasClient { session.control.close() }
            }) {
                let shared = try await self.acquireSFTP(for: session)
                channel.install(shared.client)
                do {
                    try Task.checkCancellation()
                    let value = try await operation(shared.client)
                    await self.release(shared, from: session, reusable: true)
                    return value
                } catch {
                    await self.release(shared, from: session, reusable: false)
                    throw error
                }
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Streaming transfers own a child SFTP channel. Cancelling or timing out closes it, releasing
    /// its handles without delaying browsing requests queued behind bulk reads.
    private func performOnDedicatedChannel<T: Sendable>(session: LiveSession, timeout: UInt64,
                                                        operation: @escaping @Sendable (SFTPClient) async throws -> T) async throws -> T {
        let channel = SFTPChannelControl()
        measurements.sftpChannels += 1
        do {
            return try await Self.deadline(seconds: timeout, close: {
                channel.close()
                if !channel.hasClient { session.control.close() }
            }) {
                let sftp = try await session.client.openSFTP(logger: Self.sftpLogger())
                channel.install(sftp)
                do {
                    try Task.checkCancellation()
                    let value = try await operation(sftp)
                    try await sftp.close()
                    return value
                } catch {
                    try? await sftp.close()
                    throw error
                }
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    private func acquireSFTP(for session: LiveSession) async throws -> SharedSFTPChannel {
        if let shared = session.sftp {
            if !shared.retired, shared.client.isActive { shared.users += 1; return shared }
            retire(shared, from: session)
        }
        let opening: Task<SharedSFTPChannel, Error>
        if let pending = session.openingSFTP {
            opening = pending
        } else {
            let client = session.client
            opening = Task { SharedSFTPChannel(client: try await client.openSFTP(logger: Self.sftpLogger())) }
            session.openingSFTP = opening
            measurements.sftpChannels += 1
        }
        let shared: SharedSFTPChannel
        do {
            shared = try await opening.value
        } catch {
            if session.openingSFTP == opening { session.openingSFTP = nil }
            throw error
        }
        if session.openingSFTP == opening { session.openingSFTP = nil; session.sftp = shared }
        // Another waiter may have failed on this channel and retired it while this one resumed.
        guard !shared.retired else { return try await acquireSFTP(for: session) }
        shared.users += 1
        return shared
    }

    private func release(_ shared: SharedSFTPChannel, from session: LiveSession, reusable: Bool) {
        shared.users -= 1
        if !reusable { retire(shared, from: session) } else if shared.retired, shared.users == 0 { shared.close() }
    }

    private func retire(_ shared: SharedSFTPChannel, from session: LiveSession) {
        shared.retired = true
        if session.sftp === shared { session.sftp = nil }
        if shared.users == 0 { shared.close() }
    }

    private nonisolated static func sftpLogger() -> Logger {
        var logger = Logger(label: "RemoteFiles.SFTP")
        logger.logLevel = .error
        return logger
    }

    /// Call from the failing caller's task: cancellation is read from that task.
    private nonisolated static func mapped(_ error: Error) -> Error {
        if Task.isCancelled { return CancellationError() }
        if let status = error as? SFTPMessage.Status {
            switch status.errorCode {
            case .permissionDenied:
                return RemoteFileError.unavailable("Permission denied. This account cannot read that location on the server.")
            case .noSuchFile:
                return RemoteFileError.notFound
            case .noConnection, .connectionLost:
                return RemoteFileError.unavailable("The SSH connection ended. Refresh to reconnect.")
            default: break
            }
        }
        return error
    }

    private nonisolated static func validated(_ path: String) throws -> String {
        guard !path.contains("\0") else { throw RemoteFileError.invalidPath }
        return path.isEmpty ? "." : path
    }

    private nonisolated static func entry(name: String, path: String, attributes: SFTPFileAttributes) -> RemoteEntry {
        let kind: RemoteEntry.Kind
        switch (attributes.permissions ?? 0) & 0o170000 {
        case 0o040000: kind = .directory
        case 0o100000: kind = .file
        case 0o120000: kind = .symlink
        default: kind = .other
        }
        return RemoteEntry(name: name, path: path, kind: kind, size: attributes.size,
                           modifiedAt: attributes.accessModificationTime?.modificationTime)
    }

    /// Runs `operation` in its own task so a cancelled caller need not wait for a request the
    /// transport cannot interrupt. The deadline still fires `onTimeout` for an unresponsive server.
    nonisolated static func detachedDeadline<T: Sendable>(seconds: UInt64,
                                                          onTimeout: @escaping @Sendable () -> Void,
                                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome = FirstOutcome<T>()
        let work = Task { try await operation() }
        Task { outcome.resolve(await work.result) }
        let timer = Task {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if outcome.resolve(.failure(RemoteFileError.timedOut)) { onTimeout(); work.cancel() }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { outcome.install($0) }
        } onCancel: {
            work.cancel()
            outcome.resolve(.failure(CancellationError()))
        }
    }

    nonisolated static func deadline<T: Sendable>(seconds: UInt64,
                                                         close: @escaping @Sendable () -> Void,
                                                         operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let deadline = DeadlineFlag()
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try await operation() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                        deadline.expire()
                        close()
                        throw RemoteFileError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if deadline.expired { throw RemoteFileError.timedOut }
                throw error
            }
        } onCancel: { close() }
    }
}

public struct TransportMetrics: Sendable {
    public fileprivate(set) var connections = 0
    public fileprivate(set) var sftpChannels = 0
    public fileprivate(set) var directoryOperations = 0
    public fileprivate(set) var fileOperations = 0
    public fileprivate(set) var readRequests = 0
    public fileprivate(set) var bytesReceived = 0
    public fileprivate(set) var lastConnectionSeconds: TimeInterval = 0
    public fileprivate(set) var lastDirectorySeconds: TimeInterval = 0
    public fileprivate(set) var lastReadSeconds: TimeInterval = 0
}

private final class LiveSession: @unchecked Sendable {
    let profile: ConnectionProfile
    let client: SSHClient
    let control: SocketControl
    // Actor-isolated to SFTPRemoteFileService; closing the SSH socket also closes this channel.
    var sftp: SharedSFTPChannel?
    var openingSFTP: Task<SharedSFTPChannel, Error>?
    init(profile: ConnectionProfile, client: SSHClient, control: SocketControl) {
        self.profile = profile; self.client = client; self.control = control
    }
}

/// The session's reusable SFTP channel. Mutable state is actor-isolated to SFTPRemoteFileService.
private final class SharedSFTPChannel: @unchecked Sendable {
    let client: SFTPClient
    var users = 0
    var retired = false
    init(client: SFTPClient) { self.client = client }
    func close() {
        let client = client
        Task { try? await client.close() }
    }
}

private extension RemoteFileVersion {
    init?(attributes: SFTPFileAttributes) {
        self.init(size: attributes.size, modifiedAt: attributes.accessModificationTime?.modificationTime)
    }
}

struct TrustValidator: NIOSSHClientServerAuthenticationDelegate {
    let store: HostTrustStore
    let endpoint: HostEndpoint
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // The event loop receives a promise immediately. Key lookup never blocks it,
        // and unknown/changed keys fail before NIOSSH can offer user authentication.
        validationCompletePromise.completeWithTask {
            try await store.validate(endpoint: endpoint, publicKey: hostKey)
        }
    }
}

final class SocketControl: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func install(_ channel: Channel) {
        lock.lock()
        let shouldClose = cancelled
        if !shouldClose { self.channel = channel }
        lock.unlock()
        if shouldClose { channel.close(promise: nil) }
    }
    func close() {
        lock.lock()
        cancelled = true
        let old = channel
        channel = nil
        lock.unlock()
        old?.close(promise: nil)
    }
}

private final class SFTPChannelControl: @unchecked Sendable {
    private let lock = NSLock()
    private var client: SFTPClient?
    private var cancelled = false
    var hasClient: Bool { lock.lock(); defer { lock.unlock() }; return client != nil }
    func install(_ client: SFTPClient) {
        lock.lock()
        let shouldClose = cancelled
        self.client = client
        lock.unlock()
        if shouldClose { Task { try? await client.close() } }
    }
    func close() {
        lock.lock()
        cancelled = true
        let old = client
        lock.unlock()
        if let old { Task { try? await old.close() } }
    }
}

/// Delivers whichever comes first: the operation's result, its deadline, or caller cancellation.
private final class FirstOutcome<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        guard let result else { self.continuation = continuation; lock.unlock(); return }
        lock.unlock()
        continuation.resume(with: result)
    }
    @discardableResult func resolve(_ value: Result<T, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: value)
        return true
    }
}

private final class DeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func expire() { lock.lock(); value = true; lock.unlock() }
}

/// Shared receive-time bound, independent of the server's initial size hint.
/// Kept internal so controlled chunks can exercise growth and short-read behavior.
enum BoundedPreviewReader {
    static func read(initialSize: UInt64?, limit: Int,
                     readChunk: @escaping @Sendable (UInt64, UInt32) async throws -> ByteBuffer) async throws -> (Data, Int) {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        var bytes = Data()
        bytes.reserveCapacity(min(limit, Int(clamping: initialSize ?? 0)))
        let result = try await stream(initialSize: initialSize, limit: limit, readChunk: readChunk) { chunk in
            bytes.append(contentsOf: chunk.readableBytesView)
        }
        return (bytes, result.requests)
    }

    /// Keeps up to `window` reads in flight so throughput is not capped at one chunk per round
    /// trip, and hands bytes to `consume` strictly in file order. A short read is not EOF: its gap
    /// is requested as soon as it arrives, and once a filled gap confirms the server's maximum read
    /// size, later requests use it. Requests never extend more than one probe byte past `limit`.
    static func stream(initialSize: UInt64?, limit: Int, chunkSize: Int = 64 * 1024, window: Int = 8,
                       readChunk: @escaping @Sendable (UInt64, UInt32) async throws -> ByteBuffer,
                       consume: (ByteBuffer) async throws -> Void) async throws -> (bytes: Int, requests: Int) {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        if let size = initialSize, size > UInt64(limit) { throw RemoteFileError.tooLarge(limit) }
        struct Request { let offset: Int; let amount: Int; let fillsShortRead: Int? }
        return try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { group in
            var issued: [Int: Request] = [:]
            var order: [Int] = []       // Unconsumed request IDs by ascending offset.
            var received: [Int: ByteBuffer] = [:]
            var nextID = 0, nextOffset = 0, inFlight = 0, consumed = 0
            var endOfFile = Int.max     // Lowest offset already answered with EOF.
            var chunk = max(1, chunkSize)
            func issue(_ request: Request, at position: Int) {
                let id = nextID
                nextID += 1; inFlight += 1
                issued[id] = request
                order.insert(id, at: position)
                group.addTask { (id, try await readChunk(UInt64(request.offset), UInt32(request.amount))) }
            }
            while true {
                try Task.checkCancellation()
                while inFlight < max(1, window), nextOffset <= limit, nextOffset < endOfFile {
                    let amount = min(chunk, limit - nextOffset + 1)
                    issue(Request(offset: nextOffset, amount: amount, fillsShortRead: nil), at: order.endIndex)
                    nextOffset += amount
                }
                // Every byte through the probe was requested and accepted: only growth gets here.
                guard let (id, buffer) = try await group.next() else { throw RemoteFileError.tooLarge(limit) }
                inFlight -= 1
                received[id] = buffer
                let request = issued[id]!
                if buffer.readableBytes == 0 {
                    endOfFile = min(endOfFile, request.offset)
                } else if buffer.readableBytes < request.amount {
                    // A filled gap proves the earlier short read was the server's maximum, not EOF.
                    if let short = request.fillsShortRead { chunk = min(chunk, max(short, 4 * 1024)) }
                    var offset = request.offset + buffer.readableBytes
                    var position = order.firstIndex(of: id)! + 1
                    while offset < request.offset + request.amount {
                        let amount = min(chunk, request.offset + request.amount - offset)
                        issue(Request(offset: offset, amount: amount, fillsShortRead: buffer.readableBytes), at: position)
                        offset += amount; position += 1
                    }
                } else if let short = request.fillsShortRead {
                    chunk = min(chunk, max(short, 4 * 1024))
                }
                while let head = order.first, let buffer = received.removeValue(forKey: head) {
                    order.removeFirst()
                    let request = issued.removeValue(forKey: head)!
                    if buffer.readableBytes == 0 {
                        group.cancelAll()
                        return (consumed, nextID)
                    }
                    guard buffer.readableBytes <= request.amount, buffer.readableBytes <= limit - consumed else {
                        throw RemoteFileError.tooLarge(limit)
                    }
                    try await consume(buffer)
                    consumed += buffer.readableBytes
                }
            }
        }
    }
}
