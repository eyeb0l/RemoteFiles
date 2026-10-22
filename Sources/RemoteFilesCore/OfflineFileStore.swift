import Foundation
import Crypto
import Darwin

public struct OfflinePin: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let connectionID: UUID
    public let connectionName: String
    public let routeKey: String
    public let path: String
    public let filename: String
    public let previewFilename: String?
    public var documentFilename: String { previewFilename ?? filename }
    public let byteCount: Int
    public let savedAt: Date
    let blobID: UUID
    let digest: String

    public func matches(_ profile: ConnectionProfile, path: String) -> Bool {
        connectionID == profile.id && routeKey == Self.routeKey(profile) && self.path.utf8.elementsEqual(path.utf8)
    }

    /// Display names and setup tips do not change a route. Accounts, keys, roots and bastions do.
    public static func routeKey(_ profile: ConnectionProfile) -> String {
        var parts = [profile.id.uuidString, profile.host.lowercased(), String(profile.port), profile.username,
                     profile.identityID.uuidString, profile.startingDirectory]
        if let hop = profile.jumpHost {
            parts += ["jump", hop.host.lowercased(), String(hop.port), hop.username, hop.identityID.uuidString]
        }
        // An array encoding preserves field boundaries, including arbitrary Unicode filenames.
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum OfflineFileError: LocalizedError, Sendable {
    case busy, storageFull, tooManyFiles, metadataTooLarge, missing, damaged, invalidLibrary, tooManyReaders, tooLarge(Int), timedOut
    public var errorDescription: String? {
        switch self {
        case .busy: return "An offline file is already being saved or cancelled. Wait for it to finish."
        case .storageFull: return "Offline storage is full. Remove a saved copy before adding or updating a file."
        case .tooManyFiles: return "The offline file limit has been reached. Remove a saved copy first."
        case .metadataTooLarge: return "The offline library’s file details exceed its storage limit. The previous copies have been kept."
        case .missing: return "This offline copy is missing. Save it again while connected."
        case .damaged: return "This offline copy could not be verified. Update it while connected."
        case .invalidLibrary: return "The offline library could not be read. Its existing files have been kept."
        case .tooManyReaders: return "Close another offline preview before opening this file."
        case .tooLarge(let limit): return "Offline copies are limited to \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) per file."
        case .timedOut: return "Saving this offline copy timed out. Try again while connected."
        }
    }
}

/// A private local lease keeps a preview/share valid when its pin is refreshed or removed.
/// The URL never names a remote resource. The owner must retain this value while reading it.
public final class OfflineFileLease: @unchecked Sendable {
    public let url: URL
    /// The metadata of these exact bytes, even if the pin is refreshed after this lease opens.
    public let pin: OfflinePin
    private let directory: URL
    fileprivate init(url: URL, directory: URL, pin: OfflinePin) { self.url = url; self.directory = directory; self.pin = pin }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class WeakOfflineLease {
    weak var value: OfflineFileLease?
    init(_ value: OfflineFileLease) { self.value = value }
}

/// One actor owns a directory. The app uses `shared` so separate windows cannot overwrite pins.
public actor OfflineFileStore {
    public static let maximumFileBytes = 128 * 1_024 * 1_024
    public static let maximumStoredBytes = 512 * 1_024 * 1_024
    public static let maximumFiles = 100
    private static let maximumIndexBytes = 2 * 1_024 * 1_024
    private struct Manifest: Codable { var version = 1; var pins: [OfflinePin] = [] }
    private let directory: URL
    private let fileLimit: Int
    private let storageLimit: Int
    private let countLimit: Int
    private var pins: [OfflinePin]
    private var operation: UUID?
    private var cancelled = false
    private var exporter: RemoteOriginalExporter?
    private var draining: Task<Void, Never>?
    private var leases: [WeakOfflineLease] = []
    private var refreshingID: UUID?

    public init(directory: URL, fileLimit: Int = maximumFileBytes, storageLimit: Int = maximumStoredBytes,
                countLimit: Int = maximumFiles) throws {
        self.directory = directory
        self.fileLimit = min(max(1, fileLimit), Self.maximumFileBytes)
        self.storageLimit = min(max(1, storageLimit), Self.maximumStoredBytes)
        self.countLimit = min(max(1, countLimit), Self.maximumFiles)
        try Self.protectDirectory(directory)
        let index = directory.appendingPathComponent("index-v1.json")
        if FileManager.default.fileExists(atPath: index.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: index.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumIndexBytes else { throw OfflineFileError.invalidLibrary }
            let value: Manifest
            do { value = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: index)) }
            catch { throw OfflineFileError.invalidLibrary }
            guard value.version == 1, value.pins.count <= self.countLimit,
                  Set(value.pins.map(\.id)).count == value.pins.count,
                  Set(value.pins.map(\.blobID)).count == value.pins.count else { throw OfflineFileError.invalidLibrary }
            var total = 0
            for pin in value.pins {
                guard Self.validFilename(pin.filename), pin.previewFilename.map(Self.validFilename) ?? true, pin.path.hasPrefix("/"),
                      pin.byteCount >= 0, pin.byteCount <= self.fileLimit, pin.byteCount <= self.storageLimit - total,
                      pin.digest.count == 64, pin.digest.allSatisfy({ $0.isHexDigit }),
                      pin.routeKey.count == 64, pin.routeKey.allSatisfy({ $0.isHexDigit }) else { throw OfflineFileError.invalidLibrary }
                total += pin.byteCount
            }
            pins = value.pins
        } else { pins = [] }
        // The manifest is the commit point. Clean only recognized, store-owned abandoned output.
        let retained = Set(pins.map { $0.blobID.uuidString })
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = child.lastPathComponent
            let abandonedIndex = name.hasPrefix(".index-") && name.hasSuffix(".json") &&
                UUID(uuidString: String(name.dropFirst(7).dropLast(5))) != nil
            if (UUID(uuidString: name) != nil && !retained.contains(name)) || name == ".transfers" || name == ".leases" || abandonedIndex {
                try FileManager.default.removeItem(at: child)
            }
        }
    }

    public static func shared(directory: URL) async throws -> OfflineFileStore {
        try await OfflineStores.shared.store(directory)
    }

    public func snapshot() -> [OfflinePin] { pins.sorted { $0.savedAt > $1.savedAt } }

    /// Decode only a bounded prefix, on the store actor rather than the UI actor.
    public func textPreview(_ lease: OfflineFileLease) throws -> DocumentPreview {
        let file = try FileHandle(forReadingFrom: lease.url)
        defer { try? file.close() }
        try Task.checkCancellation()
        let data = try file.read(upToCount: DocumentPolicy.previewByteLimit + 1) ?? Data()
        return DocumentPolicy.decode(data, filename: lease.pin.documentFilename)
    }

    public func pin(profile: ConnectionProfile, entry: RemoteEntry, allowedRoot: String,
                    service: any RemoteFileService, progress: @escaping DownloadProgressHandler = { _ in }) async throws -> OfflinePin {
        try Task.checkCancellation()
        guard operation == nil else { throw OfflineFileError.busy }
        guard entry.path.hasPrefix("/") else { throw RemoteFileError.invalidPath }
        if let size = entry.size, size > UInt64(fileLimit) { throw OfflineFileError.tooLarge(fileLimit) }
        let previous = pins.first { $0.matches(profile, path: entry.path) }
        guard previous != nil || pins.count < countLimit else { throw OfflineFileError.tooManyFiles }
        let used = pins.filter { $0.id != previous?.id }.reduce(0) { $0 + $1.byteCount }
        let available = storageLimit - used
        guard available > 0 else { throw OfflineFileError.storageFull }
        let transferID = UUID()
        let transferRoot = directory.appendingPathComponent(".transfers")
        try Self.protectDirectory(transferRoot)
        let temporary = transferRoot.appendingPathComponent(transferID.uuidString)
        let worker = RemoteOriginalExporter(service: service, directory: temporary, fileLimit: min(fileLimit, available))
        operation = transferID; exporter = worker; cancelled = false; refreshingID = previous?.id
        var unpublished: URL?
        do {
            let prepared = try await withTaskCancellationHandler {
                try await worker.prepare(profile: profile, entry: entry, allowedRoot: allowedRoot, progress: progress)
            } onCancel: { Task { await worker.cancelAll() } }
            try Task.checkCancellation()
            guard operation == transferID, !cancelled else { throw CancellationError() }
            let blobID = UUID(), package = directory.appendingPathComponent(blobID.uuidString)
            try Self.protectDirectory(package)
            unpublished = package
            let file = package.appendingPathComponent("original")
            try FileManager.default.moveItem(at: prepared.url, to: file)
            try Self.protectFile(file)
            let (count, digest) = try Self.fingerprint(file, limit: min(fileLimit, available))
            try Task.checkCancellation()
            guard operation == transferID, !cancelled else { throw CancellationError() }
            let pin = OfflinePin(id: previous?.id ?? UUID(), connectionID: profile.id, connectionName: profile.name,
                routeKey: OfflinePin.routeKey(profile), path: entry.path, filename: prepared.filename,
                previewFilename: Self.validFilename(prepared.sourceFilename) ? prepared.sourceFilename : prepared.filename,
                byteCount: count, savedAt: Date(), blobID: blobID, digest: digest)
            var candidate = pins.filter { $0.id != pin.id }; candidate.append(pin)
            try save(candidate)
            pins = candidate; unpublished = nil
            if let previous { try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous.blobID.uuidString)) }
            await worker.release(prepared.id)
            finish(transferID)
            return pin
        } catch {
            if let unpublished { try? FileManager.default.removeItem(at: unpublished) }
            await worker.cancelAll()
            // Cancellation returns promptly; the slot stays occupied until even an uncooperative
            // transport has stopped. It cannot publish into a later transfer's directory.
            let task = Task { await worker.cancelAndDrain(); self.finish(transferID) }
            if operation == transferID { draining = task }
            if case OriginalFileExportError.tooLarge = error {
                if available < fileLimit { throw OfflineFileError.storageFull }
                throw OfflineFileError.tooLarge(fileLimit)
            }
            if case OriginalFileExportError.timedOut = error { throw OfflineFileError.timedOut }
            throw error
        }
    }

    public func cancelAll() async { cancelled = true; await exporter?.cancelAll() }
    /// Wait without cancelling a different window's transfer. `pin` installs this drain before
    /// returning an error; cancelling its caller already targets that operation's own worker.
    public func waitForCancelledTransfer() async { let pending = draining; await pending?.value }
    public func cancelAndDrain() async {
        let current = exporter, token = operation, previousDrain = draining
        cancelled = true
        await current?.cancelAll()
        await current?.cancelAndDrain()
        await previousDrain?.value
        if let token { finish(token) }
    }

    public func remove(_ id: UUID) throws {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        let candidate = pins.filter { $0.id != id }
        try save(candidate); pins = candidate
        if refreshingID == id {
            cancelled = true
            if let worker = exporter { Task { await worker.cancelAll() } }
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(pin.blobID.uuidString))
    }

    public func lease(_ id: UUID) throws -> OfflineFileLease {
        leases.removeAll { $0.value == nil }
        guard leases.count < 4 else { throw OfflineFileError.tooManyReaders }
        guard let pin = pins.first(where: { $0.id == id }) else { throw OfflineFileError.missing }
        let package = directory.appendingPathComponent(pin.blobID.uuidString)
        guard (try? FileManager.default.attributesOfItem(atPath: package.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw OfflineFileError.missing
        }
        let source = package.appendingPathComponent("original")
        let (count, digest) = try Self.fingerprint(source, limit: fileLimit)
        guard count == pin.byteCount, digest == pin.digest else { throw OfflineFileError.damaged }
        let base = directory.appendingPathComponent(".leases")
        try Self.protectDirectory(base)
        let folder = base.appendingPathComponent(UUID().uuidString)
        try Self.protectDirectory(folder)
        do {
            let file = folder.appendingPathComponent(pin.filename)
            do { try FileManager.default.linkItem(at: source, to: file) }
            catch { try FileManager.default.copyItem(at: source, to: file) }
            try Self.protectFile(file)
            let lease = OfflineFileLease(url: file, directory: folder, pin: pin)
            leases.append(WeakOfflineLease(lease))
            return lease
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    private func finish(_ id: UUID) {
        guard operation == id else { return }
        operation = nil; exporter = nil; cancelled = false; draining = nil; refreshingID = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(".transfers").appendingPathComponent(id.uuidString))
    }
    private func save(_ pins: [OfflinePin]) throws {
        let data = try JSONEncoder().encode(Manifest(pins: pins))
        guard data.count <= Self.maximumIndexBytes else { throw OfflineFileError.metadataTooLarge }
        let index = directory.appendingPathComponent("index-v1.json")
        let temporary = directory.appendingPathComponent(".index-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        #if os(iOS)
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: temporary, options: .atomic)
        #endif
        try Self.protectFile(temporary)
        guard Darwin.rename(temporary.path, index.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    private static func validFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") &&
        !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    private static func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw OfflineFileError.invalidLibrary
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var directory = url; try directory.setResourceValues(values)
    }
    private static func protectFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
    private static func fingerprint(_ url: URL, limit: Int) throws -> (Int, String) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw OfflineFileError.damaged }
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(limit) else { throw OfflineFileError.damaged }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256(), count = 0
        while let data = try file.read(upToCount: 64 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            guard data.count <= limit - count else { throw OfflineFileError.damaged }
            count += data.count; hash.update(data: data)
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

private actor OfflineStores {
    static let shared = OfflineStores()
    var stores: [URL: OfflineFileStore] = [:]
    func store(_ directory: URL) throws -> OfflineFileStore {
        let key = directory.standardizedFileURL
        if let store = stores[key] { return store }
        let store = try OfflineFileStore(directory: key)
        stores[key] = store
        return store
    }
}
