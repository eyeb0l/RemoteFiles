import Foundation
import Crypto

public struct RemoteDocumentLocation: Hashable, Sendable {
    public let profile: ConnectionProfile
    public let path: String
    public let canonicalRoot: String?
    /// Automatic Markdown resources are confined to the document's directory tree.
    public var resourceRoot: String { RemotePath.parent(of: path) }
    public init(profile: ConnectionProfile, path: String, canonicalRoot: String? = nil) {
        self.profile = profile; self.path = path; self.canonicalRoot = canonicalRoot
    }
}

public enum RemoteResourcePath {
    public static func resolve(_ reference: String, relativeTo document: RemoteDocumentLocation) throws -> String {
        let decoded = try decodedPath(reference, in: document)
        var relative = decoded
        if decoded.hasPrefix("/") {
            guard contains(decoded, in: document.resourceRoot) else { throw RemoteResourceError.outsideDocument }
            relative = String(decoded.dropFirst(document.resourceRoot == "/" ? 1 : document.resourceRoot.count + 1))
        }
        let parts = try normalizedParts(relative, startingAt: [])
        guard !parts.isEmpty else { throw RemoteResourceError.outsideDocument }
        return RemotePath.appending(parts.joined(separator: "/"), to: document.resourceRoot)
    }

    /// Metadata lookup only, after an explicit Open file action. The returned path
    /// does not grant permission to download outside the document's directory tree.
    public static func pathForExistenceCheck(_ reference: String, relativeTo document: RemoteDocumentLocation) throws -> String {
        let decoded = try decodedPath(reference, in: document)
        let base = decoded.hasPrefix("/") ? [] : document.resourceRoot.split(separator: "/").map(String.init)
        let parts = try normalizedParts(decoded, startingAt: base)
        guard !parts.isEmpty else { throw RemoteResourceError.outsideDocument }
        return "/" + parts.joined(separator: "/")
    }

    private static func decodedPath(_ reference: String, in document: RemoteDocumentLocation) throws -> String {
        guard let components = URLComponents(string: reference), components.scheme == nil,
              components.host == nil, components.query == nil, components.fragment == nil,
              !reference.hasPrefix("//"), !reference.hasPrefix("\\"),
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              !decoded.isEmpty, !decoded.hasPrefix("//"), !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              document.path.hasPrefix("/") else { throw RemoteResourceError.outsideDocument }
        return decoded
    }

    private static func normalizedParts(_ path: String, startingAt base: [String]) throws -> [String] {
        var parts = base
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { throw RemoteResourceError.outsideDocument }
                parts.removeLast()
            } else { parts.append(String(part)) }
        }
        return parts
    }
    public static func contains(_ path: String, in root: String) -> Bool {
        // SFTP paths are UTF-8 byte names; String equality folds Unicode normalization.
        let pathBytes = Array(path.utf8), rootBytes = Array(root.utf8)
        return pathBytes == rootBytes || pathBytes.starts(with: root == "/" ? rootBytes : rootBytes + [47])
    }
}

public enum RemoteResourceError: LocalizedError, Sendable {
    case outsideDocument, notImage, insecureCache
    case missingFile(String)
    public var errorDescription: String? {
        switch self {
        case .outsideDocument: return "This image link points outside the document’s folder. Open its folder directly to access it."
        case .notImage: return "This file is not a supported image, or its image data is damaged."
        case .insecureCache: return "The protected image cache is unavailable."
        case .missingFile(let path): return "File not found at:\n\(path)\n\nIt may have been moved or deleted."
        }
    }
}

/// Resource resolution has no Markdown or image-decoder dependency. Future local links can
/// use the same normalized remote address without granting web/file URLs network access.
public protocol RemoteResourceResolving: Sendable {
    func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL
    func localFile(for reference: String, in document: RemoteDocumentLocation, progress: @escaping DownloadProgressHandler) async throws -> URL
    func localFileForOpening(for reference: String, in document: RemoteDocumentLocation) async throws -> URL
    func invalidate(_ reference: String, in document: RemoteDocumentLocation) async
}
public extension RemoteResourceResolving {
    func localFile(for reference: String, in document: RemoteDocumentLocation, progress: @escaping DownloadProgressHandler) async throws -> URL {
        try await localFile(for: reference, in: document)
    }
    func localFileForOpening(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        try await localFile(for: reference, in: document)
    }
    func invalidate(_ reference: String, in document: RemoteDocumentLocation) async {}
}

