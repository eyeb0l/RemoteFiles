#if os(iOS)
import SwiftUI
import RemoteFilesCore

@MainActor @Observable
final class AppModel {
    enum Route: Hashable { case folder(UUID, String), file(UUID, RemoteEntry) }
    enum Sheet: Identifiable {
        case connection(UUID?), keys, trust(HostEndpoint, HostKeyDetails), changed(HostEndpoint, HostKeyDetails, HostKeyDetails), unlock(IdentityMetadata)
        var id: String {
            switch self {
            case .connection: return "connection"
            case .keys: return "keys"
            case .trust: return "trust"
            case .changed: return "changed"
            case .unlock: return "unlock"
            }
        }
    }
    let metadataStore: MetadataStore
    let identities = IdentityStore()
    let trust: HostTrustStore
    private(set) var service: any RemoteFileService
    let resourceDirectory: URL
    private var resourceService: RemoteResourceResolver?
    private var exportService: RemoteOriginalExporter?
    var originalExporter: RemoteOriginalExporter {
        if let exportService { return exportService }
        let value = RemoteOriginalExporter(service: service, directory: FileManager.default.temporaryDirectory.appendingPathComponent("RemoteOriginalExports-v1", isDirectory: true))
        exportService = value
        return value
    }
    var resources: RemoteResourceResolver {
        if let resourceService { return resourceService }
        let value = RemoteResourceResolver(service: service, directory: resourceDirectory)
        resourceService = value
        return value
    }
    var metadata = AppMetadata()
    var routes: [Route] = []
    var sheet: Sheet?
    var errorMessage: String?
    var sessionRevision = 0
    var connectionStates: [UUID: String] = [:]
    var demo = false
    var isForeground = true
    private var realMetadata = AppMetadata()
    private var directories: [String: FolderListing] = [:]
    private var documents: [String: Data] = [:]
    private var directoryOrder: [String] = []
    private var documentOrder: [String] = []

