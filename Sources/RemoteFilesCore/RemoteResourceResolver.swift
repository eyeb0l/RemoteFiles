import Foundation
import Crypto

public struct RemoteDocumentLocation: Hashable, Sendable {
    public let profile: ConnectionProfile
    public let path: String
    /// Automatic Markdown resources are confined to the document's directory tree.
    public var resourceRoot: String { RemotePath.parent(of: path) }
    public init(profile: ConnectionProfile, path: String) { self.profile = profile; self.path = path }
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
    case outsideDocument, notImage
    case missingFile(String)
    public var errorDescription: String? {
        switch self {
        case .outsideDocument: return "This image link points outside the document’s folder. Open its folder directly to access it."
        case .notImage: return "This file is not a supported image, or its image data is damaged."
        case .missingFile(let path): return "File not found at:\n\(path)\n\nIt may have been moved or deleted."
        }
    }
}

/// Resource resolution has no Markdown or image-decoder dependency. Future local links can
/// use the same normalized remote address without granting web/file URLs network access.
public protocol RemoteResourceResolving: Sendable {
    func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL
    func localFileForOpening(for reference: String, in document: RemoteDocumentLocation) async throws -> URL
    func invalidate(_ reference: String, in document: RemoteDocumentLocation) async
}
public extension RemoteResourceResolving {
    func localFileForOpening(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        try await localFile(for: reference, in: document)
    }
    func invalidate(_ reference: String, in document: RemoteDocumentLocation) async {}
}

/// Disk bytes only: 256 MiB LRU, 24-hour retention, 5-minute freshness, 128 MiB per file.
/// At most two streaming transfers. A flight owns multiple cancellable consumers; the last
/// consumer leaving cancels that flight. The transport owns its SFTP operation channel.
public actor RemoteResourceResolver: RemoteResourceResolving {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
    }
    private let service: any RemoteFileService
    private let directory: URL
    private let diskLimit: Int
    private let fileLimit: Int
    private let freshness: TimeInterval
    private var flights: [String: Flight] = [:]
    private var transfers = 0
    public init(service: any RemoteFileService, directory: URL, diskLimit: Int = 256 * 1024 * 1024,
                fileLimit: Int = 128 * 1024 * 1024, freshness: TimeInterval = 300) {
        self.service = service; self.directory = directory; self.diskLimit = diskLimit
        self.fileLimit = fileLimit; self.freshness = freshness
    }
    public func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        try Task.checkCancellation()
        let path = try RemoteResourcePath.resolve(reference, relativeTo: document)
        let key = try cacheKey(path: path, document: document)
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                if flights[key] != nil { flights[key]!.waiters[waiter] = continuation; return }
                let id = UUID()
                let task = Task {
                    let result: Result<URL, Error>
                    do { result = .success(try await self.fetch(key: key, path: path, document: document)) }
                    catch { result = .failure(error) }
                    self.finish(key: key, id: id, result: result)
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: { Task { await self.cancel(key: key, waiter: waiter) } }
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
    private func cacheKey(path: String, document: RemoteDocumentLocation) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(document.profile)
        return SHA256.hash(data: data + Data(("\n" + document.resourceRoot + "\n" + path).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func invalidate(_ reference: String, in document: RemoteDocumentLocation) {
        guard let path = try? RemoteResourcePath.resolve(reference, relativeTo: document),
              let key = try? cacheKey(path: path, document: document) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key).appendingPathExtension("resource"))
    }
    public func clearCache() {
        cancelAll()
        try? FileManager.default.removeItem(at: directory)
    }
    private func cancel(key: String, waiter: UUID) {
        guard let continuation = flights[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if flights[key]?.waiters.isEmpty == true { flights.removeValue(forKey: key)?.task.cancel() }
    }
    private func finish(key: String, id: UUID, result: Result<URL, Error>) {
        guard flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }
    public func cancelAll() {
        let old = flights; flights.removeAll()
        for flight in old.values {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }
    private func fetch(key: String, path: String, document: RemoteDocumentLocation) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var cacheDirectory = directory; try? cacheDirectory.setResourceValues(excluded)
        let target = directory.appendingPathComponent(key).appendingPathExtension("resource")
        if let attrs = try? fm.attributesOfItem(atPath: target.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < freshness {
            try? fm.setAttributes([.creationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        while transfers >= 2 { try await Task.sleep(for: .milliseconds(25)) }
        try Task.checkCancellation()
        transfers += 1
        defer { transfers -= 1 }
        let temp = directory.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? fm.removeItem(at: temp) }
        do {
            _ = try await service.downloadFile(profile: document.profile, path: path, allowedRoot: document.resourceRoot,
                                               destination: temp, limit: fileLimit)
        } catch RemoteFileError.notFound {
            throw RemoteResourceError.missingFile(path)
        }
        try Task.checkCancellation()
        let size = (try fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= diskLimit else { throw RemoteFileError.tooLarge(diskLimit) }
        try? fm.removeItem(at: target)
        trim(reserving: size)
        try fm.moveItem(at: temp, to: target)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
        #endif
        return target
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