/// Disk bytes only: 256 MiB LRU, 24-hour retention, 5-minute freshness, 128 MiB per file.
/// After the freshness window, a copy whose remote size and modification time still match is
/// revalidated with one metadata request instead of being transferred again.
/// At most two streaming transfers; others wait in arrival order. A flight owns multiple cancellable consumers; the last
/// consumer leaving cancels that flight. The transport owns its SFTP operation channel.
public actor RemoteResourceResolver: RemoteResourceResolving {
    /// All resolver instances in this process share the cache. Prefixing active
    /// partials prevents one window's first-use sweep from deleting another
    /// window's in-flight transfer while still identifying prior-process debris.
    private static let partialProcessPrefix = UUID().uuidString + "-"
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
        var observers: [UUID: DownloadProgressHandler]
    }
    private let service: any RemoteFileService
    private let directory: URL
    private let diskLimit: Int
    private let fileLimit: Int
    private let freshness: TimeInterval
    private var flights: [String: Flight] = [:]
    // A refresh separates new consumers from an older transfer without cancelling it.
    private var generations: [String: UUID] = [:]
    private var transfers = 0
    private var cleanedAbandonedPartials = false
    // Fetches waiting for a transfer slot, oldest first. A released slot passes straight to the next one.
    private var slotWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    public init(service: any RemoteFileService, directory: URL, diskLimit: Int = 256 * 1024 * 1024,
                fileLimit: Int = 128 * 1024 * 1024, freshness: TimeInterval = 300) {
        self.service = service; self.directory = directory; self.diskLimit = diskLimit
        self.fileLimit = fileLimit; self.freshness = freshness
    }
    public func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        try await localFile(for: reference, in: document, progress: { _ in })
    }
    public func localFile(for reference: String, in document: RemoteDocumentLocation, progress: @escaping DownloadProgressHandler) async throws -> URL {
        try Task.checkCancellation()
        let path = try RemoteResourcePath.resolve(reference, relativeTo: document)
        let key = try cacheKey(path: path, document: document)
        let generation = generations[key]
        let flightKey = key + ":" + (generation?.uuidString ?? "initial")
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if flights[flightKey] != nil {
                    flights[flightKey]!.waiters[waiter] = continuation
                    flights[flightKey]!.observers[waiter] = progress
                    return
                }
                let id = UUID()
                let task = Task {
                    let result: Result<URL, Error>
                    do { result = .success(try await self.fetch(key: key, flightKey: flightKey, generation: generation, id: id, path: path, document: document)) }
                    catch { result = .failure(error) }
                    self.finish(key: flightKey, id: id, result: result)
                }
                flights[flightKey] = Flight(id: id, task: task, waiters: [waiter: continuation], observers: [waiter: progress])
            }
        } onCancel: { Task { await self.cancel(key: flightKey, waiter: waiter) } }
    }
    public func localFileForOpening(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        try Task.checkCancellation()
        let path = try RemoteResourcePath.pathForExistenceCheck(reference, relativeTo: document)
        do {
            _ = try await service.resolveEntry(profile: document.profile, path: path)
        } catch RemoteFileError.notFound {
            throw RemoteResourceError.missingFile(path)
        }
        try Task.checkCancellation()
        // Existence is checked even for stale absolute links. Bytes still use the
        // original boundary and canonical server check; this is not a bypass.
        return try await localFile(for: reference, in: document)
    }
    /// Keys on what determines the bytes: the account that read them and the remote location.
    /// Renaming a connection or editing its starting folder keeps its cached resources, while a
    /// different endpoint, account, identity or jump route never shares them. JSON keeps fields unambiguous.
    private func cacheKey(path: String, document: RemoteDocumentLocation) throws -> String {
        let profile = document.profile
        let endpoint = HostEndpoint(host: profile.host, port: profile.port)
        var fields = [endpoint.host, String(endpoint.port), profile.username, profile.identityID.uuidString,
                      document.resourceRoot, path]
        if let root = document.canonicalRoot { fields += ["canonical-search-root", root] }
        // A private hostname can identify different filesystems through different bastions.
        // Keep direct keys unchanged, but never reuse their bytes for a tunneled route.
        if let hop = profile.jumpHost {
            let jump = HostEndpoint(host: hop.host, port: hop.port)
            fields += ["jump-host", jump.host, String(jump.port), hop.username, hop.identityID.uuidString]
        }
        return SHA256.hash(data: try JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
    public func invalidate(_ reference: String, in document: RemoteDocumentLocation) {
        _ = invalidateResources([reference], in: document)
    }
    /// Invalidates only the supplied document references. Supply all references in the
    /// refreshed document, including resources not yet displayed in this process.
    /// Shared resources refresh for future readers, while existing transfers finish
    /// for their consumers and cannot publish stale bytes over a newer generation.
    /// Returned URLs identify decoded-image cache entries to invalidate as well.
    @discardableResult
    public func invalidateResources(_ references: [String], in document: RemoteDocumentLocation) -> [URL] {
        var invalidated = Set<String>()
        var files: [URL] = []
        for reference in references {
            guard let path = try? RemoteResourcePath.resolve(reference, relativeTo: document),
                  let key = try? cacheKey(path: path, document: document),
                  invalidated.insert(key).inserted else { continue }
            // Generation metadata is needed only while an older flight can publish.
            // Idle resources use their stable on-disk key across resolver launches.
            generations[key] = flights.keys.contains { $0.hasPrefix(key + ":") } ? UUID() : nil
            let file = directory.appendingPathComponent(key).appendingPathExtension("resource")
            try? FileManager.default.removeItem(at: file)
            files.append(file)
        }
        return files
    }
    public func clearCache() {
        cancelAll()
        try? FileManager.default.removeItem(at: directory)
        cleanedAbandonedPartials = false
    }
    private func cancel(key: String, waiter: UUID) {
        guard let continuation = flights[key]?.waiters.removeValue(forKey: waiter) else { return }
        flights[key]?.observers.removeValue(forKey: waiter)
        continuation.resume(throwing: CancellationError())
        if flights[key]?.waiters.isEmpty == true {
            flights.removeValue(forKey: key)?.task.cancel()
            removeGenerationIfIdle(for: key)
        }
    }
    private func finish(key: String, id: UUID, result: Result<URL, Error>) {
        guard flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
        removeGenerationIfIdle(for: key)
    }
    private func removeGenerationIfIdle(for flightKey: String) {
        guard let key = flightKey.split(separator: ":").first.map(String.init),
              !flights.keys.contains(where: { $0.hasPrefix(key + ":") }) else { return }
        generations.removeValue(forKey: key)
    }
    public func cancelAll() {
        let old = flights; flights.removeAll(); generations.removeAll()
        for flight in old.values {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }
    private func report(_ progress: DownloadProgress, key: String, id: UUID) async {
        guard let flight = flights[key], flight.id == id else { return }
        for (waiter, observer) in flight.observers {
            guard flights[key]?.id == id, flights[key]?.observers[waiter] != nil else { continue }
            await observer(progress)
        }
    }
    private func fetch(key: String, flightKey: String, generation: UUID?, id: UUID, path: String, document: RemoteDocumentLocation) async throws -> URL {
        let fm = FileManager.default
        try prepareCacheDirectory()
        let target = directory.appendingPathComponent(key).appendingPathExtension("resource")
        let targetAttributes = try validateCachedFile(at: target)
        // Saved results recheck their canonical boundary on every opening, even when an
        // ordinary preview or a previous search opening has already cached these bytes.
        if document.canonicalRoot == nil, let attrs = targetAttributes,
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < freshness {
            try? fm.setAttributes([.creationDate: Date()], ofItemAtPath: target.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            await report(.init(receivedBytes: size, totalBytes: size, isComplete: true), key: flightKey, id: id)
            try Task.checkCancellation()
            if generations[key] == generation, fm.fileExists(atPath: target.path) { return target }
        } else if document.canonicalRoot == nil, targetAttributes != nil, let cached = Self.storedVersion(at: target),
                  let current = try? await service.resolveEntry(profile: document.profile, path: path),
                  current.kind == .file, RemoteResourcePath.contains(current.path, in: document.resourceRoot),
                  RemoteFileVersion(size: current.size, modifiedAt: current.modifiedAt) == cached {
            // A canonical path outside the non-canonical root simply downloads, which rechecks the boundary.
            try Task.checkCancellation()
            if generations[key] == generation, fm.fileExists(atPath: target.path) {
                try? fm.setAttributes([.modificationDate: Date(), .creationDate: Date()], ofItemAtPath: target.path)
                let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.uint64Value ?? 0
                await report(.init(receivedBytes: size, totalBytes: size, isComplete: true), key: flightKey, id: id)
                try Task.checkCancellation()
                return target
            }
        }
        try await acquireTransferSlot()
        defer { releaseTransferSlot() }
        try Task.checkCancellation()
        let temp = directory.appendingPathComponent(Self.partialProcessPrefix + UUID().uuidString + ".partial")
        defer { try? fm.removeItem(at: temp) }
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RemoteResourceError.insecureCache
        }
        try protectCacheFile(temp)
        let downloaded: RemoteEntry
        do {
            if let root = document.canonicalRoot {
                downloaded = try await service.downloadSnapshotFile(profile: document.profile, path: path, canonicalRoot: root,
                    destination: temp, limit: fileLimit, progress: { update in
                        await self.report(update, key: flightKey, id: id)
                    })
            } else {
                downloaded = try await service.downloadFile(profile: document.profile, path: path, allowedRoot: document.resourceRoot,
                                                        destination: temp, limit: fileLimit, progress: { update in
                                                            await self.report(update, key: flightKey, id: id)
                                                        })
            }
        } catch RemoteFileError.notFound {
            throw RemoteResourceError.missingFile(path)
        }
        try Task.checkCancellation()
        let size = (try fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= diskLimit else { throw RemoteFileError.tooLarge(diskLimit) }
        // An invalidated transfer still belongs to its original consumers. Keep its
        // result at a separate URL so it cannot replace the current cached resource.
        let destination = generations[key] == generation ? target :
            directory.appendingPathComponent(key + "-" + id.uuidString).appendingPathExtension("resource")
        try? fm.removeItem(at: destination)
        trim(reserving: size)
        if let version = RemoteFileVersion(size: downloaded.size, modifiedAt: downloaded.modifiedAt) {
            Self.storeVersion(version, at: temp)
        }
        try fm.moveItem(at: temp, to: destination)
        do {
            try protectCacheFile(destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// The cache may outlive the process, so its containment and protection are
    /// checked before every hit or transfer. Partial files can only belong to a
    /// previous resolver lifetime when the first operation starts.
    private func prepareCacheDirectory() throws {
        let fm = FileManager.default
        if let mode = try Self.fileMode(at: directory) {
            guard mode & S_IFMT == S_IFDIR else {
                throw RemoteResourceError.insecureCache
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        guard let directoryMode = try Self.fileMode(at: directory), directoryMode & S_IFMT == S_IFDIR else {
            throw RemoteResourceError.insecureCache
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var cacheDirectory = directory
        try cacheDirectory.setResourceValues(values)

        let protected = try fm.attributesOfItem(atPath: directory.path)
        guard ((protected[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o700,
              try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw RemoteResourceError.insecureCache
        }
        #if os(iOS)
        #if targetEnvironment(simulator)
        guard (protected[.protectionKey] as? FileProtectionType).map({ $0 == .complete }) ?? true else {
            throw RemoteResourceError.insecureCache
        }
        #else
        guard protected[.protectionKey] as? FileProtectionType == .complete else {
            throw RemoteResourceError.insecureCache
        }
        #endif
        #endif

        if !cleanedAbandonedPartials {
            for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where child.pathExtension == "partial"
                    && !child.lastPathComponent.hasPrefix(Self.partialProcessPrefix) {
                do {
                    try fm.removeItem(at: child)
                } catch let error as NSError
                    where (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
                        || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
                    // Another resolver may have enumerated and removed the same
                    // stale prior-process entry concurrently.
                }
            }
            cleanedAbandonedPartials = true
        }
    }

    /// Returns secure attributes for a reusable regular file. Non-regular cache
    /// entries are discarded without following them and treated as a miss.
    private func validateCachedFile(at url: URL) throws -> [FileAttributeKey: Any]? {
        let fm = FileManager.default
        guard let mode = try Self.fileMode(at: url) else { return nil }
        guard mode & S_IFMT == S_IFREG else {
            try fm.removeItem(at: url)
            return nil
        }
        try protectCacheFile(url)
        return try fm.attributesOfItem(atPath: url.path)
    }

    private func protectCacheFile(_ url: URL) throws {
        let fm = FileManager.default
        guard let initialMode = try Self.fileMode(at: url), initialMode & S_IFMT == S_IFREG else {
            throw RemoteResourceError.insecureCache
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let finalMode = try Self.fileMode(at: url), finalMode & S_IFMT == S_IFREG,
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777 == 0o600 else {
            throw RemoteResourceError.insecureCache
        }
        #if os(iOS)
        #if targetEnvironment(simulator)
        guard (attributes[.protectionKey] as? FileProtectionType).map({ $0 == .complete }) ?? true else {
            throw RemoteResourceError.insecureCache
        }
        #else
        guard attributes[.protectionKey] as? FileProtectionType == .complete else {
            throw RemoteResourceError.insecureCache
        }
        #endif
        #endif
    }

    /// `FileManager` metadata may follow links on some filesystems. `lstat`
    /// keeps cache validation anchored to the directory entry itself.
    private static func fileMode(at url: URL) throws -> mode_t? {
        var metadata = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        if result == 0 { return metadata.st_mode }
        if errno == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    private func acquireTransferSlot() async throws {
        try Task.checkCancellation()
        if transfers < 2 { transfers += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                slotWaiters.append((id: id, continuation: continuation))
            }
        } onCancel: { Task { await self.cancelTransferWait(id) } }
    }
    /// A cancelled waiter leaves the queue without taking a slot. If a slot reached it first,
    /// the caller's cancellation check releases that slot to the next waiter.
    private func cancelTransferWait(_ id: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        slotWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func releaseTransferSlot() {
        if slotWaiters.isEmpty { transfers -= 1 } else { slotWaiters.removeFirst().continuation.resume() }
    }
    private static let versionAttribute = "dev.iris.RemoteFiles.remote-version"

    /// The remote version travels with the cached file as an extended attribute, so a rename keeps it.
    private static func storeVersion(_ version: RemoteFileVersion, at url: URL) {
        let value = Array("\(version.size) \(version.modifiedAt.timeIntervalSince1970)".utf8)
        _ = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path, versionAttribute, value, value.count, 0, 0)
        }
    }

    private static func storedVersion(at url: URL) -> RemoteFileVersion? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return getxattr(path, versionAttribute, &buffer, buffer.count, 0, 0)
        }
        guard length > 0 else { return nil }
        let fields = String(decoding: buffer.prefix(length), as: UTF8.self).split(separator: " ")
        guard fields.count == 2, let size = UInt64(fields[0]), let seconds = Double(fields[1]) else { return nil }
        return RemoteFileVersion(size: size, modifiedAt: Date(timeIntervalSince1970: seconds))
    }

    private func trim(reserving size: Int) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var entries: [(URL, Int, Date)] = []
        for url in urls {
            guard let a = try? fm.attributesOfItem(atPath: url.path), let modified = a[.modificationDate] as? Date else { continue }
            // Don't unlink a currently streaming file; abandoned partials are cleaned next launch/use.
            if Date().timeIntervalSince(modified) > 86400 { try? fm.removeItem(at: url); continue }
            if url.pathExtension == "resource" { entries.append((url, (a[.size] as? NSNumber)?.intValue ?? 0, a[.creationDate] as? Date ?? modified)) }
        }
        var total = entries.reduce(size) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > diskLimit {
            try? fm.removeItem(at: entry.0); total -= entry.1
        }
    }
}
