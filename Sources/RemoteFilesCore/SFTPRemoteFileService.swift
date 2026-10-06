import Foundation
import Citadel
import Crypto
import Logging
import NIOCore
import NIOPosix
import NIOSSH

/// Read-only SFTP adapter. The SSH connection is reused; every operation owns a child
/// SFTP channel, so cancelling it also releases all of its remote file/directory handles.
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
            let groups = try await sftp.listDirectory(atPath: canonical)
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
        try await boundedRead(profile: profile, path: path, allowedRoot: nil, limit: limit)
    }

    public func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data {
        try await boundedRead(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit)
    }

    private func boundedRead(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int) async throws -> Data {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        let started = Date()
        let session = try await session(for: profile)
        let result = try await perform(session: session) { sftp in
            var target = try Self.validated(path)
            if let allowedRoot {
                let root = try await sftp.getRealPath(atPath: Self.validated(allowedRoot))
                target = try await sftp.getRealPath(atPath: target)
                guard RemoteResourcePath.contains(target, in: root) else { throw RemoteDocumentLinkError.outsideConnection }
            }
            let file = try await sftp.openFile(filePath: target, flags: .read)
            do {
                let attributes = try await file.readAttributes()
                let result = try await BoundedPreviewReader.read(initialSize: attributes.size, limit: limit) { offset, amount in
                    try await file.read(from: offset, length: amount)
                }
                try await file.close()
                return result
            } catch {
                // Closing the containing SFTP channel in perform also releases this
                // handle if a failed/cancelled network request prevents SFTP CLOSE.
                throw error
            }
        }
        measurements.fileOperations += 1
        measurements.readRequests += result.1
        measurements.bytesReceived += result.0.count
        measurements.lastReadSeconds = Date().timeIntervalSince(started)
        return result.0
    }

    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                             destination: URL, limit: Int) async throws -> RemoteEntry {
        guard limit > 0, limit < Int.max else { throw RemoteFileError.tooLarge(limit) }
        let session = try await session(for: profile)
        let result = try await perform(session: session, timeout: 180) { sftp in
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
            while true {
                try Task.checkCancellation()
                let amount = min(256 * 1024, limit - count + 1)
                let chunk = try await file.read(from: UInt64(count), length: UInt32(amount))
                if chunk.readableBytes == 0 { break }
                guard chunk.readableBytes <= amount, chunk.readableBytes <= limit - count else { throw RemoteFileError.tooLarge(limit) }
                try handle.write(contentsOf: Data(chunk.readableBytesView))
                count += chunk.readableBytes
            }
            try await file.close()
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

    private func perform<T: Sendable>(session: LiveSession, timeout: UInt64? = nil,
                                     operation: @escaping @Sendable (SFTPClient) async throws -> T) async throws -> T {
        // The dependency's listDirectory leaves its directory handle open. Retiring
        // this operation's SFTP channel fixes that without reconnecting/authenticating.
        let channel = SFTPChannelControl()
        do {
            return try await Self.deadline(seconds: timeout ?? timeoutSeconds, close: {
                channel.close()
                if !channel.hasClient { session.control.close() }
            }) {
                var logger = Logger(label: "RemoteFiles.SFTP")
                logger.logLevel = .error
                let sftp = try await session.client.openSFTP(logger: logger)
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
            if Task.isCancelled { throw CancellationError() }
            if let status = error as? SFTPMessage.Status {
                switch status.errorCode {
                case .permissionDenied:
                    throw RemoteFileError.unavailable("Permission denied. This account cannot read that location on the server.")
                case .noSuchFile:
                    throw RemoteFileError.notFound
                case .noConnection, .connectionLost:
                    throw RemoteFileError.unavailable("The SSH connection ended. Refresh to reconnect.")
                default: break
                }
            }
            throw error
        }
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
    init(profile: ConnectionProfile, client: SSHClient, control: SocketControl) {
        self.profile = profile; self.client = client; self.control = control
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
                     readChunk: @Sendable (UInt64, UInt32) async throws -> ByteBuffer) async throws -> (Data, Int) {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        if let size = initialSize, size > UInt64(limit) { throw RemoteFileError.tooLarge(limit) }
        var bytes = Data()
        bytes.reserveCapacity(min(limit, Int(initialSize ?? 0)))
        var requests = 0
        while true {
            try Task.checkCancellation()
            // Probe one byte past the limit even when the original stat was smaller.
            let amount = min(64 * 1024, limit - bytes.count + 1)
            let chunk = try await readChunk(UInt64(bytes.count), UInt32(amount))
            requests += 1
            if chunk.readableBytes == 0 { return (bytes, requests) }
            guard chunk.readableBytes <= amount, chunk.readableBytes <= limit - bytes.count else {
                throw RemoteFileError.tooLarge(limit)
            }
            bytes.append(contentsOf: chunk.readableBytesView)
        }
    }
}
