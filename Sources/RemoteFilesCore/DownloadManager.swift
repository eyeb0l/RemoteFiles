import Foundation
import Observation

/// Opt-in transport cleanup for a completed foreground job. Explicit disconnect
/// and background lifecycle still clear unlocked identities.
public protocol RemoteFileSessionClosing: Sendable {
    func closeSessionPreservingUnlockedIdentities() async
}

public enum ManagedDownloadState: String, Codable, Sendable {
    case queued, downloading, pendingFinalization, completed, cancelled, interrupted, failed
}

public struct ManagedDownload: Identifiable, Codable, Sendable {
    public let id: UUID
    public let profile: ConnectionProfile
    public let path: String
    /// A saved index's original canonical boundary, retained across retries and relaunches.
    /// Missing in older manifests means an ordinary folder-selected download.
    public let canonicalRoot: String?
    public let filename: String
    public let expectedBytes: UInt64?
    public var state: ManagedDownloadState
    public var receivedBytes: UInt64
    public var message: String?
    /// Fully received files retain their storage reservation while protection is pending.
    public var retainsDownloadedBytes: Bool { state == .completed || state == .pendingFinalization }
    public var progress: DownloadProgress {
        .init(receivedBytes: receivedBytes, totalBytes: expectedBytes, isComplete: state == .completed)
    }
}

public enum DownloadManagerError: LocalizedError {
    case queueFull, storageFull, unavailable
    public var errorDescription: String? {
        switch self {
        case .queueFull: return "The download list is full. Remove an item before adding another."
        case .storageFull: return "Downloads use at most 512 MB. Remove a completed download to make room."
        case .unavailable: return "This download is not available. Download it again."
        }
    }
}

