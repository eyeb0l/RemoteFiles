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
public actor SFTPRemoteFileService: RemoteFileService, ProgressiveFolderListing, FolderWalking, BackgroundFolderListing, ServerFolderSearching, RemoteFileSessionClosing, ResumableManagedDownloading {
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
    /// Managed transfers fail after this long without receiving file bytes.
    private var managedTransferIdle: Duration = .seconds(60)
    /// How long a dedicated transfer may take to drain after its channel was asked to close
    /// before the connection's socket is closed too. See `performOnDedicatedChannel`.
    private var dedicatedCloseGrace: Duration = .seconds(5)
    /// How often a transfer reports its progress. Its start, first bytes and end always report.
    private var progressInterval: Duration = .milliseconds(100)
    private var transferWindowLimit = transferReadWindowLimit
    private var transferWindowFloor = transferReadWindow

    public init(identityStore: IdentityStore, trustStore: HostTrustStore,
                metadataStore: MetadataStore, timeoutSeconds: UInt64 = 15) {
        self.identityStore = identityStore
        self.trustStore = trustStore
        self.metadataStore = metadataStore
        self.timeoutSeconds = max(1, timeoutSeconds)
    }

    public func metrics() -> TransportMetrics { measurements }

    /// Shortens transfer timings so tests need not wait the production intervals.
    func setTransferTimings(idle: Duration, closeGrace: Duration) {
        managedTransferIdle = idle; dedicatedCloseGrace = closeGrace
    }
    func setProgressInterval(_ interval: Duration) { progressInterval = interval }
    /// Lets a benchmark compare fixed and growing read windows in one process.
    func setTransferWindow(floor: Int, limit: Int) { transferWindowFloor = floor; transferWindowLimit = limit }

    func searchFolders(query: String, root: String, profile: ConnectionProfile, includeHidden: Bool,
                       limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?,
                       partial: @escaping @Sendable (RemoteFolderSearch.Update) -> Void) async throws -> RemoteFolderSearch.Update? {
        do {
            _ = try ServerFolderSearch.command(query: query, root: root, includeHidden: includeHidden,
                                                     limits: limits, content: content)
        } catch ServerFolderSearch.Failure.unsupported { return nil }
        let session = try await session(for: profile)
        guard !session.serverSearchUnavailable else { return nil }
        measurements.serverSearchAttempts += 1
        do {
            let timeout = UInt64(limits.timeLimit.components.seconds + 1) + timeoutSeconds
            let (update, bytes) = try await performOnDedicatedChannel(session: session, timeout: timeout, closesInBackground: true) { sftp in
                let identity = try await Self.searchIdentity(root: root, sftp: sftp)
                // The root stays held until the helper has finished with it.
                defer { _ = identity.directory.sendClose() }
                let command = try ServerFolderSearch.command(query: query, root: root, includeHidden: includeHidden,
                    limits: limits, content: content, identity: identity.value)
                let decoder = ServerFolderSearch.OutputDecoder(query: query, root: root, includeHidden: includeHidden, limits: limits, content: content)
                return try await Self.streamSearchCommand(client: session.client, command: command, timeout: timeout, decoder: decoder, partial: partial)
            }
            try Task.checkCancellation()
            guard session.client.isConnected else { throw RemoteFileError.connectionEnded }
            measurements.bytesReceived += bytes
            measurements.serverSearchOperations += 1
            return update
        } catch {
            try Task.checkCancellation()
            guard session.client.isConnected else { throw RemoteFileError.connectionEnded }
            // Failed capability checks are remembered only for this authenticated session.
            // Connection loss, deadlines and trust errors are never disguised as unsupported search.
            switch error {
            case let failure as SearchRootFailure:
                throw Self.mapped(failure.underlying) // About this folder, not about what the server can do.
            case ServerFolderSearch.Failure.resourceLimit, CitadelError.commandOutputTooLarge:
                return nil // A narrower subsequent search can still use this capable server.
            case is ServerFolderSearch.Failure, is SSHClient.CommandFailed, is TTYSTDError:
                session.serverSearchUnavailable = true
                return nil
            case let error as NIOSSHError where error.type == .channelSetupRejected:
                session.serverSearchUnavailable = true
                return nil
            case let status as SFTPMessage.Status where status.errorCode == .failure || status.errorCode == .unsupportedOperation:
                session.serverSearchUnavailable = true
                return nil
            case RemoteFileError.notFound, RemoteFileError.permissionDenied, RemoteFileError.unsupportedFile:
                // No accessible procfs/descriptor capability: retain the ordinary SFTP search.
                session.serverSearchUnavailable = true
                return nil
            default: throw Self.mapped(error)
            }
        }
    }

    nonisolated static func searchProcessPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0].isEmpty && parts[1] == "proc"
            && !parts[2].isEmpty && parts[2].allSatisfy { $0.isASCII && $0.isNumber }
            && Int(parts[2]).map { $0 > 0 } == true
    }

    nonisolated static func searchRootHandle(process: String, root: String, before: [String: String],
                                             after: [String: String]) throws -> String {
        let added = after.filter { before[$0.key] == nil }
        guard searchProcessPath(process), added.count == 1, let descriptor = added.first,
              !descriptor.key.isEmpty, descriptor.key.allSatisfy({ $0.isASCII && $0.isNumber }),
              descriptor.value.utf8.elementsEqual(root.utf8) else { throw ServerFolderSearch.Failure.unsupported }
        return process + "/fd/" + descriptor.key
    }

    /// Descriptors looked for around the search root's OPEN, by number. The kernel gives out the lowest free
    /// number, so a server with more than this many open can't show a new one and falls back to the walk.
    static let searchDescriptorScan = 32

    /// Canonical strings alone cannot bind SFTP and exec namespaces. This private channel opens the search
    /// root and holds it, which pins its inode, and reads the kernel's mount and inode for that descriptor
    /// through its own procfs entries, so the helper can check it is looking at the same directory.
    ///
    /// Requests go together wherever nothing depends on an earlier answer: four round trips, where asking in
    /// turn took about thirty. Answers are still judged in the order that makes them safe, and a server that
    /// answers out of order can only fail the "one new descriptor" check, which falls back to the walk.
    nonisolated private static func searchIdentity(root: String, sftp: SFTPClient) async throws
        -> (value: ServerFolderSearch.RootIdentity, directory: SFTPFile) {
        let rootPath = sftp.sendRealPath(atPath: try validated(root))
        let processPath = sftp.sendRealPath(atPath: "/proc/self")
        do {
            guard try await rootPath.get().utf8.elementsEqual(root.utf8) else { throw RemoteDocumentLinkError.outsideConnection }
        } catch { throw SearchRootFailure(underlying: error) }
        let process = try await processPath.get()
        guard searchProcessPath(process) else { throw ServerFolderSearch.Failure.unsupported }
        // The scans sit either side of OPEN, so the only descriptor that can appear between them is the root's.
        let namespace = sftp.sendReadSymbolicLink(atPath: process + "/ns/mnt")
        let scan = { (0..<searchDescriptorScan).map { ("\($0)", sftp.sendReadSymbolicLink(atPath: process + "/fd/\($0)")) } }
        let scanBefore = scan()
        let opening = sftp.sendOpenFile(filePath: root, flags: .read)
        let scanAfter = scan()
        let directory = try await opening.get()
        do {
            let mountNamespace = try await namespace.get()
            let handle = try searchRootHandle(process: process, root: root, before: await searchDescriptors(scanBefore),
                                              after: await searchDescriptors(scanAfter))
            // READLINK proved the descriptor is live; REALPATH must agree on where it leads.
            let target = sftp.sendRealPath(atPath: handle)
            let openingInfo = sftp.sendOpenFile(filePath: handle.replacingOccurrences(of: "/fd/", with: "/fdinfo/"), flags: .read)
            guard try await target.get().utf8.elementsEqual(root.utf8) else { throw ServerFolderSearch.Failure.unsupported }
            let info = try await openingInfo.get()
            defer { _ = info.sendClose() }
            // One read. The helper compares these numbers with the kernel's, so a shorter answer can't pass.
            let bytes = try await info.read(from: 0, length: 4_096)
            let identity = try ServerFolderSearch.RootIdentity(fdinfo: String(buffer: bytes), namespace: mountNamespace)
            return (identity, directory)
        } catch {
            _ = directory.sendClose()
            throw error
        }
    }

    /// Open file descriptors and where they lead. Pipes and sockets have no path, so they can't be a root.
    nonisolated private static func searchDescriptors(_ scan: [(String, EventLoopFuture<String>)]) async throws -> [String: String] {
        var descriptors: [String: String] = [:]
        for (number, link) in scan {
            do {
                let target = try await link.get()
                if target.hasPrefix("/") { descriptors[number] = target }
            } catch {
                switch mapped(error) {
                case RemoteFileError.notFound, RemoteFileError.permissionDenied: continue // Not open, or not ours to see.
                case let mapped: throw mapped
                }
            }
        }
        return descriptors
    }

    /// Hands the helper's results on as they arrive. Decoding and matching happen here, off the actor and
    /// the event loop, so neither browsing nor the channel waits for them. At the match limit it stops listening,
    /// which ends the helper the next time it writes.
    nonisolated private static func streamSearchCommand(client: SSHClient, command: String, timeout: UInt64,
                                                        decoder: ServerFolderSearch.OutputDecoder,
                                                        partial: @escaping @Sendable (RemoteFolderSearch.Update) -> Void) async throws -> (RemoteFolderSearch.Update, Int) {
        // Unbuffered in effect: the whole output is capped by `outputLimit`, however fast it comes.
        let (chunks, sink) = AsyncStream.makeStream(of: ByteBuffer.self)
        let execution = Task {
            defer { sink.finish() }
            _ = try await executeSearchCommand(client: client, command: command, timeout: timeout, onOutput: { sink.yield($0) })
        }
        return try await withTaskCancellationHandler {
            var decoder = decoder, bytes = 0
            do {
                for await chunk in chunks {
                    bytes += chunk.readableBytes
                    for update in try decoder.consume(chunk.readableBytesView) { partial(update) }
                    if decoder.isAtMatchLimit {
                        execution.cancel()
                        return (try decoder.finish(), bytes)
                    }
                }
                // Exit status, stderr, overflow and deadlines all surface here.
                try await execution.value
                return (try decoder.finish(), bytes)
            } catch {
                execution.cancel()
                throw error
            }
        } onCancel: { execution.cancel() }
    }

    /// A peer can defer acknowledging channel close until its process exits. Return cancellation
    /// and deadlines immediately while the owned child drains; late-created channels close too.
    /// With `onOutput`, standard output goes there as it arrives instead of into the result.
    nonisolated static func executeSearchCommand(client: SSHClient, command: String, timeout: UInt64,
                                                 maxResponseSize: Int = ServerFolderSearch.outputLimit,
                                                 onOutput: (@Sendable (ByteBuffer) -> Void)? = nil,
                                                 onChannelCreated: @escaping @Sendable () -> Void = {}) async throws -> ByteBuffer {
        let control = SocketControl()
        return try await withTaskCancellationHandler {
            defer { control.close() }
            return try await detachedDeadline(seconds: timeout, onTimeout: { control.close() }) {
                try Task.checkCancellation()
                return try await client.executeBoundedCommand(command, maxResponseSize: maxResponseSize, onOutput: onOutput, onChannelCreated: {
                    control.install($0); onChannelCreated()
                })
            }
        } onCancel: { control.close() }
    }

    /// Most READDIR requests a listing keeps in flight. OpenSSH answers up to 100 names each, so a
    /// folder of up to 1,600 names takes one round trip of reads and a larger one keeps the sequential
    /// server busy across a cellular round trip.
    static let directoryReadWindow = 16
    /// A walk lists many small folders at once, so each sends fewer surplus requests.
    static let walkReadWindow = 8
    /// Entries a listing may hold before it fails. A folder's rows take roughly 200 bytes an entry,
    /// so even a full listing stays far below what the system allows the app.
    static let directoryEntryLimit = 250_000
    /// Decoded names, longnames and attributes that the same listing may hold in total.
    static let directoryMetadataLimit = 128 * 1024 * 1024
    /// Symbolic links resolved per listing; later links stay unresolved and resolve when tapped.
    static let linkResolutionLimit = 256
    /// Links resolved at once, each sending REALPATH and STAT together. Enough for the whole of
    /// `linkResolutionLimit` to go in one round trip, which the server then answers at its own pace.
    static let linkResolutionWindow = 128
    /// Time after which no new link lookups start, keeping best-effort resolution well inside the
    /// listing's deadline on slow connections. Lookups already sent still finish.
    static let linkResolutionBudget: Duration = .seconds(3)

    public func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        try await listDirectory(profile: profile, path: path, partial: nil, resolvesLinks: true, role: .foreground)
    }

    public func listDirectory(profile: ConnectionProfile, path: String,
                              partial: @escaping @Sendable (DirectorySnapshot) -> Void) async throws -> DirectorySnapshot {
        try await listDirectory(profile: profile, path: path, partial: partial, resolvesLinks: true, role: .foreground)
    }

    /// A folder search only needs names and kinds, and it asks only about the few links that match.
    func listDirectoryForWalk(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        try await listDirectory(profile: profile, path: path, partial: nil, resolvesLinks: false, role: .walk)
    }

    func resolvingLinks(in entries: [RemoteEntry], profile: ConnectionProfile) async throws -> [RemoteEntry] {
        guard entries.contains(where: { $0.kind == .symlink }) else { return entries }
        let session = try await session(for: profile)
        return try await perform(session: session) { sftp, _ in
            try await Self.resolvingLinks(in: entries) { await Self.linkResolution(for: $0, sftp: sftp) }
        }
    }

    private func listDirectory(profile: ConnectionProfile, path: String, partial: (@Sendable (DirectorySnapshot) -> Void)?,
                               resolvesLinks: Bool, role: SFTPChannelRole) async throws -> DirectorySnapshot {
        let started = Date()
        let session = try await session(for: profile)
        // A very large folder may take longer than one deadline: it runs out only when replies stop.
        let progress = DeadlineExtension()
        let result = try await perform(session: session, role: role, progress: progress) { sftp, closes in
            try await Self.snapshot(path, sftp: sftp, readWindow: role == .walk ? Self.walkReadWindow : Self.directoryReadWindow,
                                    progress: progress, closes: closes, partial: partial, resolvesLinks: resolvesLinks)
        }
        measurements.directoryOperations += 1
        measurements.lastDirectorySeconds = Date().timeIntervalSince(started)
        return result
    }

    /// Lists a folder on the walk channel, only over a session already open for this exact profile.
    /// It never connects, unlocks a key or replaces another server's session, and a failure or slow
    /// disk on the server can't retire or queue behind the channel foreground browsing uses. Opening
    /// a channel per folder took three round trips more each time.
    public func listDirectoryInBackground(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot? {
        try Task.checkCancellation()
        guard let session = active, session.profile == profile, !session.control.isCancelled, session.client.isConnected else { return nil }
        return try await perform(session: session, role: .walk) { sftp, closes in
            try await Self.snapshot(path, sftp: sftp, readWindow: Self.walkReadWindow, progress: nil, closes: closes, partial: nil, resolvesLinks: true)
        }
    }

    /// Names are ready after two round trips: REALPATH and OPENDIR together, then the READDIRs. With
    /// `closes`, the listing returns without waiting a third for CLOSE, whose reply is checked afterwards.
    /// `partial` receives what has arrived so far before links are resolved, each time with more entries.
    private nonisolated static func snapshot(_ path: String, sftp: SFTPClient, readWindow: Int, progress: DeadlineExtension?, closes: DeferredCloses?,
                                             partial: (@Sendable (DirectorySnapshot) -> Void)?, resolvesLinks: Bool) async throws -> DirectorySnapshot {
        let requested = try validated(path)
        // The server resolves both requests from the same path. If REALPATH fails, the listing still
        // drains and closes its handle.
        let resolved = sftp.sendRealPath(atPath: requested)
        let collected = CollectedEntries()
        let listed: Result<Void, Error>
        do {
            _ = try await sftp.listDirectory(atPath: requested, resolvingPath: false, concurrentReads: readWindow,
                                             maximumEntries: directoryEntryLimit, maximumMetadataBytes: directoryMetadataLimit,
                                             onBatch: { components in
                progress?.record()
                let canonical = try await resolved.get()
                let entries = collected.add(components, in: canonical)
                if let partial { partial(DirectorySnapshot(path: canonical, entries: entries)) }
            }, deferringClose: closes.map { closes in { closes.add($0) } })
            listed = .success(())
        } catch {
            listed = .failure(error)
        }
        let canonical = try await resolved.get()
        try listed.get()
        let entries = collected.entries
        guard resolvesLinks else { return DirectorySnapshot(path: canonical, entries: entries) }
        let linked = try await resolvingLinks(in: entries) { await linkResolution(for: $0, sftp: sftp) }
        return DirectorySnapshot(path: canonical, entries: linked)
    }

    /// Resolves symbolic links so their rows can show and open the target directly. Each link sends
    /// REALPATH and STAT together and links resolve in parallel, so a folder of links costs about one
    /// more round trip. A failed lookup leaves that link unresolved rather than failing the listing.
    /// Cancellation and the time budget stop new lookups; the remaining links resolve when tapped.
    nonisolated static func resolvingLinks(in entries: [RemoteEntry], budget: Duration = linkResolutionBudget,
                                           resolve: @escaping @Sendable (RemoteEntry) async -> LinkResolution?) async throws -> [RemoteEntry] {
        let deadline = ContinuousClock.now + budget
        var pending = entries.indices.filter { entries[$0].kind == .symlink }.prefix(linkResolutionLimit).makeIterator()
        var resolved = entries
        try await withThrowingTaskGroup(of: (Int, LinkResolution?).self) { group in
            func startNext() {
                // Lookups ignore cancellation once sent, so an abandoned or slow listing must stop adding them.
                guard ContinuousClock.now < deadline, !Task.isCancelled, let index = pending.next() else { return }
                let link = entries[index]
                _ = group.addTaskUnlessCancelled { (index, await resolve(link)) }
            }
            for _ in 0..<linkResolutionWindow { startNext() }
            while let (index, link) = try await group.next() {
                let entry = entries[index]
                if let link {
                    resolved[index] = RemoteEntry(name: entry.name, path: entry.path, kind: entry.kind, size: entry.size,
                                                  modifiedAt: entry.modifiedAt, link: link)
                }
                startNext()
            }
        }
        try Task.checkCancellation()
        return resolved
    }

    private nonisolated static func linkResolution(for link: RemoteEntry, sftp: SFTPClient) async -> LinkResolution? {
        let canonical = sftp.sendRealPath(atPath: link.path)
        let attributes = sftp.sendAttributes(at: link.path)
        // Wait for both answers: this returns normally on failure, and a request left unanswered must
        // stay under the listing's deadline. REALPATH's error still comes first.
        let stat: Result<SFTPFileAttributes, Error>
        do { stat = .success(try await attributes.get()) } catch { stat = .failure(error) }
        do {
            let path = try await canonical.get(), target = try stat.get()
            return .target(entry(name: RemotePath.name(of: path), path: path, attributes: target))
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile || status.errorCode == .failure {
            // A missing target, or a loop, which OpenSSH reports as a generic failure.
            return .broken
        } catch {
            // Permission errors, cancellation and transport failures leave the link to resolve on tap.
            return nil
        }
    }

    public func readFile(profile: ConnectionProfile, path: String, limit: Int = 2 * 1024 * 1024) async throws -> Data {
        // Without `since`, bytes are always transferred.
        try await boundedRead(profile: profile, path: path, allowedRoot: nil, limit: limit, since: nil).0 ?? Data()
    }

    public func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data {
        try await boundedRead(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit, since: nil).0 ?? Data()
    }

    public func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        // On the walk's channel, so many reads at once can't queue ahead of browsing or retire its channel.
        try await boundedRead(profile: profile, path: path, allowedRoot: canonicalRoot, limit: limit,
                              since: nil, requiresCanonicalRoot: true, role: .walk).0 ?? Data()
    }

    public func readFileIfChanged(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int,
                                  since: RemoteFileVersion?) async throws -> RemoteFileRead {
        let (bytes, version) = try await boundedRead(profile: profile, path: path, allowedRoot: allowedRoot, limit: limit, since: since)
        return bytes.map { .contents($0, version) } ?? .unchanged
    }

    /// Returns nil bytes only when `since` matches the current file. Root confinement is
    /// checked before that comparison, so an unchanged answer never skips the boundary.
    private func boundedRead(profile: ConnectionProfile, path: String, allowedRoot: String?, limit: Int,
                             since: RemoteFileVersion?, requiresCanonicalRoot: Bool = false, role: SFTPChannelRole = .foreground) async throws -> (Data?, RemoteFileVersion?) {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        let started = Date()
        let session = try await session(for: profile)
        let result = try await perform(session: session, role: role) { sftp, closes -> (Data?, RemoteFileVersion?, Int) in
            var target = try Self.validated(path)
            var canonicalRoot: String?
            // Whatever can be answered together goes together. Each answer is still judged in the order
            // that makes it safe: root confinement before a version match, so an unchanged answer never
            // skips the boundary.
            let currentAttributes: EventLoopFuture<SFTPFileAttributes>?
            if let allowedRoot {
                let rootPath = sftp.sendRealPath(atPath: try Self.validated(allowedRoot))
                let targetPath = sftp.sendRealPath(atPath: target)
                currentAttributes = since == nil ? nil : sftp.sendAttributes(at: target)
                let root = try await rootPath.get()
                if requiresCanonicalRoot, !root.utf8.elementsEqual(allowedRoot.utf8) { throw RemoteDocumentLinkError.outsideConnection }
                target = try await targetPath.get()
                guard RemoteResourcePath.contains(target, in: root) else { throw RemoteDocumentLinkError.outsideConnection }
                canonicalRoot = root
            } else {
                currentAttributes = since == nil ? nil : sftp.sendAttributes(at: target)
            }
            if let since, let currentAttributes, RemoteFileVersion(attributes: try await currentAttributes.get()) == since {
                return (nil, since, 0)
            }
            // The handle and the size come back together. The size only shapes the reads, so that a small
            // file needs one of them rather than a second to find out where it ended.
            let opening = sftp.sendOpenFile(filePath: target, flags: .read)
            let expected = sftp.sendAttributes(at: target)
            let file = try await opening.get()
            do {
                // The version comes from the handle and is taken before the bytes, so a concurrent
                // write reads as changed next time.
                let attributes: SFTPFileAttributes
                let handleAttributes: EventLoopFuture<SFTPFileAttributes>
                if let canonicalRoot {
                    // SFTP v3 has no portable openat/no-follow operation. Re-resolving both
                    // paths after OPEN catches stable namespace replacement before bytes move;
                    // the server must still provide a jail or immutable root for an atomic boundary.
                    let rootCheck = sftp.sendRealPath(atPath: canonicalRoot)
                    let targetCheck = sftp.sendRealPath(atPath: target)
                    handleAttributes = file.sendReadAttributes()
                    let currentRoot = try await rootCheck.get()
                    let currentTarget = try await targetCheck.get()
                    guard currentRoot.utf8.elementsEqual(canonicalRoot.utf8),
                          currentTarget.utf8.elementsEqual(target.utf8),
                          RemoteResourcePath.contains(currentTarget, in: currentRoot) else {
                        throw RemoteDocumentLinkError.outsideConnection
                    }
                } else {
                    handleAttributes = file.sendReadAttributes()
                }
                let hint = try? await expected.get()
                let (bytes, requests) = try await BoundedPreviewReader.read(initialSize: hint?.size, limit: limit,
                    window: hint?.size == nil ? 8 : Self.previewReadWindow) { offset, amount in
                    try await file.read(from: offset, length: amount)
                }
                attributes = try await handleAttributes.get()
                if let size = attributes.size, size > UInt64(limit) { throw RemoteFileError.tooLarge(limit) }
                closes.add(file.sendClose())
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
        try await download(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination,
                           limit: limit, progress: progress, canonicalPaths: false)
    }
    public func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String,
                                     destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await download(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination,
                           limit: limit, progress: progress, canonicalPaths: true)
    }
    public func downloadManagedFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                                    destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await download(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination,
                           limit: limit, progress: progress, canonicalPaths: false, managed: true)
    }
    public func downloadManagedSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String,
                                            destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await download(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination,
                           limit: limit, progress: progress, canonicalPaths: true, managed: true)
    }
    public func downloadManagedFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int,
                                    resumeVersion: RemoteFileVersion?, started: @escaping ManagedDownloadStartHandler,
                                    progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await download(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit,
                           progress: progress, canonicalPaths: false, managed: true, resumeVersion: resumeVersion, started: started)
    }
    public func downloadManagedSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL, limit: Int,
                                            resumeVersion: RemoteFileVersion?, started: @escaping ManagedDownloadStartHandler,
                                            progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await download(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination, limit: limit,
                           progress: progress, canonicalPaths: true, managed: true, resumeVersion: resumeVersion, started: started)
    }
    /// Reads a preview keeps in flight. A foreground read has nothing to wait behind on its channel, and
    /// knowing the size means none of them is wasted, so a preview of 2 MiB takes one round trip.
    static let previewReadWindow = 32
    /// Reads a transfer starts with, and the most it grows to on a fast, distant connection.
    static let transferReadWindow = 16
    static let transferReadWindowLimit = 64
    /// Bytes just before a resume offset that must still match the server's copy.
    static let resumeOverlapBytes = 64 * 1024
    private func download(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL,
                          limit: Int, progress: @escaping DownloadProgressHandler, canonicalPaths: Bool,
                          managed: Bool = false, resumeVersion: RemoteFileVersion? = nil,
                          started: @escaping ManagedDownloadStartHandler = { _, _ in }) async throws -> RemoteEntry {
        guard limit > 0, limit < Int.max else { throw RemoteFileError.tooLarge(limit) }
        let session = try await session(for: profile)
        let reportInterval = progressInterval, windowLimit = transferWindowLimit, windowFloor = transferWindowFloor
        let result = try await performOnDedicatedChannel(session: session, budget: managed ? .idle(managedTransferIdle) : .total(180)) { sftp, activity in
            let rootPath = sftp.sendRealPath(atPath: try Self.validated(allowedRoot))
            let targetPath = sftp.sendRealPath(atPath: try Self.validated(path))
            let root = try await rootPath.get()
            let canonical = try await targetPath.get()
            if canonicalPaths {
                guard root.utf8.elementsEqual(allowedRoot.utf8), canonical.utf8.elementsEqual(path.utf8) else {
                    throw RemoteDocumentLinkError.outsideConnection
                }
            }
            guard RemoteResourcePath.contains(canonical, in: root) else { throw RemoteResourceError.outsideDocument }
            let file = try await sftp.openFile(filePath: canonical, flags: .read)
            do {
                // This post-OPEN stability check catches durable path replacement before
                // publication. Atomic confinement still requires a server-side jail or helper.
                let rootCheck = sftp.sendRealPath(atPath: root)
                let targetCheck = sftp.sendRealPath(atPath: canonical)
                let handleAttributes = file.sendReadAttributes()
                let currentRoot = try await rootCheck.get()
                let currentTarget = try await targetCheck.get()
                guard currentRoot.utf8.elementsEqual(root.utf8),
                      currentTarget.utf8.elementsEqual(canonical.utf8),
                      RemoteResourcePath.contains(currentTarget, in: currentRoot) else {
                    throw RemoteResourceError.outsideDocument
                }
                let attributes = try await handleAttributes.get()
                let entry = Self.entry(name: RemotePath.name(of: canonical), path: canonical, attributes: attributes)
                guard entry.kind == .file else { throw RemoteFileError.unsupportedFile }
                if let size = attributes.size, size > UInt64(limit) { throw RemoteFileError.tooLarge(limit) }
                let version = RemoteFileVersion(size: attributes.size, modifiedAt: entry.modifiedAt)
                var start = 0
                if let resumeVersion, resumeVersion == version {
                    start = try await Self.resumableOffset(destination: destination, size: resumeVersion.size, limit: limit) { offset, amount in
                        let bytes = try await file.read(from: offset, length: amount)
                        activity.receivedBytes(bytes.readableBytes)
                        return bytes
                    }
                }
                let handle: FileHandle
                if start > 0 {
                    handle = try FileHandle(forWritingTo: destination)
                    try handle.truncate(atOffset: UInt64(start))
                    try handle.seekToEnd()
                } else {
                    FileManager.default.createFile(atPath: destination.path, contents: nil)
                    handle = try FileHandle(forWritingTo: destination)
                }
                defer { try? handle.close() }
                // The caller records the version before any byte of it reaches the destination.
                await started(version, UInt64(start))
                try Task.checkCancellation()
                var count = start
                await progress(.init(receivedBytes: UInt64(start), totalBytes: attributes.size))
                var lastReport: ContinuousClock.Instant?
                var window = WindowSample()
                _ = try await BoundedPreviewReader.stream(initialSize: attributes.size, limit: limit, startOffset: start, window: windowFloor,
                                                          windowLimit: windowLimit, observe: { window.add(window: $0, inFlight: $1) }, readChunk: { offset, amount in
                    let bytes = try await file.read(from: offset, length: amount)
                    activity.receivedBytes(bytes.readableBytes)
                    return bytes
                }) { chunk in
                    try handle.write(contentsOf: Data(chunk.readableBytesView))
                    count += chunk.readableBytes
                    // At full speed this would be thousands of main-actor updates a second, each
                    // invalidating every view that shows a transfer. The first bytes always show.
                    let now = ContinuousClock.now
                    if lastReport.map({ $0.duration(to: now) >= reportInterval }) ?? true {
                        lastReport = now
                        await progress(.init(receivedBytes: UInt64(count), totalBytes: attributes.size))
                    }
                }
                try await file.close()
                try Task.checkCancellation()
                await progress(.init(receivedBytes: UInt64(count), totalBytes: UInt64(count), isComplete: true))
                return (entry, count - start, window)
            } catch {
                try? await file.close()
                throw error
            }
        }
        measurements.fileOperations += 1; measurements.bytesReceived += result.1
        measurements.lastTransferPeakWindow = result.2.peak; measurements.lastTransferMeanInFlight = result.2.meanInFlight
        return result.0
    }

    /// The local length a transfer may continue from, or zero. The partial file must be a
    /// regular file no longer than the remote file or the limit, and its final bytes (up to
    /// `resumeOverlapBytes`) must equal the server's bytes at the same offsets. Size and
    /// modification time alone miss a same-length rewrite within one timestamp tick.
    static func resumableOffset(destination: URL, size: UInt64, limit: Int,
                                readChunk: (UInt64, UInt32) async throws -> ByteBuffer) async throws -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let length = (attributes[.size] as? NSNumber)?.uint64Value,
              length > 0, length <= size, length <= UInt64(limit) else { return 0 }
        let overlap = Int(min(length, UInt64(resumeOverlapBytes)))
        let overlapStart = length - UInt64(overlap)
        guard let reader = try? FileHandle(forReadingFrom: destination) else { return 0 }
        defer { try? reader.close() }
        guard (try? reader.seek(toOffset: overlapStart)) != nil,
              let local = try? reader.read(upToCount: overlap), local.count == overlap else { return 0 }
        var remote = Data()
        while remote.count < overlap {
            let bytes = try await readChunk(overlapStart + UInt64(remote.count), UInt32(overlap - remote.count))
            guard bytes.readableBytes > 0, bytes.readableBytes <= overlap - remote.count else { return 0 }
            remote.append(contentsOf: bytes.readableBytesView)
        }
        return remote == local ? Int(length) : 0
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
        closeTransport()
        await identityStore.clearSession()
    }

    /// A completed foreground download releases its socket without locking keys used
    /// by browsing or subsequent user-initiated downloads in the same app session.
    public func closeSessionPreservingUnlockedIdentities() { closeTransport() }

    private func closeTransport() {
        generation &+= 1
        pending?.cancel()
        pendingControl?.close()
        pending = nil
        pendingControl = nil
        pendingProfile = nil
        let old = active
        active = nil
        old?.control.close()
    }

    private func session(for profile: ConnectionProfile) async throws -> LiveSession {
        try Task.checkCancellation()
        guard profile.hasValidSSHEndpoints else {
            throw RemoteFileError.unavailable("Enter a valid hostname, username, and port from 1 to 65535 for both endpoints.")
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
            // Unlock both keys before opening sockets. Each error carries the identity needing UI.
            func key(_ id: UUID) async throws -> IdentityPrivateKey {
                let metadata = try await metadataStore.identity(id: id)
                do { return try await identityStore.unlock(metadata) }
                catch IdentityError.missingPassphrase { throw ConnectionIdentityUnlockRequired(identity: metadata) }
            }
            let jumpKey: IdentityPrivateKey?
            if let hop = profile.jumpHost { jumpKey = try await key(hop.identityID) } else { jumpKey = nil }
            let privateKey = try await key(profile.identityID)
            return try await Self.deadline(seconds: timeout, close: { control.close() }) {
                func settings(host: String, port: Int, username: String, key: IdentityPrivateKey) -> SSHClientSettings {
                    var value = SSHClientSettings(
                        host: host, port: port,
                        authenticationMethod: { key.authentication(username: username) },
                        hostKeyValidator: .custom(TrustValidator(store: trustStore, endpoint: HostEndpoint(host: host, port: port)))
                    )
                    value.connectTimeout = .seconds(Int64(timeout))
                    // NIOSSH also uses this as its receive window, which has to hold a full transfer window.
                    value.protocolOptions = [.maximumPacketSize(1 << 23)]
                    value.onChannelCreated = { control.install($0) }
                    return value
                }
                do {
                    try Task.checkCancellation()
                    let destination = settings(host: profile.host, port: profile.port, username: profile.username, key: privateKey)
                    let client: SSHClient
                    var bastion: SSHClient?
                    if let hop = profile.jumpHost, let jumpKey {
                        let jump = try await SSHClient.connect(to: settings(host: hop.host, port: hop.port, username: hop.username, key: jumpKey))
                        bastion = jump
                        try Task.checkCancellation()
                        client = try await jump.jump(to: destination)
                    } else {
                        client = try await SSHClient.connect(to: destination)
                    }
                    try Task.checkCancellation()
                    return LiveSession(profile: profile, client: client, control: control, bastion: bastion)
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
            switch error {
            case SSHClientError.allAuthenticationOptionsFailed, SSHClientError.unsupportedPrivateKeyAuthentication,
                 is AuthenticationFailed, CitadelError.unauthorized:
                throw RemoteFileError.authenticationFailed
            default: break
            }
            if profile.jumpHost != nil, let sshError = error as? NIOSSHError, sshError.type == .channelSetupRejected {
                throw RemoteFileError.unavailable("The jump host couldn't reach the destination. Check its hostname and port, and that the jump host permits TCP forwarding to it.")
            }
            if error is NIOConnectionError {
                throw RemoteFileError.unavailable("Couldn't connect to this server. Check its address and network. For local Wi-Fi, allow RemoteFiles in Settings → Privacy & Security → Local Network, then try again.")
            }
            throw error
        }
    }

    /// Short operations share the session's SFTP channel, saving the channel-open, subsystem and
    /// version round trips on every tap. A cancelled caller returns at once while its operation
    /// drains the in-flight request. Any failure retires the channel once its other users finish,
    /// so an interrupted operation cannot leave a handle open on a reused channel.
    ///
    /// A deadline marks the channel closing before the timeout is reported, so no later operation
    /// reuses it: the timed-out work holds the channel until the server confirms the close or TCP
    /// drops, and the half-closed channel would fail the next request.
    ///
    /// An operation that has what its caller needs can leave its handles closing in `DeferredCloses`
    /// rather than wait a round trip for the replies. The channel stays in use until they arrive, and
    /// a failed close retires it just as a failed operation would. A close still unanswered after a
    /// full deadline closes the channel, which also ends anything else outstanding on it.
    private func perform<T: Sendable>(session: LiveSession, role: SFTPChannelRole = .foreground, progress: DeadlineExtension? = nil,
                                      operation: @escaping @Sendable (SFTPClient, DeferredCloses) async throws -> T) async throws -> T {
        let channel = SFTPChannelControl()
        do {
            return try await Self.detachedDeadline(seconds: timeoutSeconds, extending: progress, onTimeout: {
                channel.close()
                if !channel.hasClient { session.control.close() }
            }) {
                let shared = try await self.acquireSFTP(for: session, role: role)
                channel.install(shared.client, closing: shared.closing)
                let closes = DeferredCloses()
                do {
                    try Task.checkCancellation()
                    let value = try await operation(shared.client, closes)
                    let pending = closes.take()
                    if pending.isEmpty {
                        await self.release(shared, from: session, reusable: true)
                    } else {
                        Task { await self.release(shared, from: session, reusable: await self.settle(pending, on: shared)) }
                    }
                    return value
                } catch {
                    let pending = closes.take()
                    if pending.isEmpty {
                        await self.release(shared, from: session, reusable: false)
                    } else {
                        Task { _ = await self.settle(pending, on: shared); await self.release(shared, from: session, reusable: false) }
                    }
                    throw error
                }
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    private func settle(_ pending: [EventLoopFuture<Void>], on shared: SharedSFTPChannel) async -> Bool {
        await DeferredCloses.succeeded(pending, within: .seconds(Int64(timeoutSeconds))) {
            // Marked first, so that nothing reuses a channel being closed.
            shared.closing.set()
            shared.close()
        }
    }

    private func perform<T: Sendable>(session: LiveSession,
                                      operation: @escaping @Sendable (SFTPClient) async throws -> T) async throws -> T {
        try await perform(session: session, progress: nil) { sftp, _ in try await operation(sftp) }
    }

    /// Streaming transfers own a child SFTP channel. Cancelling or timing out closes it, releasing
    /// its handles without delaying browsing requests queued behind bulk reads.
    private func performOnDedicatedChannel<T: Sendable>(session: LiveSession, timeout: UInt64, closesInBackground: Bool = false,
                                                        operation: @escaping @Sendable (SFTPClient) async throws -> T) async throws -> T {
        try await performOnDedicatedChannel(session: session, budget: .total(timeout), closesInBackground: closesInBackground) { sftp, _ in
            try await operation(sftp)
        }
    }

    private enum DedicatedChannelBudget { case total(UInt64), idle(Duration) }

    /// `closesInBackground` returns as soon as the operation has what its caller needs, instead of waiting a
    /// round trip for the channel to close. Only for work that leaves nothing behind that a later write could hit.
    private func performOnDedicatedChannel<T: Sendable>(session: LiveSession, budget: DedicatedChannelBudget, closesInBackground: Bool = false,
        operation: @escaping @Sendable (SFTPClient, TransferActivity) async throws -> T) async throws -> T {
        let channel = SFTPChannelControl()
        measurements.sftpChannels += 1
        let drained = LockedFlag(), grace = dedicatedCloseGrace
        // The caller waits for `work` to drain, so a late write cannot follow a cancelled or
        // expired transfer. Closing the SFTP channel needs the server's reply, which never
        // arrives over a dead network, and the drain would then wait for TCP to give up or the
        // network to return. If the channel has not drained within the grace period, close the
        // socket: pending requests then fail locally and the caller sees the outcome.
        let close: @Sendable () -> Void = {
            channel.close()
            guard channel.hasClient else { session.control.close(); return }
            Task {
                try? await Task.sleep(for: grace)
                if !drained.isSet { session.control.close() }
            }
        }
        let work: @Sendable (TransferActivity) async throws -> T = { activity in
            defer { drained.set() }
            let sftp = try await session.client.openSFTP(logger: Self.sftpLogger())
            channel.install(sftp)
            do {
                try Task.checkCancellation()
                let value = try await operation(sftp, activity)
                if closesInBackground { Task { try? await sftp.close() } } else { try await sftp.close() }
                return value
            } catch {
                if closesInBackground { Task { try? await sftp.close() } } else { try? await sftp.close() }
                throw error
            }
        }
        do {
            switch budget {
            case .total(let seconds):
                return try await Self.deadline(seconds: seconds, close: close) { try await work(.ignored) }
            case .idle(let interval):
                return try await TransferIdleDeadline.run(idle: interval, clock: ContinuousClock(), close: close, operation: work)
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    private func acquireSFTP(for session: LiveSession, role: SFTPChannelRole = .foreground) async throws -> SharedSFTPChannel {
        if let shared = session.sftp[role] {
            if !shared.retired, !shared.closing.isSet, shared.client.isActive { shared.users += 1; return shared }
            retire(shared, from: session)
        }
        let opening: Task<SharedSFTPChannel, Error>
        if let pending = session.openingSFTP[role] {
            opening = pending
        } else {
            let client = session.client
            opening = Task { SharedSFTPChannel(client: try await client.openSFTP(logger: Self.sftpLogger()), role: role) }
            session.openingSFTP[role] = opening
            measurements.sftpChannels += 1
        }
        let shared: SharedSFTPChannel
        do {
            shared = try await opening.value
        } catch {
            if session.openingSFTP[role] == opening { session.openingSFTP[role] = nil }
            // A server allowing few channels may refuse a second one. A walk then shares the first.
            if role == .walk, let refusal = error as? NIOSSHError, refusal.type == .channelSetupRejected {
                return try await acquireSFTP(for: session, role: .foreground)
            }
            throw error
        }
        if session.openingSFTP[role] == opening { session.openingSFTP[role] = nil; session.sftp[role] = shared }
        // Another waiter may have failed on this channel and retired it while this one resumed.
        guard !shared.retired else { return try await acquireSFTP(for: session, role: role) }
        shared.users += 1
        return shared
    }

    private func release(_ shared: SharedSFTPChannel, from session: LiveSession, reusable: Bool) {
        shared.users -= 1
        if !reusable { retire(shared, from: session) } else if shared.retired, shared.users == 0 { shared.close() }
    }

    private func retire(_ shared: SharedSFTPChannel, from session: LiveSession) {
        shared.retired = true
        if session.sftp[shared.role] === shared { session.sftp[shared.role] = nil }
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
                return RemoteFileError.permissionDenied
            case .noSuchFile:
                return RemoteFileError.notFound
            case .noConnection, .connectionLost:
                return connectionEnded
            default: break
            }
        }
        return endsConnection(error) ? connectionEnded : error
    }

    private static let connectionEnded = RemoteFileError.connectionEnded

    /// Errors NIO, NIOSSH and Citadel raise once the SSH connection or its SFTP channel has closed.
    private nonisolated static func endsConnection(_ error: Error) -> Bool {
        switch error {
        case ChannelError.alreadyClosed, ChannelError.outputClosed, ChannelError.ioOnClosedChannel, ChannelError.eof,
             SFTPError.connectionClosed:
            return true
        case let error as NIOSSHError:
            return error.type == .tcpShutdown
        default:
            return false
        }
    }

    private nonisolated static func validated(_ path: String) throws -> String {
        guard !path.contains("\0") else { throw RemoteFileError.invalidPath }
        return path.isEmpty ? "." : path
    }

    nonisolated static func entry(name: String, path: String, attributes: SFTPFileAttributes) -> RemoteEntry {
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
    /// transport cannot interrupt. The deadline outlives the caller: it runs until the operation
    /// itself finishes, so an unanswered request still fires `onTimeout` and releases its channel.
    /// `onTimeout` runs before the caller sees the timeout, and once it has run the result is
    /// `timedOut` even if the work fails first because of what `onTimeout` closed.
    nonisolated static func detachedDeadline<T: Sendable>(seconds: UInt64, extending progress: DeadlineExtension? = nil,
                                                          onTimeout: @escaping @Sendable () -> Void,
                                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome = FirstOutcome<T>()
        let finished = LockedFlag()
        let fired = LockedFlag()
        let work = Task { try await operation() }
        let timer = Task {
            let interval = Duration.seconds(Int64(seconds))
            var deadline = ContinuousClock.now + interval
            while true {
                try await Task.sleep(until: deadline, clock: .continuous)
                guard let latest = progress?.latest, latest + interval > ContinuousClock.now else { break }
                deadline = latest + interval
            }
            guard !finished.isSet else { return }
            fired.set()
            onTimeout(); work.cancel()
            outcome.resolve(.failure(RemoteFileError.timedOut))
        }
        Task {
            let result = await work.result
            finished.set(); timer.cancel()
            outcome.resolve(fired.isSet ? .failure(RemoteFileError.timedOut) : result)
        }
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
        let deadline = LockedFlag()
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: T.self) { group in
                    group.addTask { try await operation() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                        deadline.set()
                        close()
                        throw RemoteFileError.timedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if deadline.isSet { throw RemoteFileError.timedOut }
                throw error
            }
        } onCancel: { close() }
    }
}

/// Keeps an operation's deadline from expiring while it is still receiving what it asked for.
/// The search root itself failed: the error belongs to the caller, and says nothing about server search.
private struct SearchRootFailure: Error { let underlying: Error }

final class DeadlineExtension: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ContinuousClock.Instant?
    var latest: ContinuousClock.Instant? { lock.lock(); defer { lock.unlock() }; return last }
    func record() { let now = ContinuousClock.now; lock.lock(); last = now; lock.unlock() }
}

/// Handles an operation has asked the server to close without waiting for its replies.
final class DeferredCloses: @unchecked Sendable {
    private let lock = NSLock()
    private var futures: [EventLoopFuture<Void>] = []
    func add(_ future: EventLoopFuture<Void>) { lock.lock(); futures.append(future); lock.unlock() }
    func take() -> [EventLoopFuture<Void>] {
        lock.lock(); defer { lock.unlock() }
        let taken = futures
        futures = []
        return taken
    }
    /// Whether every close succeeded. Replies can't be cancelled, so `onTimeout` must make them fail by
    /// closing what they are waiting on. Anything that outlasted `limit` counts as failed.
    static func succeeded(_ futures: [EventLoopFuture<Void>], within limit: Duration,
                          onTimeout: @escaping @Sendable () -> Void) async -> Bool {
        let fired = LockedFlag()
        let watchdog = Task {
            try await Task.sleep(for: limit)
            fired.set()
            onTimeout()
        }
        var succeeded = true
        for future in futures where (try? await future.get()) == nil { succeeded = false }
        watchdog.cancel()
        return succeeded && !fired.isSet
    }
}

/// Maps a listing's batches to entries as they arrive, and keeps them.
private final class CollectedEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [RemoteEntry] = []
    private var prefix: String?
    var entries: [RemoteEntry] { lock.lock(); defer { lock.unlock() }; return collected }
    /// Returns everything so far. Batches arrive one at a time, in the order the server gave them.
    func add(_ components: [SFTPPathComponent], in canonical: String) -> [RemoteEntry] {
        lock.lock(); defer { lock.unlock() }
        let prefix = self.prefix ?? RemotePath.childPrefix(of: canonical)
        self.prefix = prefix
        for component in components where component.filename != "." && component.filename != ".." {
            collected.append(SFTPRemoteFileService.entry(name: component.filename, path: prefix + component.filename, attributes: component.attributes))
        }
        return collected
    }
}

public struct TransportMetrics: Sendable {
    public fileprivate(set) var serverSearchAttempts = 0
    public fileprivate(set) var serverSearchOperations = 0
    public fileprivate(set) var connections = 0
    public fileprivate(set) var sftpChannels = 0
    public fileprivate(set) var directoryOperations = 0
    public fileprivate(set) var fileOperations = 0
    public fileprivate(set) var readRequests = 0
    public fileprivate(set) var bytesReceived = 0
    public fileprivate(set) var lastConnectionSeconds: TimeInterval = 0
    public fileprivate(set) var lastDirectorySeconds: TimeInterval = 0
    public fileprivate(set) var lastReadSeconds: TimeInterval = 0
    /// The largest read window the last download reached, and the reads it had in flight on average when one returned.
    public fileprivate(set) var lastTransferPeakWindow = 0
    public fileprivate(set) var lastTransferMeanInFlight: Double = 0
}

private struct WindowSample {
    private(set) var peak = 0
    private var inFlightTotal = 0, samples = 0
    var meanInFlight: Double { samples == 0 ? 0 : Double(inFlightTotal) / Double(samples) }
    mutating func add(window: Int, inFlight: Int) { peak = max(peak, window); inFlightTotal += inFlight; samples += 1 }
}

private final class LiveSession: @unchecked Sendable {
    let profile: ConnectionProfile
    let client: SSHClient
    let control: SocketControl
    let bastion: SSHClient?
    // Actor-isolated to SFTPRemoteFileService; closing the SSH socket also closes these channels.
    var sftp: [SFTPChannelRole: SharedSFTPChannel] = [:]
    var openingSFTP: [SFTPChannelRole: Task<SharedSFTPChannel, Error>] = [:]
    var serverSearchUnavailable = false
    init(profile: ConnectionProfile, client: SSHClient, control: SocketControl, bastion: SSHClient? = nil) {
        self.profile = profile; self.client = client; self.control = control; self.bastion = bastion
    }
}

/// A walk over many folders has a channel of its own. OpenSSH runs one server process per channel,
/// answering in turn, so this keeps a folder someone taps from queueing behind the walk's listings,
/// and a stalled walk from retiring the channel everything else is using.
private enum SFTPChannelRole: Hashable, Sendable { case foreground, walk }

/// One of the session's reusable SFTP channels. Mutable state is actor-isolated to SFTPRemoteFileService.
private final class SharedSFTPChannel: @unchecked Sendable {
    let client: SFTPClient
    let role: SFTPChannelRole
    /// Set from a deadline outside the actor, before the timeout is reported.
    let closing = LockedFlag()
    var users = 0
    var retired = false
    init(client: SFTPClient, role: SFTPChannelRole) { self.client = client; self.role = role }
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
    private var channels: [Channel] = []
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func install(_ channel: Channel) {
        lock.lock()
        let shouldClose = cancelled
        if !shouldClose { channels.append(channel) }
        lock.unlock()
        if shouldClose { channel.close(promise: nil) }
    }
    func close() {
        lock.lock()
        cancelled = true
        let old = channels
        channels.removeAll()
        lock.unlock()
        for channel in old.reversed() { channel.close(promise: nil) }
    }
}

private final class SFTPChannelControl: @unchecked Sendable {
    private let lock = NSLock()
    private var client: SFTPClient?
    private var closing: LockedFlag?
    private var cancelled = false
    var hasClient: Bool { lock.lock(); defer { lock.unlock() }; return client != nil }
    /// `closing` is set synchronously on close, before the asynchronous channel close begins.
    func install(_ client: SFTPClient, closing: LockedFlag? = nil) {
        lock.lock()
        let shouldClose = cancelled
        self.client = client
        self.closing = closing
        lock.unlock()
        if shouldClose { closing?.set(); Task { try? await client.close() } }
    }
    func close() {
        lock.lock()
        cancelled = true
        let old = client
        let closing = closing
        lock.unlock()
        closing?.set()
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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Grows a transfer's read window to cover what the connection delivers in a round trip, and half as
/// much again so that a faster link shows itself. The shortest latency seen stands for the round trip
/// itself, so requests queueing at a slow link don't count: the window settles at a little over the
/// link's capacity, and browsing over the same connection doesn't wait behind a long queue.
struct TransferPacing {
    private(set) var window: Int
    private let floor: Int, limit: Int, chunkSize: Int
    private var shortestLatency: Duration?
    private var intervalStart: ContinuousClock.Instant?
    private var intervalBytes = 0

    init(window: Int, limit: Int, chunkSize: Int) {
        self.window = window; floor = window; self.limit = max(window, limit); self.chunkSize = chunkSize
    }

    mutating func received(bytes: Int, latency: Duration, at now: ContinuousClock.Instant) {
        guard limit > floor else { return }
        let shortest = min(shortestLatency ?? latency, latency)
        shortestLatency = shortest
        guard let start = intervalStart else { intervalStart = now; return }
        intervalBytes += bytes
        let elapsed = start.duration(to: now)
        guard elapsed >= shortest, elapsed > .zero else { return }
        let deliveredInRoundTrip = Double(intervalBytes) * (shortest / elapsed)
        let wanted = (deliveredInRoundTrip * 1.5 / Double(chunkSize)).rounded(.up)
        window = max(floor, min(limit, wanted >= Double(limit) ? limit : Int(wanted)))
        intervalStart = now; intervalBytes = 0
    }
}

/// Shared receive-time bound, independent of the server's initial size hint.
/// Kept internal so controlled chunks can exercise growth and short-read behavior.
enum BoundedPreviewReader {
    static func read(initialSize: UInt64?, limit: Int, window: Int = 8,
                     readChunk: @escaping @Sendable (UInt64, UInt32) async throws -> ByteBuffer) async throws -> (Data, Int) {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        var bytes = Data()
        bytes.reserveCapacity(min(limit, Int(clamping: initialSize ?? 0)))
        let result = try await stream(initialSize: initialSize, limit: limit, window: window, readChunk: readChunk) { chunk in
            bytes.append(contentsOf: chunk.readableBytesView)
        }
        return (bytes, result.requests)
    }

    /// Keeps at most `window` reads in flight so throughput is not capped at one chunk per round
    /// trip, and hands bytes to `consume` strictly in file order. A short read is not EOF: its gap
    /// is queued as soon as it arrives and takes the next free slots, and once a filled gap confirms
    /// the server's maximum read size, later requests use it. Requests never extend more than one
    /// probe byte past `limit`.
    /// `startOffset` continues a transfer whose earlier bytes are already held; offsets, the
    /// limit and the returned byte count are all absolute file positions.
    ///
    /// A known size shapes the requests: they end exactly where the file should, with one probe just
    /// past it, so reading a small file takes one round trip. Growth past the size carries on as without one.
    /// With `windowLimit`, `window` grows towards it for as long as the connection delivers more.
    static func stream(initialSize: UInt64?, limit: Int, startOffset: Int = 0, chunkSize: Int = 64 * 1024, window: Int = 8, windowLimit: Int? = nil,
                       observe: (_ window: Int, _ inFlight: Int) -> Void = { _, _ in },
                       readChunk: @escaping @Sendable (UInt64, UInt32) async throws -> ByteBuffer,
                       consume: (ByteBuffer) async throws -> Void) async throws -> (bytes: Int, requests: Int) {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        guard startOffset >= 0, startOffset <= limit else { throw RemoteFileError.tooLarge(limit) }
        if let size = initialSize, size > UInt64(limit) { throw RemoteFileError.tooLarge(limit) }
        struct Request { let offset: Int; let amount: Int; let fillsShortRead: Int? }
        let clock = ContinuousClock()
        var pacing = TransferPacing(window: max(1, window), limit: windowLimit ?? max(1, window), chunkSize: max(1, chunkSize))
        return try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { group in
            var issued: [Int: Request] = [:]
            var order: [Int] = []       // Unconsumed request IDs by ascending offset.
            var received: [Int: ByteBuffer] = [:]
            var waiting: [Int] = []     // Registered gap pieces not yet sent, by ascending offset.
            var nextID = 0, sent = 0, nextOffset = startOffset, inFlight = 0, consumed = startOffset
            var endOfFile = Int.max     // Lowest offset already answered with EOF.
            var chunk = max(1, chunkSize)
            var expectedEnd = initialSize.map { Int(clamping: $0) } // Nil once the file has outgrown it.
            var sentAt: [Int: ContinuousClock.Instant] = [:]
            func register(_ request: Request, at position: Int) -> Int {
                let id = nextID
                nextID += 1
                issued[id] = request
                order.insert(id, at: position)
                return id
            }
            func send(_ id: Int) {
                let request = issued[id]!
                inFlight += 1; sent += 1
                sentAt[id] = clock.now
                group.addTask { (id, try await readChunk(UInt64(request.offset), UInt32(request.amount))) }
            }
            while true {
                try Task.checkCancellation()
                // Gaps hold back in-order delivery, so they take free slots before new ranges.
                while inFlight < pacing.window, !waiting.isEmpty { send(waiting.removeFirst()) }
                while inFlight < pacing.window, nextOffset <= limit, nextOffset < endOfFile, nextOffset <= expectedEnd ?? Int.max {
                    var amount = min(chunk, limit - nextOffset + 1)
                    if let expectedEnd, nextOffset < expectedEnd { amount = min(amount, expectedEnd - nextOffset) }
                    send(register(Request(offset: nextOffset, amount: amount, fillsShortRead: nil), at: order.endIndex))
                    nextOffset += amount
                }
                // Every byte through the probe was requested and accepted: only growth gets here.
                guard let (id, buffer) = try await group.next() else { throw RemoteFileError.tooLarge(limit) }
                observe(pacing.window, inFlight)
                inFlight -= 1
                received[id] = buffer
                let request = issued[id]!
                if let started = sentAt.removeValue(forKey: id) {
                    let now = clock.now
                    pacing.received(bytes: buffer.readableBytes, latency: started.duration(to: now), at: now)
                }
                if let end = expectedEnd, request.offset >= end, buffer.readableBytes > 0 { expectedEnd = nil }
                if buffer.readableBytes == 0 {
                    endOfFile = min(endOfFile, request.offset)
                } else if buffer.readableBytes < request.amount {
                    // A filled gap proves the earlier short read was the server's maximum, not EOF.
                    if let short = request.fillsShortRead { chunk = min(chunk, max(short, 4 * 1024)) }
                    var offset = request.offset + buffer.readableBytes
                    var position = order.firstIndex(of: id)! + 1
                    while offset < request.offset + request.amount {
                        let amount = min(chunk, request.offset + request.amount - offset)
                        waiting.append(register(Request(offset: offset, amount: amount, fillsShortRead: buffer.readableBytes), at: position))
                        offset += amount; position += 1
                    }
                    waiting.sort { issued[$0]!.offset < issued[$1]!.offset }
                } else if let short = request.fillsShortRead {
                    chunk = min(chunk, max(short, 4 * 1024))
                }
                while let head = order.first, let buffer = received.removeValue(forKey: head) {
                    order.removeFirst()
                    let request = issued.removeValue(forKey: head)!
                    if buffer.readableBytes == 0 {
                        group.cancelAll()
                        return (consumed, sent)
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
