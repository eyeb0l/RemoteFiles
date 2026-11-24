import Foundation
import Observation

public enum ManagedTransferState: String, Codable, Sendable {
    case queued, transferring, completed, cancelled, interrupted, failed
}

/// One file on its way to a server: from this device (an upload) or from another server (a copy).
public struct ManagedTransfer: Identifiable, Codable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        /// A copy of the chosen file, held in the transfer's private folder until it has been sent.
        case local
        /// A file on a server, bounded by the canonical folder it was chosen from.
        case remote(profile: ConnectionProfile, path: String, canonicalRoot: String)
    }
    public let id: UUID
    public let destination: ConnectionProfile
    /// The destination folder's canonical path.
    public let directory: String
    /// The name asked for; once completed, the name the file took.
    public var filename: String
    public let source: Source
    public internal(set) var expectedBytes: UInt64?
    public var conflict: UploadConflictPolicy
    public var state: ManagedTransferState
    /// Bytes the server has confirmed writing.
    public var sentBytes: UInt64
    public var message: String?
    /// The source's size and modification time when the server's partial copy was written. Nil means
    /// no partial copy is kept there and Retry starts at byte zero.
    public var partialVersion: TransferSourceVersion?
    /// Failed because the name is taken: the bytes are already on the server, waiting for a decision.
    public var nameTaken: Bool

    public var isCopy: Bool { if case .remote = source { return true }; return false }
    public var sourceProfile: ConnectionProfile? { if case .remote(let profile, _, _) = source { return profile }; return nil }
    /// Every connection this transfer uses.
    public var profiles: [ConnectionProfile] { [destination] + (sourceProfile.map { [$0] } ?? []) }
    public var isPending: Bool { state == .queued || state == .transferring }
    /// An interrupted or failed transfer whose sent bytes are kept on the server so Retry can continue.
    public var keepsPartialBytes: Bool {
        partialVersion?.allowsResume == true && sentBytes > 0 && (state == .interrupted || state == .failed)
    }
    public var progress: DownloadProgress {
        .init(receivedBytes: sentBytes, totalBytes: expectedBytes, isComplete: state == .completed)
    }
}

public enum TransferManagerError: LocalizedError {
    case queueFull, deviceStorageFull, unavailable, notRegularFile
    public var errorDescription: String? {
        switch self {
        case .queueFull: return "The transfer list is full. Remove finished transfers before adding more."
        case .deviceStorageFull: return "This device doesn't have enough free storage to prepare this upload. Free up storage, then try again."
        case .unavailable: return "This transfer is no longer available. Start it again."
        case .notRegularFile: return "Only regular files can be transferred."
        }
    }
}