    init(directory: URL, fileService: (any RemoteFileService)? = nil) throws {
        resourceDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteImages-v1")
        metadataStore = try MetadataStore(fileURL: directory.appendingPathComponent("library-v1.json"))
        trust = try HostTrustStore(fileURL: directory.appendingPathComponent("known-hosts-v1.json"))
        service = fileService ?? CoalescingFileService(base: SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadataStore))
    }
    func load() async { metadata = await metadataStore.snapshot() }
    func profile(_ id: UUID) -> ConnectionProfile? { metadata.connections.first { $0.id == id } }
    func persist() async {
        guard !demo else { return }
        do { try await metadataStore.save(metadata) } catch { errorMessage = error.localizedDescription }
    }
    func saveConnection(_ value: ConnectionProfile) async {
        await disconnect()
        metadata.connections.removeAll { $0.id == value.id }
        metadata.connections.append(value)
        await persist()
    }
    func removeConnection(_ profile: ConnectionProfile) async {
        await disconnect()
        metadata.connections.removeAll { $0.id == profile.id }
        metadata.favourites.removeAll { $0.connectionID == profile.id }
        metadata.recents.removeAll { $0.connectionID == profile.id }
        await persist()
    }
    func addIdentity(_ value: IdentityMetadata) async throws {
        guard !demo else { throw RemoteFileError.unavailable("Leave Demo before saving keys.") }
        var candidate = metadata
        candidate.identities.append(value)
        try await metadataStore.save(candidate)
        metadata = candidate
    }
    func deleteIdentity(_ value: IdentityMetadata) async {
        do {
            try await identities.delete(value, referencedBy: Set(metadata.connections.map(\.identityID)))
            metadata.identities.removeAll { $0.id == value.id }
            await persist()
        } catch { errorMessage = error.localizedDescription }
    }
    func favourite(profile: ConnectionProfile, path: String) async {
        if let index = metadata.favourites.firstIndex(where: { $0.connectionID == profile.id && $0.path == path }) {
            metadata.favourites.remove(at: index)
        } else {
            metadata.favourites.append(.init(connectionID: profile.id, path: path, name: RemotePath.name(of: path)))
        }
        await persist()
    }
    func isFavourite(_ id: UUID, path: String) -> Bool { metadata.favourites.contains { $0.connectionID == id && $0.path == path } }
    func recordRecent(profile: ConnectionProfile, entry: RemoteEntry) async {
        metadata.recents.removeAll { $0.connectionID == profile.id && $0.path == entry.path }
        metadata.recents.insert(.init(connectionID: profile.id, path: entry.path, name: entry.name), at: 0)
        metadata.recents = Array(metadata.recents.prefix(8)); await persist()
    }
    func handle(_ error: Error, profile: ConnectionProfile) {
        connectionStates[profile.id] = "Disconnected"
        if let trustError = error as? HostTrustError {
            switch trustError {
            case .unknown(let endpoint, let key): sheet = .trust(endpoint, key)
            case .changed(let endpoint, let previous, let current): sheet = .changed(endpoint, previous, current)
            default: errorMessage = error.localizedDescription
            }
        } else if (error as? IdentityError) == .missingPassphrase,
                  let key = metadata.identities.first(where: { $0.id == profile.identityID }) {
            sheet = .unlock(key)
        }
    }
    func isSecurityError(_ error: Error) -> Bool {
        if error is HostTrustError || error is IdentityError { return true }
        if let boundary = error as? RemoteDocumentLinkError, boundary == .outsideConnection { return true }
        if case RemoteResourceError.outsideDocument = error { return true }
        return false
    }
    func disconnect() async {
        let previousExporter = exportService
        await previousExporter?.cancelAll()
        await resourceService?.cancelAll(); resourceService = nil
        await RemoteImageDecoder.shared.clear()
        await SourceHighlighting.shared.clear()
        await service.disconnect()
        await previousExporter?.cancelAndDrain()
        exportService = nil
        await identities.clearSession()
        connectionStates = [:]; clearCaches()
    }
    func background() async {
        sheet = nil
        await disconnect()
    }
    func clearCaches() { directories.removeAll(); documents.removeAll(); directoryOrder.removeAll(); documentOrder.removeAll() }
    private func key(_ id: UUID, _ path: String) -> String { "\(id.uuidString):\(path)" }
    func cachedListing(_ id: UUID, path: String) -> FolderListing? { directories[key(id, path)] }
    func cache(_ value: FolderListing, id: UUID, requestedPath: String) {
        let k = key(id, requestedPath)
        directories[k] = value; directoryOrder.removeAll { $0 == k }; directoryOrder.append(k)
        while directoryOrder.count > 10 { directories.removeValue(forKey: directoryOrder.removeFirst()) }
    }
    func cachedDocument(_ id: UUID, path: String) -> Data? { documents[key(id, path)] }
    func cache(_ value: Data, id: UUID, path: String) {
        let k = key(id, path)
        documents[k] = value; documentOrder.removeAll { $0 == k }; documentOrder.append(k)
        while documentOrder.count > 4 || documents.values.reduce(0, { $0 + $1.count }) > 6 * 1024 * 1024 {
            documents.removeValue(forKey: documentOrder.removeFirst())
        }
    }
    func setDemo(_ enabled: Bool) async {
        await disconnect(); routes = []
        if enabled {
            realMetadata = metadata
            metadata = AppMetadata()
            let profile = ConnectionProfile(name: "Studio Server · Demo", host: "demo.invalid", username: "demo", identityID: UUID(), startingDirectory: "/Projects")
            metadata.connections = [profile]
            metadata.favourites = [.init(connectionID: profile.id, path: "/Projects", name: "Projects"), .init(connectionID: profile.id, path: "/Projects/Reports", name: "Reports")]
            service = CoalescingFileService(base: DemoRemoteFileService())
        } else {
            metadata = realMetadata
            service = CoalescingFileService(base: SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadataStore))
        }
        demo = enabled
    }
}

#endif