/// A bounded, persistent queue of original bytes. Only one worker runs at a time;
/// cancellation keeps that slot occupied until the transport actually drains.
@MainActor @Observable
public final class DownloadManager {
    private static var sharedManagers: [String: DownloadManager] = [:]
    public static func shared(directory: URL) throws -> DownloadManager {
        let key = directory.standardizedFileURL.path
        if let manager = sharedManagers[key] { return manager }
        let manager = try DownloadManager(directory: directory)
        sharedManagers[key] = manager
        return manager
    }
    public static let maximumFileBytes = 128 * 1024 * 1024
    public static let maximumStoredBytes = 512 * 1024 * 1024
    public static let maximumItems = 100
    public private(set) var items: [ManagedDownload] = []
    public private(set) var persistenceError: String?
    public private(set) var activeID: UUID?
    public var didChange: (() -> Void)?
    private let service: (any RemoteFileService)?
    private let directory: URL
    private let fileLimit: Int
    private let totalLimit: Int
    private var worker: Task<Void, Never>?
    private struct JobContext {
        let service: any RemoteFileService
        let onFailure: ((Error, ConnectionProfile) -> Void)?
    }
    private var contexts: [UUID: JobContext] = [:]
    private var sceneStates: [UUID: Bool] = [:]
    private static let defaultSceneID = UUID()
    public var isForeground: Bool { sceneStates.isEmpty ? !hadScenes : sceneStates.values.contains(true) }
    private var hadScenes = false
    private var cleanupBlockedIDs: Set<UUID> = []
    /// Injectable failure seam for filesystem regression tests.
    var removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    /// The app supplies the protected-data state; deterministic fixtures can inject lock races.
    public var protectedDataAvailable: () -> Bool = { true }
    var protectCompletedFile: (URL) throws -> Void = { url in
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
    private var stopped = false

    public init(service: (any RemoteFileService)? = nil, directory: URL,
                fileLimit: Int = maximumFileBytes, totalLimit: Int = maximumStoredBytes) throws {
        self.service = service; self.directory = directory
        self.fileLimit = min(max(1, fileLimit), Self.maximumFileBytes)
        self.totalLimit = min(max(1, totalLimit), Self.maximumStoredBytes)
        try Self.makePrivateDirectory(directory)
        let manifest = directory.appendingPathComponent("downloads.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: manifest.path)
            guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 2 * 1024 * 1024 else { throw DownloadManagerError.queueFull }
            let bytes = try Data(contentsOf: manifest)
            guard bytes.count <= 2 * 1024 * 1024 else { throw DownloadManagerError.queueFull }
            items = try JSONDecoder().decode([ManagedDownload].self, from: bytes)
            guard items.count <= Self.maximumItems, Set(items.map(\.id)).count == items.count,
                  items.allSatisfy({ Self.validFilename($0.filename) && $0.receivedBytes <= UInt64(self.fileLimit) }) else { throw DownloadManagerError.unavailable }
            for index in items.indices {
                if items[index].state == .downloading || items[index].state == .queued {
                    items[index].state = .interrupted
                    items[index].message = "The app stopped before this download finished. Retry to start again."
                }
                if !items[index].retainsDownloadedBytes { try removeDirectory(jobDirectory(items[index].id)) }
                else {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(items[index]).path)
                    let size = (attributes?[.size] as? NSNumber)?.uint64Value
                    if attributes?[.type] as? FileAttributeType != .typeRegular || size != items[index].receivedBytes {
                        items[index].state = .failed; items[index].message = "The saved file is missing or changed. Retry to download it again."
                        try removeDirectory(jobDirectory(items[index].id))
                    }
                }
            }
        }
        let retainedBytes = items.filter { $0.retainsDownloadedBytes }.reduce(UInt64(0)) { $0 + $1.receivedBytes }
        guard retainedBytes <= UInt64(self.totalLimit) else { throw DownloadManagerError.storageFull }
        let retained = Set(items.filter { $0.retainsDownloadedBytes }.map { $0.id.uuidString })
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if UUID(uuidString: child.lastPathComponent) != nil, !retained.contains(child.lastPathComponent) {
                try removeDirectory(child)
            }
        }
        persist()
    }

    @discardableResult public func enqueue(profile: ConnectionProfile, entry: RemoteEntry,
                        service: (any RemoteFileService)? = nil,
                        onFailure: ((Error, ConnectionProfile) -> Void)? = nil) throws -> UUID {
        guard entry.kind == .file || entry.kind == .symlink else { throw OriginalFileExportError.notRegularFile }
        let filename = entry.exportFilename ?? entry.name
        guard Self.validFilename(filename) else { throw OriginalFileExportError.invalidFilename }
        guard items.count < Self.maximumItems else { throw DownloadManagerError.queueFull }
        if let bytes = entry.size, bytes > UInt64(fileLimit) { throw OriginalFileExportError.tooLarge(fileLimit) }
        guard let transport = service ?? self.service else { throw DownloadManagerError.unavailable }
        let id = UUID()
        items.append(.init(id: id, profile: profile, path: entry.path, canonicalRoot: entry.canonicalRoot,
                           filename: filename, expectedBytes: entry.size,
                           state: .queued, receivedBytes: 0, message: nil))
        contexts[id] = .init(service: transport, onFailure: onFailure)
        stopped = false; publish(); startNext()
        return id
    }

    public func retry(_ id: UUID, profile: ConnectionProfile, service: (any RemoteFileService)? = nil,
                      onFailure: ((Error, ConnectionProfile) -> Void)? = nil) throws {
        guard let index = index(id), activeID != id, !items[index].retainsDownloadedBytes else { return }
        guard items[index].profile == profile else { throw DownloadManagerError.unavailable }
        guard let transport = service ?? self.service else { throw DownloadManagerError.unavailable }
        try removeDirectory(jobDirectory(id)); cleanupBlockedIDs.remove(id)
        contexts[id] = .init(service: transport, onFailure: onFailure)
        items[index].state = .queued; items[index].message = nil; items[index].receivedBytes = 0
        stopped = false; publish(); startNext()
    }

    public func cancel(_ id: UUID) {
        guard let index = index(id), items[index].state == .queued || items[index].state == .downloading else { return }
        items[index].state = .cancelled; items[index].message = nil
        if activeID == id { worker?.cancel() } else { contexts.removeValue(forKey: id) }
        publish()
    }

    public func remove(_ id: UUID) throws {
        guard activeID != id else { cancel(id); return }
        try removeDirectory(jobDirectory(id))
        cleanupBlockedIDs.remove(id); contexts.removeValue(forKey: id)
        items.removeAll { $0.id == id }; publish(); startNext()
    }

    public func completedURL(_ id: UUID) throws -> URL {
        guard let item = items.first(where: { $0.id == id }), item.state == .completed,
              FileManager.default.fileExists(atPath: fileURL(item).path) else { throw DownloadManagerError.unavailable }
        return fileURL(item)
    }

    /// Queued work starts only while foregrounded, where trust and unlock prompts can be shown.
    public func setForeground(_ value: Bool, sceneID: UUID? = nil) {
        hadScenes = true
        sceneStates[sceneID ?? Self.defaultSceneID] = value
        if isForeground { finalizePendingDownloads(); startNext() }
    }
    public func removeScene(_ id: UUID) {
        sceneStates.removeValue(forKey: id)
    }

    /// Used for explicit disconnect, background expiration and lock. No automatic reconnect.
    public func interrupt(reason: String) async {
        stopped = true
        for index in items.indices where items[index].state == .queued || items[index].state == .downloading {
            items[index].state = .interrupted; items[index].message = reason
        }
        let activeWorker = worker
        activeWorker?.cancel(); publish()
        let activeService = activeID.flatMap { contexts[$0]?.service }
        // Retire only the contexts present at interruption, before yielding. New work
        // admitted by another foreground window while the old worker drains owns new contexts.
        contexts.removeAll()
        if activeWorker != nil { await activeService?.disconnect() }
        await activeWorker?.value
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    private func jobDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func fileURL(_ item: ManagedDownload) -> URL { jobDirectory(item.id).appendingPathComponent(item.filename) }
    private func startNext() {
        guard worker == nil, isForeground, !stopped, cleanupBlockedIDs.isEmpty,
              let item = items.first(where: { $0.state == .queued }), let index = index(item.id) else { return }
        let used = items.filter { $0.retainsDownloadedBytes }.reduce(UInt64(0)) { $0 + $1.receivedBytes }
        let available = max(0, totalLimit - Int(min(UInt64(totalLimit), used)))
        let limit = min(fileLimit, available)
        guard limit > 0, item.expectedBytes.map({ $0 <= UInt64(limit) }) ?? true else {
            items[index].state = .failed; items[index].message = DownloadManagerError.storageFull.localizedDescription
            contexts.removeValue(forKey: item.id)
            publish(); startNext(); return
        }
        guard let context = contexts[item.id] else { return }
        let service = context.service
        activeID = item.id; items[index].state = .downloading
        worker = Task { [weak self, service] in
            guard let self else { return }
            do {
                try Self.makePrivateDirectory(self.jobDirectory(item.id))
                let target = self.fileURL(item)
                let progress: DownloadProgressHandler = { [weak self] progress in
                    await self?.updateProgress(progress, id: item.id)
                }
                let remote: RemoteEntry
                if let root = item.canonicalRoot {
                    // A saved-index result stays within the index's exact canonical root,
                    // wherever that index was built.
                    if let managed = service as? any ManagedRemoteFileDownloading {
                        remote = try await managed.downloadManagedSnapshotFile(profile: item.profile, path: item.path,
                            canonicalRoot: root, destination: target, limit: limit, progress: progress)
                    } else {
                        remote = try await service.downloadSnapshotFile(profile: item.profile, path: item.path,
                            canonicalRoot: root, destination: target, limit: limit, progress: progress)
                    }
                } else if let managed = service as? any ManagedRemoteFileDownloading {
                    remote = try await managed.downloadManagedFile(profile: item.profile, path: item.path,
                        allowedRoot: RemotePath.parent(of: item.path), destination: target, limit: limit, progress: progress)
                } else {
                    remote = try await service.downloadFile(profile: item.profile, path: item.path,
                        allowedRoot: RemotePath.parent(of: item.path), destination: target, limit: limit, progress: progress)
                }
                try Task.checkCancellation()
                guard remote.kind == .file else { throw OriginalFileExportError.notRegularFile }
                let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(limit) else {
                    throw OriginalFileExportError.tooLarge(limit)
                }
                if let index = self.index(item.id), self.items[index].state == .downloading {
                    self.items[index].receivedBytes = size.uint64Value
                    self.items[index].state = .pendingFinalization
                    try self.finalizeDownload(item.id)
                }
            } catch {
                // Describe a moved or redirected selection in terms of the chosen file. The
                // original error still reaches onFailure, which treats it as a security event.
                let shown: Error = switch error {
                case RemoteDocumentLinkError.outsideConnection, RemoteResourceError.outsideDocument: OriginalFileExportError.outsideRoot
                default: error
                }
                if let index = self.index(item.id),
                   self.items[index].state == .downloading || self.items[index].state == .pendingFinalization {
                    self.items[index].state = error is CancellationError ? .cancelled : .failed
                    self.items[index].message = error is CancellationError ? nil : shown.localizedDescription
                    if !(error is CancellationError) { context.onFailure?(error, item.profile) }
                }
            }
            if self.items.first(where: { $0.id == item.id })?.retainsDownloadedBytes != true {
                do { try self.removeDirectory(self.jobDirectory(item.id)) }
                catch {
                    self.cleanupBlockedIDs.insert(item.id)
                    if let index = self.index(item.id) {
                        self.items[index].message = "Partial download could not be removed. Remove this item before continuing. " + error.localizedDescription
                    }
                }
            }
            // Release the socket without locking another foreground operation's keys.
            if self.isForeground, !self.stopped, let closer = service as? any RemoteFileSessionClosing {
                await closer.closeSessionPreservingUnlockedIdentities()
            } else { await service.disconnect() }
            self.contexts.removeValue(forKey: item.id)
            self.activeID = nil; self.worker = nil; self.publish(); self.startNext()
        }
        publish()
    }
    /// Called on foreground/unlock. Completed network bytes stay private and count
    /// against quota until complete protection can be applied; no network retry occurs.
    public func finalizePendingDownloads() {
        for id in items.filter({ $0.state == .pendingFinalization }).map(\.id) {
            do { try finalizeDownload(id) }
            catch {
                guard let index = index(id) else { continue }
                items[index].state = .failed; items[index].message = error.localizedDescription
                do { try removeDirectory(jobDirectory(id)) }
                catch {
                    cleanupBlockedIDs.insert(id)
                    items[index].message = "Download cleanup failed. Remove this item before continuing. " + error.localizedDescription
                }
            }
        }
        // Retry a manifest write that was denied while locked, including when a file
        // already acquired complete protection before the manifest became unavailable.
        publish()
    }

    private func finalizeDownload(_ id: UUID) throws {
        guard let index = index(id), items[index].state == .pendingFinalization else { return }
        let waiting = "Download received. Unlock this device to finish securing the file."
        guard protectedDataAvailable() else { items[index].message = waiting; return }
        do {
            let url = fileURL(items[index])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.uint64Value == items[index].receivedBytes,
                  size.uint64Value <= UInt64(fileLimit) else { throw DownloadManagerError.unavailable }
            try protectCompletedFile(url)
            items[index].state = .completed; items[index].message = nil
        } catch {
            // The lock can race with the protection update. Other failures still fail
            // closed, so a corrupt/missing/unprotectable file is never exported.
            guard !protectedDataAvailable() else { throw error }
            items[index].message = waiting
        }
    }

    private func updateProgress(_ progress: DownloadProgress, id: UUID) {
        guard let index = index(id), items[index].state == .downloading else { return }
        items[index].receivedBytes = progress.receivedBytes
        // Keep progress out of disk writes: persist at state transitions only.
        didChange?()
    }
    private func publish() { persist(); didChange?() }
    private func persist() {
        do {
            let bytes = try JSONEncoder().encode(items)
            #if os(iOS)
            try bytes.write(to: directory.appendingPathComponent("downloads.json"), options: [.atomic, .completeFileProtection])
            #else
            try bytes.write(to: directory.appendingPathComponent("downloads.json"), options: .atomic)
            #endif
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }
    private func removeDirectory(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try removeItem(url)
    }
    private static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") &&
        !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    private static func makePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var directory = directory; try directory.setResourceValues(values)
        #if os(iOS)
        // An open transfer may continue while locked; completed files become Complete-protected.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: directory.path)
        #endif
    }
}