/// A persistent queue of uploads and copies between servers, beside the download queue. One transfer runs
/// at a time, and the connections it uses stay open until the queue is empty, so a batch of files pays for
/// one SSH handshake. Cancellation keeps the worker's slot until the transport has actually drained.
@MainActor @Observable
public final class TransferManager {
    private static var sharedManagers: [String: TransferManager] = [:]
    public static func shared(directory: URL) throws -> TransferManager {
        let key = LocalStoreKey.path(of: directory)
        if let manager = sharedManagers[key] { return manager }
        let manager = try TransferManager(directory: directory)
        sharedManagers[key] = manager
        return manager
    }
    /// An upload is first copied into the app, so it is bounded as a download is.
    public static let maximumUploadBytes = UInt64(DownloadManager.maximumFileBytes)
    /// A copy between servers passes through memory a few mebibytes at a time and is never stored here.
    public static let maximumCopyBytes: UInt64 = 64 * 1024 * 1024 * 1024
    public static let maximumItems = 500
    /// Where files dragged in are copied before they are queued, inside the queue's folder. Emptied at launch.
    public static let incomingFolderName = "Incoming"
    public private(set) var items: [ManagedTransfer] = []
    public private(set) var persistenceError: String?
    public private(set) var activeID: UUID?
    /// How many transfers have arrived in each folder since launch. Every window shares this queue, so one
    /// showing a folder can list it again whichever window the transfer was started in.
    private var arrivals: [String: Int] = [:]
    public func arrivals(on connection: UUID, in directory: String) -> Int { arrivals[connection.uuidString + "|" + directory, default: 0] }
    public var didChange: (() -> Void)?
    private let directory: URL
    private var worker: Task<Void, Never>?
    private struct JobContext {
        let service: any RemoteFileUploading
        let onFailure: ((Error, ConnectionProfile) -> Void)?
        let onCompletion: ((ManagedTransfer) -> Void)?
    }
    private var contexts: [UUID: JobContext] = [:]
    private var sceneStates: [UUID: Bool] = [:]
    private static let defaultSceneID = UUID()
    public var isForeground: Bool { sceneStates.isEmpty ? !hadScenes : sceneStates.values.contains(true) }
    private var hadScenes = false
    private var stopped = false
    private var removeActiveWhenFinished = false
    /// How often a running transfer's progress is written to the saved list.
    var progressSaveInterval = Duration.seconds(2)
    private var lastProgressSave = ContinuousClock.now
    /// The SFTP channel a transport's transfers share on one server, for writing to it or for reading
    /// copies from it, until the queue has no more for that transport.
    private struct BatchKey: Hashable { let transport: ObjectIdentifier; let connection: UUID; let reads: Bool }
    private func batch(_ key: BatchKey) -> SnapshotTransferBatch {
        if let existing = batches[key] { return existing }
        let created = SnapshotTransferBatch()
        batches[key] = created
        return created
    }
    private var batches: [BatchKey: SnapshotTransferBatch] = [:]
    /// Partial copies to remove from servers once the worker's slot is free. See `discardRemotePartial`.
    private var cleanups: [(item: ManagedTransfer, service: any RemoteFileUploading)] = []
    /// Free bytes on the staging volume, or nil when the system cannot say. Injectable for fixtures.
    var availableDeviceBytes: (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    public init(directory: URL) throws {
        self.directory = directory
        try Self.makePrivateDirectory(directory)
        // The list, and the copy written beside it when the list couldn't be saved. Whichever was saved
        // later is the one to open, and each says which that is by its count: their dates can't, since a
        // copy may outlive the save that should have removed it and a clock may be set back. A copy that
        // is there and can't be read, as on a locked device, leaves that unknown, so nothing is opened:
        // opening the older would sweep the newer's staged files and then be saved over it.
        let list = try Self.readList(directory.appendingPathComponent(Self.listName))
        let beside: SavedList?
        do { beside = try Self.readList(directory.appendingPathComponent(Self.unsavedListName)) }
        // Written whole or not at all, so one that doesn't parse is nothing this wrote, and says nothing.
        catch is DecodingError { beside = nil }
        revision = max(list?.revision ?? 0, beside?.revision ?? 0)
        if let saved = [list, beside].compactMap({ $0 }).first(where: { $0.revision == revision }) {
            items = saved.items
            guard items.count <= Self.maximumItems, Set(items.map(\.id)).count == items.count,
                  items.allSatisfy({ UploadRequest.isValidName($0.filename) }) else { throw TransferManagerError.unavailable }
            for index in items.indices where items[index].isPending {
                items[index].state = .interrupted
                items[index].message = "The app stopped before this transfer finished. Retry to continue."
            }
        }
        // What was being copied in for an upload when the app last stopped was never queued, so nothing owns it.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.incomingFolderName, isDirectory: true))
        // A staged file is kept only while its upload can still be sent.
        let staged = Set(items.filter { $0.source == .local && $0.state != .completed }.map { $0.id.uuidString })
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if UUID(uuidString: child.lastPathComponent) != nil, !staged.contains(child.lastPathComponent) {
                try? FileManager.default.removeItem(at: child)
            }
        }
        for index in items.indices where items[index].source == .local && items[index].state != .completed
            && !FileManager.default.fileExists(atPath: stagedURL(items[index]).path) {
            items[index].state = .failed; items[index].message = RemoteUploadError.sourceUnavailable.localizedDescription
            items[index].partialVersion = nil
        }
        persist()
    }

    // MARK: Adding work

