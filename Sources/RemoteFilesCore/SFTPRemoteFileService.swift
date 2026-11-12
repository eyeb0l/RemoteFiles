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
    /// Off unless a benchmark sets it. See `TransferWindowCarry`.
    private var transferWindowCarry: TransferWindowCarry?

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
    /// Lets a benchmark start each transfer at the window the last one on the connection settled at, or, with
    /// `settled`, at a window it names, as if an earlier transfer had left it. Nil turns it off. Either way
    /// the connection forgets what it had, so one policy's transfers never start from another's.
    func setTransferWindowCarry(_ carry: TransferWindowCarry?, settled: Int? = nil) {
        transferWindowCarry = carry
        active?.settledTransferWindow = carry == nil ? nil : settled
    }

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
        var retried = false
        while true {
            // Channels of an earlier search, cancelled or finished, that the server may not have freed yet.
            let earlier = session.helperChannels.count, expectsRoom = retried
            do {
                let timeout = UInt64(limits.timeLimit.components.seconds + 1) + timeoutSeconds
                let helperChannels = session.helperChannels
                let (update, bytes) = try await performOnDedicatedChannel(session: session, timeout: timeout, purpose: .search(expectsRoom: expectsRoom),
                                                                                         closesInBackground: true) { sftp in
                    let identity = try await Self.searchIdentity(root: root, sftp: sftp)
                    // The root stays held until the helper has finished with it.
                    defer { _ = identity.directory.sendClose() }
                    let command = try ServerFolderSearch.command(query: query, root: root, includeHidden: includeHidden,
                        limits: limits, content: content, identity: identity.value)
                    let decoder = ServerFolderSearch.OutputDecoder(query: query, root: root, includeHidden: includeHidden, limits: limits, content: content)
                    return try await self.retryingRefusal(session, expected: expectsRoom) {
                        try await Self.streamSearchCommand(client: session.client, command: command, timeout: timeout, decoder: decoder,
                                                           partial: partial, onChannel: { helperChannels.add($0.closeFuture) })
                    }
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
                case _ where Self.isChannelRefusal(error):
                    // The server limits session channels: a question of room, not of what it can run. The helper
                    // needs two beside browsing. Free what this connection can and try once more; remember the
                    // refusal only when browsing alone left no room, since transfers and closing channels pass.
                    await fallBackFromHelper(session)
                    if !retried {
                        retried = true
                        if earlier > 0 { continue }
                        if await reclaimWalk(for: session) { continue }
                    }
                    if session.transferChannels.count == 0, session.foregroundLoan == nil { session.serverSearchUnavailable = true }
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
    }

    /// After a refusal, lets the helper's channels close before SFTP search takes over, so that the slots they held
    /// are free for it. Bounded: a peer can hold a close until its process exits. (After other failures, browsing
    /// waits for them itself if the server refuses its channel; see `acquireSFTP`.)
    private func fallBackFromHelper(_ session: LiveSession) async {
        await awaitHelperChannels(session)
    }

    private func awaitHelperChannels(_ session: LiveSession) async {
        _ = await session.helperChannels.closed(within: dedicatedCloseGrace)
    }

    /// OpenSSH frees a session's slot only once that session's process has exited, a moment after its channel
    /// closed. Where this connection expects room (`expected`), a refusal while one of its own channels is still
    /// closing, or soon after one closed, is asked again, briefly, rather than taken for the server's limit.
    /// Nothing is sent on a refused channel, so asking again is safe.
    private func retryingRefusal<T: Sendable>(_ session: LiveSession, expected: Bool, replacingShared: Bool = false,
                                              _ open: @Sendable () async throws -> T) async throws -> T {
        let started = ContinuousClock.now
        var delay = Duration.milliseconds(25)
        while true {
            do { return try await open() } catch {
                guard expected, Self.isChannelRefusal(error), session.client.isConnected,
                      started.duration(to: .now) < dedicatedCloseGrace, session.mayStillHoldASlot(within: Self.slotReleaseAllowance, replacingShared: replacingShared) else { throw error }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .milliseconds(400))
            }
        }
    }

    /// How long after one of this connection's channels closed its slot may still be counted.
    static let slotReleaseAllowance: Duration = .seconds(1)

    nonisolated static func isChannelRefusal(_ error: Error) -> Bool {
        (error as? NIOSSHError)?.type == .channelSetupRejected
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
                if RemotePath.isAbsolute(target) { descriptors[number] = target }
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
                                                        partial: @escaping @Sendable (RemoteFolderSearch.Update) -> Void,
                                                        onChannel: @escaping @Sendable (Channel) -> Void = { _ in }) async throws -> (RemoteFolderSearch.Update, Int) {
        // Unbuffered in effect: the whole output is capped by `outputLimit`, however fast it comes.
        let (chunks, sink) = AsyncStream.makeStream(of: ByteBuffer.self)
        let execution = Task {
            defer { sink.finish() }
            _ = try await executeSearchCommand(client: client, command: command, timeout: timeout, onOutput: { sink.yield($0) }, onChannel: onChannel)
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
                                                 onChannelCreated: @escaping @Sendable () -> Void = {},
                                                 onChannel: @escaping @Sendable (Channel) -> Void = { _ in }) async throws -> ByteBuffer {
        let control = SocketControl()
        return try await withTaskCancellationHandler {
            defer { control.close() }
            return try await detachedDeadline(seconds: timeout, onTimeout: { control.close() }) {
                try Task.checkCancellation()
                return try await client.executeBoundedCommand(command, maxResponseSize: maxResponseSize, onOutput: onOutput, onChannelCreated: {
                    onChannel($0); control.install($0); onChannelCreated()
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
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL, limit: Int,
                              batch: SnapshotTransferBatch, overlapped: Bool, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await download(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination,
                           limit: limit, progress: progress, canonicalPaths: true, batch: batch, overlapped: overlapped)
    }
    /// Closes the batch's channel without waiting for the server: nothing on it is still running.
    func endSnapshotBatch(_ batch: SnapshotTransferBatch) {
        measurements.lastBatchPeakFiles = batch.peakFiles; measurements.lastBatchPeakBytes = batch.peakBytes
        batch.ended = true
        batch.retire()
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
                          started: @escaping ManagedDownloadStartHandler = { _, _ in },
                          batch: SnapshotTransferBatch? = nil, overlapped: Bool = false) async throws -> RemoteEntry {
        guard limit > 0, limit < Int.max else { throw RemoteFileError.tooLarge(limit) }
        let session = try await session(for: profile)
        let reportInterval = progressInterval, windowFloor = transferWindowFloor
        // Files that overlap keep the starting window, so together they hold no more in flight than one growing transfer.
        let windowLimit = overlapped ? transferWindowFloor : transferWindowLimit
        // Measured and not adopted: see `TransferWindowCarry`. Only a transfer that grows takes or leaves a window.
        let carry = windowLimit > windowFloor ? transferWindowCarry : nil
        let windowStart = carry == nil ? windowFloor : min(windowLimit, max(windowFloor, session.settledTransferWindow ?? windowFloor))
        let holdsFirstWindow = carry?.holdsFirstWindow ?? false
        let operation: @Sendable (SFTPClient, TransferActivity) async throws -> (RemoteEntry, Int, WindowSample) = { sftp, activity in
            batch?.fileStarted()
            defer { batch?.fileEnded() }
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
                var window = WindowSample(start: windowStart)
                window.settled = try await BoundedPreviewReader.stream(initialSize: attributes.size, limit: limit, startOffset: start, window: windowStart,
                                                          windowLimit: windowLimit, windowFloor: windowFloor, holdsFirstWindow: holdsFirstWindow,
                                                          observe: { window.add(window: $0, inFlight: $1) }, readChunk: { offset, amount in
                    batch?.requested(Int(amount))
                    defer { batch?.answered(Int(amount)) }
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
                }.settledWindow
                try await file.close()
                try Task.checkCancellation()
                await progress(.init(receivedBytes: UInt64(count), totalBytes: UInt64(count), isComplete: true))
                return (entry, count - start, window)
            } catch {
                try? await file.close()
                throw error
            }
        }
        let result: (RemoteEntry, Int, WindowSample)
        if let batch, batch.sharesChannel {
            result = try await performOnBatchChannel(session: session, batch: batch, operation: operation)
        } else {
            result = try await performOnDedicatedChannel(session: session, budget: managed ? .idle(managedTransferIdle) : .total(180), operation: operation)
        }
        measurements.fileOperations += 1; measurements.bytesReceived += result.1
        measurements.lastTransferPeakWindow = result.2.peak; measurements.lastTransferMeanInFlight = result.2.meanInFlight
        measurements.lastTransferStartWindow = result.2.start; measurements.lastTransferSettledWindow = result.2.settled ?? 0
        // Only a transfer that finished, and that the window held back, says anything about the connection.
        if carry != nil, let settled = result.2.settled { session.settledTransferWindow = settled }
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
            // Two round trips, not four: the root and the document are asked for together, then the target
            // and what it is. Each answer is still judged in the order it was before, the boundary first.
            let rootPath = sftp.sendRealPath(atPath: try Self.validated(profile.startingDirectory))
            let documentCanonical = sftp.sendRealPath(atPath: try Self.validated(documentPath))
            let root = try await rootPath.get()
            let document = try await documentCanonical.get()
            guard RemoteResourcePath.contains(document, in: root) else { throw RemoteDocumentLinkError.outsideConnection }
            let requested = try RemoteDocumentLinkPath.resolve(reference, relativeTo: document, connectionRoot: root)
            let target = try Self.validated(requested)
            let canonicalPath = sftp.sendRealPath(atPath: target)
            // Both follow links from the same path, so they describe the same file. It is only a
            // description: reading the file checks the boundary again on the handle it opens.
            let describing = sftp.sendAttributes(at: target)
            let canonical = try await canonicalPath.get()
            guard RemoteResourcePath.contains(canonical, in: root) else { throw RemoteDocumentLinkError.outsideConnection }
            let attributes = try await describing.get()
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
            // One round trip: both follow links from the same path, so they describe the same entry.
            let requested = try Self.validated(path)
            let canonicalPath = sftp.sendRealPath(atPath: requested)
            let describing = sftp.sendAttributes(at: requested)
            let canonical = try await canonicalPath.get()
            let attributes = try await describing.get()
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
            let session: LiveSession
            do {
                session = try await withTaskCancellationHandler { try await pending.value } onCancel: {
                    pending.cancel()
                    joinedControl?.close()
                }
            } catch {
                // Cancelled if this caller was, or if the attempt it joined was given up, as by Disconnect.
                // A newer attempt started since by another request doesn't make this one's failure any
                // less a failure.
                if Task.isCancelled || pending.isCancelled { throw CancellationError() }
                // The same failure as the caller that started this connection reports, in the same words.
                throw Self.connectionFailure(error, profile: profile)
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
            throw Self.connectionFailure(error, profile: profile)
        }
    }

    /// What a failed connection is reported as, to the caller that started it and to any that joined it.
    nonisolated static func connectionFailure(_ error: Error, profile: ConnectionProfile) -> Error {
        switch error {
        case SSHClientError.allAuthenticationOptionsFailed, SSHClientError.unsupportedPrivateKeyAuthentication,
             is AuthenticationFailed, CitadelError.unauthorized:
            return RemoteFileError.authenticationFailed
        default: break
        }
        if profile.jumpHost != nil, let sshError = error as? NIOSSHError, sshError.type == .channelSetupRejected {
            return RemoteFileError.unavailable("The jump host couldn't reach the destination. Check its hostname and port, and that the jump host permits TCP forwarding to it.")
        }
        if let sshError = error as? NIOSSHError, sshError.type == .keyExchangeNegotiationFailure {
            return RemoteFileError.unavailable(noCommonAlgorithms(jumpHost: profile.jumpHost != nil))
        }
        if error is NIOConnectionError {
            return RemoteFileError.unavailable("Couldn't connect to this server. Check its address and network. For local Wi-Fi, allow RemoteFiles in Settings → Privacy & Security → Local Network, then try again.")
        }
        return error
    }

    /// The SSH stack reports every key-exchange, host-key, cipher and MAC mismatch as the same error, without
    /// saying which list failed, so the message names everything the app needs rather than guessing. A missing
    /// AES-GCM cipher (stock Dropbear offers none) is the common case. No weaker algorithm is enabled as a fallback.
    nonisolated static func noCommonAlgorithms(jumpHost: Bool) -> String {
        "RemoteFiles and this server\(jumpHost ? " or its jump host" : "") have no secure connection method in common, so it can't connect. "
            + "RemoteFiles needs AES-GCM encryption (aes128-gcm@openssh.com or aes256-gcm@openssh.com), "
            + "Curve25519 or elliptic-curve Diffie-Hellman key exchange, and an Ed25519 or ECDSA host key, and doesn't fall back to weaker methods. "
            + "Some servers, including Dropbear, don't offer AES-GCM. Ask the server's administrator which of these the server lacks."
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
            // Outside the deadline: on a one-channel server this waits for a transfer, which may take a while.
            try await enterForeground(session)
            return try await Self.detachedDeadline(seconds: timeoutSeconds, extending: progress, onTimeout: {
                channel.close()
                if !channel.hasClient { session.control.close() }
            }) {
                let shared: SharedSFTPChannel
                do { shared = try await self.acquireSFTP(for: session, role: role) } catch {
                    await self.leaveForeground(session)
                    throw error
                }
                channel.install(shared.client, closing: shared.closing)
                let closes = DeferredCloses()
                do {
                    try Task.checkCancellation()
                    let value = try await operation(shared.client, closes)
                    let pending = closes.take()
                    if pending.isEmpty {
                        await self.release(shared, from: session, reusable: true, leaving: true)
                    } else {
                        Task { await self.release(shared, from: session, reusable: await self.settle(pending, on: shared), leaving: true) }
                    }
                    return value
                } catch {
                    let pending = closes.take()
                    if pending.isEmpty {
                        await self.release(shared, from: session, reusable: false, leaving: true)
                    } else {
                        Task { _ = await self.settle(pending, on: shared); await self.release(shared, from: session, reusable: false, leaving: true) }
                    }
                    throw error
                }
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Waits while a transfer holds the session slot that browsing lent it (see `lendForeground`), then counts
    /// the caller as using the session's shared channels until `leaveForeground`. Cancellable.
    private func enterForeground(_ session: LiveSession) async throws {
        while let loan = session.foregroundLoan {
            // The slot came back and `endLoan` counted this caller in, ahead of any transfer.
            if try await wait(on: loan, admitted: true) { return }
        }
        session.foregroundUsers += 1
    }

    /// A transfer waiting for the slot to come back. It isn't counted in: browsing goes first.
    private func waitWhileLent(_ session: LiveSession) async throws {
        while let loan = session.foregroundLoan { _ = try await wait(on: loan, admitted: false) }
    }

    private func wait(on loan: ForegroundLoan, admitted: Bool) async throws -> Bool {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Bool, Error>) in
                if Task.isCancelled { waiter.resume(throwing: CancellationError()); return }
                loan.waiters[id] = (waiter, admitted)
                loan.returnWhenIdle?()
            }
        } onCancel: {
            Task { await self.abandonWait(id, on: loan) }
        }
    }

    private func abandonWait(_ id: UUID, on loan: ForegroundLoan) {
        loan.waiters.removeValue(forKey: id)?.0.resume(throwing: CancellationError())
    }

    private func leaveForeground(_ session: LiveSession) {
        session.foregroundUsers -= 1
        if session.foregroundUsers == 0, let drained = session.foregroundLoan?.drained {
            session.foregroundLoan?.drained = nil
            drained.resume()
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
    private func performOnDedicatedChannel<T: Sendable>(session: LiveSession, timeout: UInt64, purpose: DedicatedChannelPurpose = .transfer,
                                                        closesInBackground: Bool = false,
                                                        operation: @escaping @Sendable (SFTPClient) async throws -> T) async throws -> T {
        try await performOnDedicatedChannel(session: session, budget: .total(timeout), purpose: purpose, closesInBackground: closesInBackground) { sftp, _ in
            try await operation(sftp)
        }
    }

    private enum DedicatedChannelBudget { case total(UInt64), idle(Duration) }

    /// A transfer may reclaim the walk's channel, or borrow browsing's on a one-channel server, when the server
    /// refuses it a channel. The search helper does neither here: `searchFolders` decides what its refusal means.
    private enum DedicatedChannelPurpose: Equatable { case transfer, search(expectsRoom: Bool) }

    /// `closesInBackground` returns as soon as the operation has what its caller needs, instead of waiting a
    /// round trip for the channel to close. Only for work that leaves nothing behind that a later write could hit.
    private func performOnDedicatedChannel<T: Sendable>(session: LiveSession, budget: DedicatedChannelBudget,
        purpose: DedicatedChannelPurpose = .transfer, closesInBackground: Bool = false,
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
            let sftp = try await self.openTransferSFTP(for: session, purpose: purpose).sftp
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

    /// As `performOnDedicatedChannel`, on the batch's channel instead of a new one: the operation keeps its own
    /// idle deadline (as a managed download's: it fails only after `managedTransferIdle` without file bytes, so a
    /// slow file still finishes and a stalled one fails in about a minute), its caller waits for it to drain, and a channel that hasn't drained within the grace period
    /// closes the socket. A deadline or cancellation closes the channel for every file on it; the next file
    /// opens another, as it does after the connection was replaced. Once the batch has ended nothing starts,
    /// so a cancelled file arriving late can't open a channel only to close the connection.
    ///
    /// Unlike a file's own channel, one still opening isn't a reason to close the socket at once: the open is
    /// shared, so a live connection finishes it and the grace period covers a dead one.
    private func performOnBatchChannel<T: Sendable>(session: LiveSession, batch: SnapshotTransferBatch,
                                                    operation: @escaping @Sendable (SFTPClient, TransferActivity) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !batch.ended else { throw CancellationError() }
        // Browsing is waiting for the slot this batch (or another transfer) borrowed: start nothing more on it. The
        // files still running finish, the channel goes back, and this file borrows it again once browsing has had
        // its turn. The batch forgets its loan when it retires, but the session keeps it until the channel closes.
        if let loan = session.foregroundLoan, !loan.waiters.isEmpty {
            if loan === batch.loan, batch.users == 0 { batch.retire() }
            // Outside the idle deadline below, and the caller's own (see `TransferQueueing`): queueing isn't stalling.
            TransferQueueing.observer?(true)
            defer { TransferQueueing.observer?(false) }
            try await waitWhileLent(session)
            guard !batch.ended else { throw CancellationError() }
        }
        if batch.session !== session || batch.control.isClosed { batch.retire() }
        let opening: Task<SFTPClient, Error>
        if let existing = batch.opening {
            opening = existing
        } else {
            opening = Task {
                let channel = try await self.openTransferSFTP(for: session, purpose: .transfer)
                if let loan = channel.loan { self.lend(loan, to: batch) }
                return channel.sftp
            }
            batch.session = session; batch.opening = opening
            measurements.sftpChannels += 1
        }
        batch.users += 1
        defer {
            batch.users -= 1
            if batch.users == 0, let loan = batch.loan, !loan.waiters.isEmpty { batch.retire() }
        }
        let control = batch.control, drained = LockedFlag(), grace = dedicatedCloseGrace
        let close: @Sendable () -> Void = {
            control.close()
            Task {
                try? await Task.sleep(for: grace)
                if !drained.isSet { session.control.close() }
            }
        }
        do {
            return try await TransferIdleDeadline.run(idle: managedTransferIdle, clock: ContinuousClock(), close: close) { activity in
                defer { drained.set() }
                let sftp = try await opening.value
                control.install(sftp)
                try Task.checkCancellation()
                return try await operation(sftp, activity)
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    /// A folder save that borrowed browsing's slot gives it back as soon as none of its files is running.
    private func lend(_ loan: ForegroundLoan, to batch: SnapshotTransferBatch) {
        guard !loan.ended else { return }
        batch.loan = loan
        loan.returnWhenIdle = { [weak batch] in
            guard let batch, batch.users == 0, batch.loan != nil else { return }
            batch.retire()
        }
    }

    private struct TransferChannel { let sftp: SFTPClient; let loan: ForegroundLoan? }

    /// Opens a dedicated channel. When the server refuses a transfer one, makes room on this connection rather
    /// than reconnecting, in this order: wait for a finished search's channels, or a retired browsing channel, to
    /// close; reclaim the optional walk channel (`reclaimWalk`); on a server allowing one channel, borrow
    /// browsing's (`lendForeground`).
    /// Each happens at most once. A transfer never shares a channel with browsing, so its cancellation and
    /// deadlines stay its own. Only an explicit channel-open refusal counts as a lack of room.
    private func openTransferSFTP(for session: LiveSession, purpose: DedicatedChannelPurpose) async throws -> TransferChannel {
        let tracked = purpose == .transfer ? session.transferChannels : session.helperChannels
        var waited = false, reclaimed = false, settled = false
        // A server that has had to lend browsing's slot allows one channel. Asking it for another while browsing
        // holds or is opening its own would only race browsing for the slot; borrow it in turn instead.
        if purpose == .transfer, session.lendsForeground, let lent = try await lendForeground(session) { return lent }
        while true {
            do {
                let client = session.client, expected = waited || reclaimed || settled || purpose == .search(expectsRoom: true)
                let sftp = try await retryingRefusal(session, expected: expected) { try await client.openSFTP(logger: Self.sftpLogger()) }
                tracked.add(sftp.closeFuture)
                return TransferChannel(sftp: sftp, loan: nil)
            } catch {
                guard purpose == .transfer, Self.isChannelRefusal(error) else { throw error }
                try Task.checkCancellation()
                guard session.client.isConnected else { throw RemoteFileError.connectionEnded }
                if !waited, session.helperChannels.count > 0 {
                    waited = true
                    await awaitHelperChannels(session)
                } else if !settled, session.sftp.isEmpty, session.openingSFTP.isEmpty, session.sharedChannels.count > 0 {
                    // Browsing's channel was retired and is still closing: the server counts it until it has closed.
                    settled = true
                    _ = await session.sharedChannels.closed(within: dedicatedCloseGrace)
                } else if !reclaimed, await reclaimWalk(for: session) {
                    reclaimed = true
                } else if let lent = try await lendForeground(session) {
                    return lent
                } else {
                    throw error
                }
                try Task.checkCancellation()
                guard session.client.isConnected else { throw RemoteFileError.connectionEnded }
                measurements.sftpChannels += 1
            }
        }
    }

    /// Reclaim the optional walk channel only after a server refuses another channel. Servers with
    /// two session slots can then keep browsing and one isolated transfer. In-flight walk requests
    /// drain normally before their channel closes; subsequent walks share browsing for this session.
    /// Returns false, having done nothing, when there is no walk channel to reclaim.
    private func reclaimWalk(for session: LiveSession) async -> Bool {
        guard session.walkReclamation != nil || session.sftp[.walk] != nil || session.openingSFTP[.walk] != nil else { return false }
        session.walkUsesForeground = true
        let draining: Task<Void, Never>
        if let pending = session.walkReclamation {
            draining = pending
        } else {
            let shared = session.sftp.removeValue(forKey: .walk)
            let opening = session.openingSFTP.removeValue(forKey: .walk)
            draining = Task {
                if let shared { await self.drain(shared, in: session) }
                if let opening, let shared = try? await opening.value { await self.drain(shared, in: session) }
            }
            session.walkReclamation = draining
        }
        await draining.value
        session.walkReclamation = nil
        return true
    }

    /// Lets a shared channel's current work finish, closes it, and waits until it has closed.
    private func drain(_ shared: SharedSFTPChannel, in session: LiveSession) async {
        shared.retired = true
        if shared.users > 0 { await withCheckedContinuation { shared.idleWaiters.append($0) } }
        await shared.close().value
        try? await shared.client.closeFuture.get()
    }

    /// A server that refuses a second channel while this connection holds only browsing's allows one. A transfer
    /// then borrows that slot: new foreground work waits outside its deadline (`enterForeground`), work under
    /// way finishes, browsing's channel closes, and the transfer opens its own. The slot comes back when the
    /// transfer's channel has closed, however that happens, and browsing then opens its channel again. Browsing
    /// waits for a single file; a folder save gives the slot back between files whenever browsing is waiting.
    /// Returns nil, having done nothing, if anything else holds a channel on this connection.
    private func lendForeground(_ session: LiveSession) async throws -> TransferChannel? {
        guard session.foregroundLoan == nil, session.transferChannels.count == 0, session.helperChannels.count == 0,
              session.sftp[.walk] == nil, session.openingSFTP[.walk] == nil, session.walkReclamation == nil,
              session.sftp[.foreground] != nil || session.openingSFTP[.foreground] != nil || session.foregroundUsers > 0 else { return nil }
        let loan = ForegroundLoan()
        session.foregroundLoan = loan
        do {
            if session.foregroundUsers > 0 { await withCheckedContinuation { loan.drained = $0 } }
            if let shared = session.sftp.removeValue(forKey: .foreground) { await drain(shared, in: session) }
            if let opening = session.openingSFTP.removeValue(forKey: .foreground), let shared = try? await opening.value {
                await drain(shared, in: session)
            }
            try Task.checkCancellation()
            guard session.client.isConnected else { throw RemoteFileError.connectionEnded }
            measurements.sftpChannels += 1
            let client = session.client
            let sftp = try await retryingRefusal(session, expected: true) { try await client.openSFTP(logger: Self.sftpLogger()) }
            session.transferChannels.add(sftp.closeFuture)
            sftp.closeFuture.whenComplete { _ in Task { await self.endLoan(loan, in: session) } }
            measurements.foregroundLoans += 1
            session.lendsForeground = true
            return TransferChannel(sftp: sftp, loan: loan)
        } catch {
            endLoan(loan, in: session)
            throw error
        }
    }

    private func endLoan(_ loan: ForegroundLoan, in session: LiveSession) {
        guard !loan.ended else { return }
        loan.ended = true
        loan.returnWhenIdle = nil
        if session.foregroundLoan === loan { session.foregroundLoan = nil }
        // Browsing waiting for the slot is counted in at once, so a transfer borrowing it next waits for that work.
        let waiters = loan.waiters
        loan.waiters = [:]
        for (waiter, admitted) in waiters.values {
            if admitted { session.foregroundUsers += 1 }
            waiter.resume(returning: admitted)
        }
    }

    private func acquireSFTP(for session: LiveSession, role: SFTPChannelRole = .foreground, madeRoom: Bool = false) async throws -> SharedSFTPChannel {
        if role == .walk, session.walkUsesForeground { return try await acquireSFTP(for: session, role: .foreground, madeRoom: madeRoom) }
        if let shared = session.sftp[role] {
            if !shared.retired, !shared.closing.isSet, shared.client.isActive { shared.users += 1; return shared }
            retire(shared, from: session)
        }
        let opening: Task<SharedSFTPChannel, Error>
        if let pending = session.openingSFTP[role] {
            opening = pending
        } else {
            // Browsing expects room whenever no other open channel of this connection's could hold the slot.
            let client = session.client
            let expected = role == .foreground && session.transferChannels.count == 0 && session.helperChannels.count == 0
                && session.sftp[.walk] == nil && session.openingSFTP[.walk] == nil
            opening = Task {
                let sftp = try await self.retryingRefusal(session, expected: expected, replacingShared: true) {
                    try await client.openSFTP(logger: Self.sftpLogger())
                }
                session.sharedChannels.add(sftp.closeFuture)
                return SharedSFTPChannel(client: sftp, role: role)
            }
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
                session.walkUsesForeground = true
                return try await acquireSFTP(for: session, role: .foreground, madeRoom: madeRoom)
            }
            // Browsing refused its own channel. On a server allowing one, a walk or a search helper may have taken
            // the slot first: wait for the helper's channels to close, or take the walk's back (it shares browsing's
            // from then on), and try once more.
            if role == .foreground, !madeRoom, Self.isChannelRefusal(error), session.client.isConnected {
                if session.helperChannels.count > 0 {
                    await awaitHelperChannels(session)
                    return try await acquireSFTP(for: session, role: .foreground, madeRoom: true)
                }
                if await reclaimWalk(for: session) { return try await acquireSFTP(for: session, role: .foreground, madeRoom: true) }
            }
            throw error
        }
        if role == .walk, session.walkUsesForeground {
            retire(shared, from: session)
            return try await acquireSFTP(for: session, role: .foreground)
        }
        if session.openingSFTP[role] == opening { session.openingSFTP[role] = nil; session.sftp[role] = shared }
        // Another waiter may have failed on this channel and retired it while this one resumed.
        guard !shared.retired else { return try await acquireSFTP(for: session, role: role) }
        shared.users += 1
        return shared
    }

    private func release(_ shared: SharedSFTPChannel, from session: LiveSession, reusable: Bool, leaving: Bool = false) {
        shared.users -= 1
        if !reusable { retire(shared, from: session) } else if shared.retired, shared.users == 0 { shared.close() }
        if shared.users == 0 {
            let waiters = shared.idleWaiters; shared.idleWaiters = []
            waiters.forEach { $0.resume() }
        }
        if leaving { leaveForeground(session) }
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
    /// The window the last download began with, and the one it had settled at when it issued its last new range
    /// with a whole window outstanding; zero if the window never held it back or was never judged.
    public fileprivate(set) var lastTransferStartWindow = 0
    public fileprivate(set) var lastTransferSettledWindow = 0
    /// The most files, and bytes of reads, the last snapshot batch had in flight at once.
    public fileprivate(set) var lastBatchPeakFiles = 0
    public fileprivate(set) var lastBatchPeakBytes = 0
    /// Transfers that borrowed browsing's channel on a server allowing one. See `lendForeground`.
    public fileprivate(set) var foregroundLoans = 0
}

/// Saves a folder's files over one SFTP channel of their own, several at a time. See `SnapshotTransferBatch`.
protocol SnapshotBatchDownloading: RemoteFileService {
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL, limit: Int,
                              batch: SnapshotTransferBatch, overlapped: Bool, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry
    func endSnapshotBatch(_ batch: SnapshotTransferBatch) async
}

extension SFTPRemoteFileService: SnapshotBatchDownloading {}

/// The files of one offline folder share an SFTP channel, opened by the first of them and closed by
/// `endSnapshotBatch`. Each file still sends every request it sent on a channel of its own, in the same order
/// and judged the same way; what it saves is the channel's open, subsystem, version and close, four of about
/// nine round trips. Files may overlap on it. One that fails closes only its own handle, so those beside it
/// finish and the folder reports what a save of one file at a time would have.
final class SnapshotTransferBatch: @unchecked Sendable {
    /// Benchmarks only: false gives each file a channel of its own, as before.
    let sharesChannel: Bool
    // Actor-isolated to SFTPRemoteFileService.
    fileprivate var session: LiveSession?
    fileprivate var opening: Task<SFTPClient, Error>?
    fileprivate var control = SFTPChannelControl()
    fileprivate var ended = false
    /// Browsing's slot, when this batch's channel borrowed it, and the files using or waiting for the channel.
    fileprivate var loan: ForegroundLoan?
    fileprivate var users = 0
    private let lock = NSLock()
    private var files = 0, bytes = 0, mostFiles = 0, mostBytes = 0
    init(sharesChannel: Bool = true) { self.sharesChannel = sharesChannel }
    deinit { Self.close(control, opening: opening) }

    var peakFiles: Int { lock.lock(); defer { lock.unlock() }; return mostFiles }
    var peakBytes: Int { lock.lock(); defer { lock.unlock() }; return mostBytes }
    func fileStarted() { lock.lock(); files += 1; mostFiles = max(mostFiles, files); lock.unlock() }
    func fileEnded() { lock.lock(); files -= 1; lock.unlock() }
    func requested(_ amount: Int) { lock.lock(); bytes += amount; mostBytes = max(mostBytes, bytes); lock.unlock() }
    func answered(_ amount: Int) { lock.lock(); bytes -= amount; lock.unlock() }

    /// Closes the channel, including one still opening, so that the next file opens another.
    fileprivate func retire() {
        Self.close(control, opening: opening)
        session = nil; opening = nil; control = SFTPChannelControl(); loan = nil
    }
    private static func close(_ control: SFTPChannelControl, opening: Task<SFTPClient, Error>?) {
        control.close()
        guard let opening else { return }
        Task { if let client = try? await opening.value { control.install(client) } }
    }
}

private struct WindowSample {
    let start: Int
    var settled: Int?
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
    var walkUsesForeground = false
    var walkReclamation: Task<Void, Never>?
    var serverSearchUnavailable = false
    /// Operations using or opening the shared channels, and the slot browsing has lent a transfer, if any.
    var foregroundUsers = 0
    var foregroundLoan: ForegroundLoan?
    /// The read window the last growing transfer settled at, when a benchmark carries it. A new connection has none.
    var settledTransferWindow: Int?
    /// Set once browsing has had to lend its slot: the server allows one channel.
    var lendsForeground = false
    /// Dedicated channels the server may still count: the search helper's, and transfers'.
    let helperChannels = OpenChannels()
    let transferChannels = OpenChannels()
    /// Browsing's and the walk's channels, open or closing.
    let sharedChannels = OpenChannels()
    /// Whether a channel of this connection's closed within `allowance`, or, when browsing replaces its channel,
    /// whether the one it replaces (or a walk's) is still closing. See `retryingRefusal`.
    func mayStillHoldASlot(within allowance: Duration, replacingShared: Bool) -> Bool {
        if replacingShared, sharedChannels.count > 0 { return true }
        let now = ContinuousClock.now
        return [sharedChannels, helperChannels, transferChannels].contains { $0.lastClosed.map { $0.duration(to: now) < allowance } ?? false }
    }
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
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let closeLock = NSLock()
    private var closeTask: Task<Void, Never>?
    init(client: SFTPClient, role: SFTPChannelRole) { self.client = client; self.role = role }
    @discardableResult func close() -> Task<Void, Never> {
        closeLock.lock(); defer { closeLock.unlock() }
        if let closeTask { return closeTask }
        let client = client
        let task = Task { try? await client.close(); return () }
        closeTask = task
        return task
    }
}

/// Browsing's session slot, lent to a transfer on a server allowing one channel. Actor-isolated to
/// SFTPRemoteFileService. See `lendForeground`.
private final class ForegroundLoan: @unchecked Sendable {
    /// Work waiting for the slot to come back; browsing's is counted in as it returns.
    var waiters: [UUID: (CheckedContinuation<Bool, Error>, admitted: Bool)] = [:]
    /// The borrower, waiting for foreground work under way to finish.
    var drained: CheckedContinuation<Void, Never>?
    /// Set by a borrower that can give the slot back early, between its own operations.
    var returnWhenIdle: (() -> Void)?
    var ended = false
}

/// Channels that the server may still count against its session limit: open, or closing but not yet closed.
final class OpenChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var futures: [ObjectIdentifier: EventLoopFuture<Void>] = [:]
    private var closedAt: ContinuousClock.Instant?
    var count: Int { lock.withLock { futures.count } }
    /// When one of these channels last closed.
    var lastClosed: ContinuousClock.Instant? { lock.withLock { closedAt } }

    func add(_ closed: EventLoopFuture<Void>) {
        let id = ObjectIdentifier(closed)
        lock.withLock { futures[id] = closed }
        closed.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.futures.removeValue(forKey: id); self.closedAt = .now }
        }
    }

    /// Waits for every channel tracked now to close. False if some were still open when the time ran out.
    func closed(within limit: Duration) async -> Bool {
        let pending = lock.withLock { Array(futures.values) }
        guard let loop = pending.first?.eventLoop else { return true }
        let all = EventLoopFuture.andAllComplete(pending, on: loop)
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task { try? await Task.sleep(for: limit); once.resume(false) }
            all.whenComplete { _ in timer.cancel(); once.resume(true) }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock { defer { continuation = nil }; return continuation }
        pending?.resume(returning: value)
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
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
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
///
/// A transfer may start above its floor, at the window an earlier one settled at (`TransferWindowCarry`). The
/// window then shrinks as far as the floor if the connection carries less than it did, at once or, with
/// `holdsFirstWindow`, only after as many replies as the starting window have come back.
struct TransferPacing {
    private(set) var window: Int
    /// Whether the window is what the connection was last seen to carry, and not only where it started.
    private(set) var isJudged = false
    private let floor: Int, limit: Int, chunkSize: Int
    private var shortestLatency: Duration?
    private var intervalStart: ContinuousClock.Instant?
    private var intervalBytes = 0
    /// Replies still to come before the window may go below where it started.
    private var held: Int
    private let startWindow: Int

    init(window: Int, limit: Int, chunkSize: Int, floor: Int? = nil, holdsFirstWindow: Bool = false) {
        self.window = window; self.floor = min(window, floor ?? window); self.limit = max(window, limit); self.chunkSize = chunkSize
        startWindow = window; held = holdsFirstWindow ? window : 0
    }

    mutating func received(bytes: Int, latency: Duration, at now: ContinuousClock.Instant) {
        guard limit > floor else { return }
        held = max(0, held - 1)
        let shortest = min(shortestLatency ?? latency, latency)
        shortestLatency = shortest
        guard let start = intervalStart else { intervalStart = now; return }
        intervalBytes += bytes
        let elapsed = start.duration(to: now)
        guard elapsed >= shortest, elapsed > .zero else { return }
        let deliveredInRoundTrip = Double(intervalBytes) * (shortest / elapsed)
        let wanted = (deliveredInRoundTrip * 1.5 / Double(chunkSize)).rounded(.up)
        window = max(held > 0 ? startWindow : floor, min(limit, wanted >= Double(limit) ? limit : Int(wanted)))
        isJudged = isJudged || held == 0
        intervalStart = now; intervalBytes = 0
    }
}

/// Benchmarks only, measured and not adopted (docs/PERFORMANCE.md, "Starting at the last transfer's window"):
/// a transfer that grows starts at the read window the last one on the same connection settled at, with the
/// usual starting window as its floor.
struct TransferWindowCarry: Sendable, Equatable {
    /// Keeps the window from shrinking until as many replies as it started with have come back, so that a
    /// server whose TCP begins slowly again after an idle moment isn't taken for a slow link.
    var holdsFirstWindow = false
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
    /// With `windowLimit`, `window` grows towards it for as long as the connection delivers more, and with a
    /// `windowFloor` below `window` it also shrinks towards that. `settledWindow` is the window as the last new
    /// range went out with a whole window outstanding, once the connection had been judged: the end of a file
    /// always shrinks the window, because fewer reads are left to ask for, so its final value says nothing.
    static func stream(initialSize: UInt64?, limit: Int, startOffset: Int = 0, chunkSize: Int = 64 * 1024, window: Int = 8, windowLimit: Int? = nil,
                       windowFloor: Int? = nil, holdsFirstWindow: Bool = false,
                       observe: (_ window: Int, _ inFlight: Int) -> Void = { _, _ in },
                       readChunk: @escaping @Sendable (UInt64, UInt32) async throws -> ByteBuffer,
                       consume: (ByteBuffer) async throws -> Void) async throws -> (bytes: Int, requests: Int, settledWindow: Int?) {
        guard limit >= 0, limit < Int.max else { throw RemoteFileError.tooLarge(max(0, limit)) }
        guard startOffset >= 0, startOffset <= limit else { throw RemoteFileError.tooLarge(limit) }
        if let size = initialSize, size > UInt64(limit) { throw RemoteFileError.tooLarge(limit) }
        struct Request { let offset: Int; let amount: Int; let fillsShortRead: Int? }
        let clock = ContinuousClock()
        var pacing = TransferPacing(window: max(1, window), limit: windowLimit ?? max(1, window), chunkSize: max(1, chunkSize),
                                    floor: windowFloor.map { max(1, $0) }, holdsFirstWindow: holdsFirstWindow)
        var settledWindow: Int?
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
                    if pacing.isJudged, inFlight >= pacing.window { settledWindow = pacing.window }
                }
                // Every byte through the probe was requested and accepted: only growth gets here.
                guard let (id, buffer) = try await group.next() else { throw RemoteFileError.tooLarge(limit) }
                observe(pacing.window, inFlight)
                inFlight -= 1
                let request = issued[id]!
                // Refused on arrival, not when its turn comes: replies wait here for the ones before them, and a
                // server answering each read with far more than was asked could otherwise fill memory meanwhile.
                guard buffer.readableBytes <= request.amount else { throw RemoteFileError.tooLarge(limit) }
                received[id] = buffer
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
                        return (consumed, sent, settledWindow)
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