    /// Queues `file` for `directory` on `profile`. The file is taken: it is moved into the transfer's private
    /// folder (or copied, when it is on another volume), so it must be a copy the app owns and never a
    /// person's original, which a move would take from where they keep it.
    @discardableResult public func enqueueUpload(consuming file: URL, named name: String, to profile: ConnectionProfile, directory: String,
                                                 conflict: UploadConflictPolicy = .fail, service: any RemoteFileUploading,
                                                 onFailure: ((Error, ConnectionProfile) -> Void)? = nil,
                                                 onCompletion: ((ManagedTransfer) -> Void)? = nil) throws -> UUID {
        guard UploadRequest.isValidName(name) else { throw RemoteUploadError.invalidName }
        let version: TransferSourceVersion
        do { version = try LocalFileTransferSource.version(of: file) } catch { throw TransferManagerError.notRegularFile }
        guard version.size <= Self.maximumUploadBytes else { throw RemoteUploadError.tooLarge(Self.maximumUploadBytes) }
        try makeRoom()
        let id = UUID()
        let folder = jobDirectory(id), staged = folder.appendingPathComponent(name)
        try Self.makePrivateDirectory(folder)
        do {
            do { try FileManager.default.moveItem(at: file, to: staged) }
            catch {
                // Another volume, or a file the app may read and not move: copy, leaving room on the device.
                if let free = availableDeviceBytes(self.directory), UInt64(max(0, free)) < version.size + UInt64(DownloadManager.reservedDeviceBytes) {
                    throw TransferManagerError.deviceStorageFull
                }
                try FileManager.default.copyItem(at: file, to: staged)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        items.append(.init(id: id, destination: profile, directory: directory, filename: name, source: .local,
                           expectedBytes: version.size, conflict: conflict, state: .queued, sentBytes: 0, message: nil,
                           partialVersion: nil, nameTaken: false))
        contexts[id] = .init(service: service, onFailure: onFailure, onCompletion: onCompletion)
        stopped = false; publish(); startNext()
        return id
    }

    /// Queues a copy of `entry` on `source` into `directory` on `profile`. The bytes pass through this
    /// device without being stored on it. `entry` keeps the canonical folder it was chosen from.
    @discardableResult public func enqueueCopy(of entry: RemoteEntry, from source: ConnectionProfile, to profile: ConnectionProfile,
                                               directory: String, conflict: UploadConflictPolicy = .fail,
                                               service: any RemoteFileUploading,
                                               onFailure: ((Error, ConnectionProfile) -> Void)? = nil,
                                               onCompletion: ((ManagedTransfer) -> Void)? = nil) throws -> UUID {
        guard entry.kind == .file || entry.kind == .symlink else { throw TransferManagerError.notRegularFile }
        guard service is any RemoteFileStreaming else { throw TransferManagerError.unavailable }
        let name = entry.exportFilename ?? entry.name
        guard UploadRequest.isValidName(name) else { throw RemoteUploadError.invalidName }
        if let size = entry.size, size > Self.maximumCopyBytes { throw RemoteUploadError.tooLarge(Self.maximumCopyBytes) }
        try makeRoom()
        let id = UUID()
        items.append(.init(id: id, destination: profile, directory: directory, filename: name,
                           source: .remote(profile: source, path: entry.path, canonicalRoot: entry.selectionRoot),
                           expectedBytes: entry.size, conflict: conflict, state: .queued, sentBytes: 0, message: nil,
                           partialVersion: nil, nameTaken: false))
        contexts[id] = .init(service: service, onFailure: onFailure, onCompletion: onCompletion)
        stopped = false; publish(); startNext()
        return id
    }

    /// Finished transfers give way to new ones, oldest first; unfinished ones never do.
    private func makeRoom() throws {
        while items.count >= Self.maximumItems {
            guard let finished = items.firstIndex(where: { $0.state == .completed || $0.state == .cancelled }) else { throw TransferManagerError.queueFull }
            removeLocalFiles(items[finished].id)
            items.remove(at: finished)
        }
    }

    /// Queues an interrupted, failed or cancelled transfer again. `conflict` answers a taken name.
    /// `profiles` are the connections as they are saved now: a transfer made for a connection that has
    /// since changed must be started again, so it can't reach a different server, account or folder.
    public func retry(_ id: UUID, profiles: [ConnectionProfile], conflict: UploadConflictPolicy? = nil,
                      service: any RemoteFileUploading, onFailure: ((Error, ConnectionProfile) -> Void)? = nil,
                      onCompletion: ((ManagedTransfer) -> Void)? = nil) throws {
        guard let index = index(id), activeID != id, items[index].state != .completed, items[index].state != .queued else { return }
        guard items[index].profiles.allSatisfy(profiles.contains) else { throw TransferManagerError.unavailable }
        if items[index].source == .local, !FileManager.default.fileExists(atPath: stagedURL(items[index]).path) {
            throw RemoteUploadError.sourceUnavailable
        }
        if items[index].isCopy, !(service is any RemoteFileStreaming) { throw TransferManagerError.unavailable }
        if let conflict { items[index].conflict = conflict }
        contexts[id] = .init(service: service, onFailure: onFailure, onCompletion: onCompletion)
        items[index].state = .queued; items[index].message = nil; items[index].nameTaken = false
        stopped = false; publish(); startNext()
    }

    // MARK: Stopping and removing

    public func cancel(_ id: UUID) {
        guard let index = index(id), items[index].isPending else { return }
        items[index].state = .cancelled; items[index].message = nil
        if activeID == id { worker?.cancel() } else {
            // A retry waiting in the queue gives up the bytes it kept on the server, as a cancelled transfer does.
            let context = contexts.removeValue(forKey: id)
            if items[index].partialVersion != nil, let service = context?.service { discardRemotePartial(items[index], service: service) }
            items[index].partialVersion = nil; items[index].sentBytes = 0
        }
        publish(); startNext()
    }

    /// Removes a transfer and its staged file. Its partial copy on the server is removed too when
    /// `service` can reach it; if it can't, a hidden `.rf-upload-….part` file stays there.
    public func remove(_ id: UUID, service: (any RemoteFileUploading)? = nil) {
        guard activeID != id else { removeActiveWhenFinished = true; cancel(id); return }
        guard let index = index(id) else { return }
        if items[index].partialVersion != nil, let service = service ?? contexts[id]?.service {
            discardRemotePartial(items[index], service: service)
        }
        removeRecord(id)
        publish(); startNext()
    }

    /// Removes every transfer that has finished, successfully or by cancellation.
    public func removeFinished() {
        for item in items where item.state == .completed || item.state == .cancelled {
            // One cancelled a moment ago may still be stopping. It goes when it has, as `remove` has it go,
            // so that its partial copy on the server is removed too.
            if item.id == activeID { removeActiveWhenFinished = true } else { removeRecord(item.id) }
        }
        publish()
    }

    public func removeAll(service: (any RemoteFileUploading)? = nil) {
        if let activeID {
            removeActiveWhenFinished = true
            cancel(activeID)
        }
        // Retire queued jobs together so removing one cannot start the next.
        for item in items where item.id != activeID {
            if item.partialVersion != nil, let service = service ?? contexts[item.id]?.service { discardRemotePartial(item, service: service) }
            removeRecord(item.id)
        }
        publish(); startNext()
    }

    private func removeRecord(_ id: UUID) {
        removeLocalFiles(id)
        contexts.removeValue(forKey: id)
        items.removeAll { $0.id == id }
    }
    private func removeLocalFiles(_ id: UUID) {
        try? FileManager.default.removeItem(at: jobDirectory(id))
    }

    /// Best effort: a server that can't be reached keeps its hidden partial file. The removal takes the
    /// worker's slot, after a transfer under way, so that it and the closing of its connection never run
    /// beside a transfer on the same connection.
    /// Only noted here. The caller starts the worker once it has finished changing the list, so that a
    /// removal of several transfers can't start one of them part-way through.
    private func discardRemotePartial(_ item: ManagedTransfer, service: any RemoteFileUploading) {
        cleanups.append((item, service))
    }
    /// Returns the transports the removals went through.
    private func runCleanups() async -> [any RemoteFileUploading] {
        var used: [any RemoteFileUploading] = []
        while !cleanups.isEmpty {
            let next = cleanups.removeFirst()
            if !used.contains(where: { ($0 as AnyObject) === (next.service as AnyObject) }) { used.append(next.service) }
            // The worker's own task may be cancelled, and the removal must still be asked for.
            await Task {
                try? await next.service.removePartialUpload(profile: next.item.destination, directory: next.item.directory,
                                                            partialName: UploadRequest.partialName(for: next.item.id),
                                                            restoring: next.item.conflict == .replace ? next.item.filename : nil)
            }.value
        }
        return used
    }
    /// Ends the worker's turn. Still holding its slot, so nothing else is using the connections: removes the
    /// partial copies waiting to go, then closes this transport's connections unless the queue has more
    /// for them, without locking the keys another foreground operation holds. A stopped or backgrounded
    /// queue locks them, as a download's does.
    private func finishWorker(_ service: any RemoteFileUploading) async {
        var used = await runCleanups()
        if !used.contains(where: { ($0 as AnyObject) === (service as AnyObject) }) { used.append(service) }
        for transport in used {
            let more = isForeground && !stopped && items.contains { item in
                item.state == .queued && contexts[item.id].map { ($0.service as AnyObject) === (transport as AnyObject) } == true
            }
            guard !more else { continue }
            for (key, batch) in batches where key.transport == ObjectIdentifier(transport as AnyObject) {
                batches[key] = nil
                await (transport as? any BatchedUploading)?.endSnapshotBatch(batch)
            }
            await Self.close(transport, lockingKeys: !isForeground || stopped)
        }
        // Asked to go while it still had the slot. Here, and not as its transfer ends, so that one asked to go
        // while its connection closes goes too, and the asking is never left for the transfer after it.
        if removeActiveWhenFinished, let activeID { removeRecord(activeID) }
        removeActiveWhenFinished = false
        activeID = nil; worker = nil; publish(); startNext()
    }

    /// Queued work starts only while foregrounded, where trust and unlock prompts can be shown.
    public func setForeground(_ value: Bool, sceneID: UUID? = nil) {
        hadScenes = true
        sceneStates[sceneID ?? Self.defaultSceneID] = value
        guard isForeground else { return }
        saveIfUnsaved()
        startNext()
    }
    /// The saved list is protected while the device is locked, so what a transfer did in the background then
    /// could only be recorded in memory. This writes it again: when the app comes to the front, and when
    /// iOS says protected files can be reached, which on a device with a passcode can be the later of the two.
    public func saveIfUnsaved() {
        if persistenceError != nil { publish() }
    }
    public func removeScene(_ id: UUID) { sceneStates.removeValue(forKey: id) }

    /// Used for explicit disconnect, background expiration and lock. No automatic reconnect.
    public func interrupt(reason: String) async { await interruptNow(reason: reason).value }

    /// The part of an interruption that can't wait, done before this returns: every pending transfer is
    /// marked interrupted, the one under way is told to stop, and the list is saved. What is left, closing
    /// the connection and letting the worker drain, is the task returned. iOS suspends an app as soon as it
    /// gives back its background time, so a caller about to do that must have the list right first.
    @discardableResult public func interruptNow(reason: String) -> Task<Void, Never> {
        stopped = true
        for index in items.indices where items[index].isPending {
            items[index].state = .interrupted; items[index].message = reason
        }
        let activeWorker = worker
        activeWorker?.cancel(); publish()
        let service = activeID.flatMap { contexts[$0]?.service }
        // Retire only the contexts present at interruption, before yielding.
        contexts.removeAll()
        return Task {
            await (service as? any RemoteFileService)?.disconnect()
            await activeWorker?.value
        }
    }

    /// Interrupts only the queued and active transfers `matching` selects, as when a connection they use was
    /// edited, removed or had its host key forgotten. Others keep their place and the queue isn't stopped.
    public func interrupt(reason: String, where matching: (ManagedTransfer) -> Bool) async {
        var selected = Set<UUID>()
        for index in items.indices where items[index].isPending && matching(items[index]) {
            items[index].state = .interrupted; items[index].message = reason
            selected.insert(items[index].id)
        }
        guard !selected.isEmpty else { return }
        let activeWorker = activeID.map(selected.contains) == true ? worker : nil
        let activeService = activeWorker == nil ? nil : activeID.flatMap { contexts[$0]?.service }
        for id in selected { contexts.removeValue(forKey: id) }
        activeWorker?.cancel(); publish()
        // Its connections close so the transfer drains; keys stay unlocked for the transfers left.
        if let activeService { await Self.close(activeService, lockingKeys: false) }
        await activeWorker?.value
    }

    // MARK: Running

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    private func jobDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func stagedURL(_ item: ManagedTransfer) -> URL { jobDirectory(item.id).appendingPathComponent(item.filename) }

    private func startNext() {
        guard worker == nil else { return }
        guard isForeground, !stopped, let item = items.first(where: { $0.state == .queued }), let index = index(item.id) else {
            // Nothing to send: partial copies waiting to be removed take the slot instead.
            if let service = cleanups.first?.service { worker = Task { [weak self] in await self?.finishWorker(service) } }
            return
        }
        guard let context = contexts[item.id] else {
            // Queued by a window that has gone: nothing can show its prompts or run it.
            items[index].state = .interrupted; items[index].message = "Retry to continue this transfer."
            publish(); startNext(); return
        }
        let service = context.service
        let source: any TransferSource
        switch item.source {
        case .local: source = LocalFileTransferSource(url: stagedURL(item))
        case .remote(let profile, let path, let canonicalRoot):
            guard let streaming = service as? any RemoteFileStreaming else {
                items[index].state = .failed; items[index].message = TransferManagerError.unavailable.localizedDescription
                contexts.removeValue(forKey: item.id)
                publish(); startNext(); return
            }
            var remote = RemoteFileTransferSource(service: streaming, profile: profile, path: path, canonicalRoot: canonicalRoot)
            remote.sameConnection = profile == item.destination
            if !remote.sameConnection, service is any BatchedStreaming {
                remote.batch = batch(.init(transport: ObjectIdentifier(service as AnyObject), connection: profile.id, reads: true))
            }
            source = remote
        }
        let request = UploadRequest(directory: item.directory, name: item.filename, conflict: item.conflict,
                                    partialName: UploadRequest.partialName(for: item.id), resumeVersion: item.partialVersion,
                                    limit: item.isCopy ? Self.maximumCopyBytes : Self.maximumUploadBytes)
        activeID = item.id; items[index].state = .transferring
        worker = Task { [weak self, service] in
            guard let self else { return }
            do {
                let started: UploadStartHandler = { [weak self] version, offset in await self?.recordStart(version: version, offset: offset, id: item.id) }
                let progress: DownloadProgressHandler = { [weak self] progress in await self?.updateProgress(progress, id: item.id) }
                let entry: RemoteEntry
                if let batched = service as? any BatchedUploading {
                    let batch = self.batch(.init(transport: ObjectIdentifier(service as AnyObject), connection: item.destination.id, reads: false))
                    entry = try await batched.uploadFile(profile: item.destination, request: request, source: source, batch: batch,
                                                        started: started, progress: progress)
                } else {
                    entry = try await service.uploadFile(profile: item.destination, request: request, source: source,
                                                        started: started, progress: progress)
                }
                try Task.checkCancellation()
                if let index = self.index(item.id), self.items[index].state == .transferring {
                    self.items[index].state = .completed; self.items[index].message = nil
                    self.items[index].sentBytes = entry.size ?? self.items[index].sentBytes
                    self.items[index].partialVersion = nil; self.items[index].nameTaken = false
                    if entry.name != item.filename, UploadRequest.isValidName(entry.name) {
                        // Kept beside another file: the list shows the name it was given.
                        self.items[index].filename = entry.name
                    }
                    self.removeLocalFiles(item.id)
                    self.arrivals[item.destination.id.uuidString + "|" + item.directory, default: 0] += 1
                    context.onCompletion?(self.items[index])
                }
            } catch {
                let shown: Error = switch error {
                case RemoteDocumentLinkError.outsideConnection, RemoteResourceError.outsideDocument: OriginalFileExportError.outsideRoot
                default: error
                }
                if let index = self.index(item.id), self.items[index].state == .transferring {
                    self.items[index].state = error is CancellationError ? .cancelled : .failed
                    self.items[index].message = error is CancellationError ? nil : shown.localizedDescription
                    if case RemoteUploadError.destinationExists = error { self.items[index].nameTaken = true }
                    if !(error is CancellationError) { context.onFailure?(error, item.destination) }
                }
                // Only an interrupted transfer, or one waiting for a decision about its name, keeps its bytes
                // on the server: not a cancellation, and not a refusal that Retry would only repeat.
                if let index = self.index(item.id), self.items[index].partialVersion != nil,
                   !Self.allowsResume(after: error) || self.items[index].state == .cancelled {
                    self.cleanups.append((self.items[index], service))
                    self.items[index].partialVersion = nil; self.items[index].sentBytes = 0
                }
            }
            self.contexts.removeValue(forKey: item.id)
            await self.finishWorker(service)
        }
        publish()
    }

    private static func close(_ service: any RemoteFileUploading, lockingKeys: Bool) async {
        if !lockingKeys, let closer = service as? any RemoteFileSessionClosing { await closer.closeSessionPreservingUnlockedIdentities() }
        else { await (service as? any RemoteFileService)?.disconnect() }
    }

    /// Persist which source version the server's partial copy holds before any of its bytes are sent,
    /// so bytes kept after an interruption are never attributed to a different version.
    private func recordStart(version: TransferSourceVersion, offset: UInt64, id: UUID) {
        guard let index = index(id), items[index].state == .transferring else { return }
        // Kept even for a source that can't be continued from: it marks that the server holds a partial
        // copy, which a cancellation or removal then asks it to drop.
        items[index].partialVersion = version
        items[index].sentBytes = offset
        // What is being sent is this version. A size read from a folder's list some time ago may not be its.
        items[index].expectedBytes = version.size
        publish()
    }
    static func allowsResume(after error: Error) -> Bool {
        switch error {
        case RemoteUploadError.destinationExists: return true // The bytes are there; only the name is undecided.
        case is RemoteUploadError, is TransferManagerError, is OriginalFileExportError, is RemoteDocumentLinkError, is RemoteResourceError: return false
        case RemoteFileError.tooLarge, RemoteFileError.notFound, RemoteFileError.permissionDenied,
             RemoteFileError.invalidPath, RemoteFileError.unsupportedFile: return false
        default: return true
        }
    }
    private func updateProgress(_ progress: DownloadProgress, id: UUID) {
        guard let index = index(id), items[index].state == .transferring else { return }
        items[index].sentBytes = progress.receivedBytes
        // The partial copy is on the server, so after the app is closed mid-transfer the saved count is all
        // the list has to show for it. It is saved every couple of seconds, not for every confirmation, and
        // can only be short of what the server holds, which is what Retry measures and continues from.
        if ContinuousClock.now - lastProgressSave >= progressSaveInterval {
            lastProgressSave = .now
            persist()
        }
        didChange?()
    }
    private func publish() { persist(); didChange?() }
    static let listName = "transfers.json", unsavedListName = "transfers-unsaved.json"
    /// What is saved: the list, and a count that rises with every save.
    struct SavedList: Codable { var revision: UInt64; var items: [ManagedTransfer] }
    private var revision: UInt64 = 0
    /// Nil only if there is no such file: one that is there and can't be looked at or read throws, so that
    /// it is never taken for absent. A bare list, saved before saves were counted, is older than any counted one.
    static func readList(_ url: URL) throws -> SavedList? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 8 * 1024 * 1024 else { throw TransferManagerError.queueFull }
        let bytes = try Data(contentsOf: url)
        if let saved = try? JSONDecoder().decode(SavedList.self, from: bytes) { return saved }
        return SavedList(revision: 0, items: try JSONDecoder().decode([ManagedTransfer].self, from: bytes))
    }
    /// Writes the saved list. Replaced in tests to stand for a locked device, which refuses it.
    var writeList: (Data, URL) throws -> Void = { bytes, url in
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
    private func persist() {
        revision += 1
        guard let bytes = try? JSONEncoder().encode(SavedList(revision: revision, items: items)) else { return }
        let unsaved = directory.appendingPathComponent(Self.unsavedListName)
        do {
            try writeList(bytes, directory.appendingPathComponent(Self.listName))
            persistenceError = nil
            try? FileManager.default.removeItem(at: unsaved)
        } catch {
            persistenceError = error.localizedDescription
            // The list is protected while the device is locked and can't be rewritten then, and a transfer
            // can finish then. So that the app being closed before the device is unlocked doesn't lose what
            // the transfer did, the list is written to a file of the class that may be created while locked
            // and is as closed as the list once written. The next launch opens it if its count is the
            // higher; the next save removes it, and if that removal fails its count is by then the lower.
            // If this write fails too, as on a full disk, the change is in memory only until a save succeeds.
            #if os(iOS)
            try? bytes.write(to: unsaved, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
            try? bytes.write(to: unsaved, options: .atomic)
            #endif
        }
    }
    private static func makePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var directory = directory; try directory.setResourceValues(values)
        #if os(iOS)
        // A staged file is read by a transfer that may continue while the device is locked.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: directory.path)
        #endif
    }
}
