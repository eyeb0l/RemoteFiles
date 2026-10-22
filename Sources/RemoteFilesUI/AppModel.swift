#if os(iOS)
import SwiftUI
import RemoteFilesCore

/// Cancels a subscription when its window goes away, without requiring actor-isolated work
/// in AppModel's nonisolated deinitializer.
private final class OfflineLibraryObservation {
    let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    deinit { task.cancel() }
}

@MainActor @Observable
final class AppModel {
    enum Route: Hashable {
        case folder(UUID, String), file(UUID, RemoteEntry)
        var connectionID: UUID {
            switch self { case .folder(let id, _), .file(let id, _): return id }
        }
    }
    enum Sheet: Identifiable {
        case offlineFolder(ConnectionProfile, String, Bool)
        case connection(UUID?), keys, offlineFiles, trust(HostEndpoint, HostKeyDetails), changed(HostEndpoint, HostKeyDetails, HostKeyDetails), unlock(IdentityMetadata)
        var id: String {
            switch self {
            case .connection: return "connection"
            case .keys: return "keys"
            case .offlineFiles: return "offlineFiles"
            case .offlineFolder: return "offlineFolder"
            case .trust: return "trust"
            case .changed: return "changed"
            case .unlock: return "unlock"
            }
        }
    }
    let metadataStore: MetadataStore
    let readingPositions: ReadingPositionStore
    let identities: IdentityStore
    let trust: HostTrustStore
    let publicKeyInstaller: any PublicKeyInstalling
    private(set) var service: any RemoteFileService
    /// Subfolder search lists folders without sharing in-flight requests: cancelling a search must
    /// not cancel a folder the user opens while the search happens to be listing it.
    var searchService: any RemoteFileService { (service as? CoalescingFileService)?.base ?? service }
    /// The real (or injected) transport, restored when leaving Demo.
    private let connectionService: any RemoteFileService
    let resourceDirectory: URL
    let offlineDirectory: URL
    private(set) var offlineStore: OfflineFileStore?
    private(set) var offlinePins: [OfflinePin] = []
    private(set) var offlineFolders: [OfflineFolderPin] = []
    var standaloneOfflinePins: [OfflinePin] {
        let members = Set(offlineFolders.flatMap(\.fileIDs))
        return offlinePins.filter { !members.contains($0.id) }
    }
    private(set) var offlineError: String?
    private(set) var pinningName: String?
    private(set) var pinProgress = DownloadProgress()
    private(set) var folderPinProgress: OfflineFolderProgress?
    private(set) var cancellingPin = false
    private var pinTask: Task<Void, Never>?
    private var pinToken: UUID?
    private var offlineObservation: OfflineLibraryObservation?
    private var offlineLibraryToken = UUID()
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
    private(set) var isDisconnecting = false
    private var disconnectWork: Task<Void, Never>?
    private var realMetadata = AppMetadata()
    private var directories: [String: FolderListing] = [:]
    private var documents: [String: (bytes: Data, version: RemoteFileVersion?)] = [:]
    private var directoryOrder: [String] = []
    private var documentOrder: [String] = []

    let preferences: UserDefaults
    init(directory: URL, fileService: (any RemoteFileService)? = nil, publicKeyInstaller: (any PublicKeyInstalling)? = nil,
         preferences: UserDefaults = .standard, identities: IdentityStore = IdentityStore()) throws {
        self.preferences = preferences
        self.identities = identities
        offlineDirectory = directory.appendingPathComponent("Offline-v1", isDirectory: true)
        resourceDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteImages-v1")
        metadataStore = try MetadataStore(fileURL: directory.appendingPathComponent("library-v1.json"))
        readingPositions = ReadingPositionStore(fileURL: directory.appendingPathComponent("reading-positions-v1.json"))
        trust = try HostTrustStore(fileURL: directory.appendingPathComponent("known-hosts-v1.json"))
        self.publicKeyInstaller = publicKeyInstaller ?? SSHPublicKeyInstaller(trust: trust)
        connectionService = fileService ?? CoalescingFileService(base: SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadataStore))
        service = connectionService
    }
    func load() async {
        metadata = await metadataStore.snapshot()
        await loadOfflineLibrary()
    }
    private func loadOfflineLibrary() async {
        offlineObservation = nil
        let token = UUID(); offlineLibraryToken = token
        offlineStore = nil; offlinePins = []; offlineFolders = []; offlineError = nil
        do {
            let directory = demo ? offlineDirectory.appendingPathComponent("Demo", isDirectory: true) : offlineDirectory
            let store = try await OfflineFileStore.shared(directory: directory)
            let library = await store.librarySnapshot()
            guard offlineLibraryToken == token else { return }
            offlineStore = store; offlinePins = library.files; offlineFolders = library.folders
            offlineObservation = OfflineLibraryObservation(Task { [weak self] in
                for await _ in await store.changes() {
                    let library = await store.librarySnapshot()
                    guard !Task.isCancelled, self?.offlineLibraryToken == token else { return }
                    self?.offlinePins = library.files; self?.offlineFolders = library.folders
                }
            })
        } catch { if offlineLibraryToken == token { offlineError = error.localizedDescription } }
    }
    func offlinePin(profile: ConnectionProfile, path: String) -> OfflinePin? {
        standaloneOfflinePins.first { $0.matches(profile, path: path) }
    }
    func offlineFolder(profile: ConnectionProfile, path: String) -> OfflineFolderPin? {
        offlineFolders.first { $0.matches(profile, path: path) }
    }
    func pinOffline(profile: ConnectionProfile, entry: RemoteEntry, includeHidden: Bool = false) {
        guard pinTask == nil, isForeground, !isDisconnecting, disconnectWork == nil,
              let store = offlineStore else { return }
        let token = UUID(), revision = sessionRevision
        let transport = entry.kind == .directory ? searchService : service
        pinToken = token; pinningName = entry.exportFilename ?? entry.name
        pinProgress = .init(); cancellingPin = false
        folderPinProgress = entry.kind == .directory ? .init() : nil
        pinTask = Task {
            do {
                if entry.kind == .directory {
                    _ = try await store.pinFolder(profile: profile, path: entry.path, includeHidden: includeHidden,
                        service: transport, operationID: token) { [weak self] progress in
                            await self?.updateFolderPinProgress(progress, token: token)
                        }
                } else {
                    _ = try await store.pin(profile: profile, entry: entry, allowedRoot: profile.startingDirectory,
                                            service: transport, operationID: token) { [weak self] progress in
                        await self?.updatePinProgress(progress, token: token)
                    }
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, revision == sessionRevision, isForeground {
                    if isSecurityError(error) { handle(error, profile: profile) }
                    else if let remote = error as? RemoteFileError {
                        switch remote {
                        case .connectionEnded, .timedOut, .unavailable: handle(error, profile: profile)
                        default: break
                        }
                    }
                    if sheet == nil || sheet?.id == "offlineFiles" { errorMessage = error.localizedDescription }
                }
            }
            // A cancelled future-backed transfer can still be draining. Keep the UI slot until
            // its private output is gone; disconnect closes the channel before waiting here.
            await store.waitForCancelledTransfer(token)
            guard pinToken == token else { return }
            await refreshOfflineSnapshot(store)
            pinTask = nil; pinToken = nil; pinningName = nil; cancellingPin = false
            folderPinProgress = nil
        }
    }
    private func refreshOfflineSnapshot(_ store: OfflineFileStore) async {
        let library = await store.librarySnapshot()
        guard offlineStore === store else { return }
        offlinePins = library.files; offlineFolders = library.folders
    }
    private func updateFolderPinProgress(_ progress: OfflineFolderProgress, token: UUID) {
        guard pinToken == token, !cancellingPin else { return }
        folderPinProgress = progress
        pinProgress = .init(receivedBytes: progress.bytes)
    }
    private func updatePinProgress(_ progress: DownloadProgress, token: UUID) {
        guard pinToken == token, !cancellingPin else { return }
        pinProgress = progress
    }
    func cancelOfflinePin() {
        guard pinTask != nil else { return }
        cancellingPin = true; pinTask?.cancel()
    }
    func removeOfflinePin(_ pin: OfflinePin) async {
        guard let store = offlineStore else { return }
        do { try await store.remove(pin.id); await refreshOfflineSnapshot(store) }
        catch { errorMessage = error.localizedDescription }
    }
    func refreshOfflinePin(_ pin: OfflinePin) {
        guard let profile = profile(pin.connectionID), pin.matches(profile, path: pin.path) else {
            errorMessage = "This connection has changed or was removed. The saved copy is still available. Save a new copy from the current connection to update it."
            return
        }
        pinOffline(profile: profile, entry: .init(name: RemotePath.name(of: pin.path), path: pin.path,
                                                kind: .file, exportFilename: pin.filename))
    }
    func removeOfflineFolder(_ folder: OfflineFolderPin) async {
        guard let store = offlineStore else { return }
        do { try await store.removeFolder(folder.id); await refreshOfflineSnapshot(store) }
        catch { errorMessage = error.localizedDescription }
    }
    func refreshOfflineFolder(_ folder: OfflineFolderPin) {
        guard let profile = profile(folder.connectionID), folder.matches(profile, path: folder.path) else {
            errorMessage = "This connection has changed or was removed. The saved folder is still available. Save a new copy from the current connection to update it."
            return
        }
        pinOffline(profile: profile, entry: .init(name: folder.name, path: folder.path, kind: .directory), includeHidden: folder.includeHidden)
    }
    func prepareReadingPosition(_ position: DocumentReadingPosition, text: String, profile: ConnectionProfile, path: String) async {
        await position.prepare(text: text, store: demo ? nil : readingPositions, connectionID: profile.id, path: path)
    }
    func profile(_ id: UUID) -> ConnectionProfile? { metadata.connections.first { $0.id == id } }
    /// Installation is direct: a bastion-only identity must not prefill the destination account.
    func installationConnection(for identity: IdentityMetadata) -> ConnectionProfile? {
        metadata.connections.first { $0.identityID == identity.id }
    }
    func persist() async {
        guard !demo else { return }
        do { try await metadataStore.save(metadata) } catch { errorMessage = error.localizedDescription }
    }
    func saveConnection(_ value: ConnectionProfile) async {
        await disconnect()
        // The iPad sidebar can edit the connection whose reader is still on screen.
        routes.removeAll { $0.connectionID == value.id }
        sessionRevision += 1
        metadata.connections.removeAll { $0.id == value.id }
        metadata.connections.append(value)
        await persist()
    }
    func removeConnection(_ profile: ConnectionProfile) async {
        await disconnect()
        routes.removeAll { $0.connectionID == profile.id }
        sessionRevision += 1
        metadata.connections.removeAll { $0.id == profile.id }
        metadata.favourites.removeAll { $0.connectionID == profile.id }
        metadata.recents.removeAll { $0.connectionID == profile.id }
        if !demo {
            do { try await readingPositions.remove(connectionID: profile.id) }
            catch { errorMessage = error.localizedDescription }
            storeFolderSortOrders(folderSortOrders().filter { !$0[0].hasPrefix(profile.id.uuidString + "|") })
        }
        await persist()
    }
    private static let folderSortKey = "folderSortOrders-v1"
    /// Most folders whose sort choice is remembered; the least recently changed is dropped first.
    static let folderSortLimit = 200
    /// A folder's remembered sort, or Name. Demo never reads or writes these choices.
    func folderSortOrder(_ id: UUID, path: String) -> FolderSortOrder {
        guard !demo else { return .name }
        let key = id.uuidString + "|" + path
        return folderSortOrders().last { $0[0] == key }.flatMap { FolderSortOrder(rawValue: $0[1]) } ?? .name
    }
    /// Remembers a user's sort choice for a canonical folder path. Name is the default, so it is
    /// stored as no entry at all.
    func setFolderSortOrder(_ order: FolderSortOrder, id: UUID, path: String) {
        guard !demo else { return }
        let key = id.uuidString + "|" + path
        var entries = folderSortOrders().filter { $0[0] != key }
        if order != .name { entries.append([key, order.rawValue]) }
        storeFolderSortOrders(Array(entries.suffix(Self.folderSortLimit)))
    }
    /// Stored as [key, order] pairs, oldest first.
    private func folderSortOrders() -> [[String]] {
        (preferences.array(forKey: Self.folderSortKey) as? [[String]])?.filter { $0.count == 2 } ?? []
    }
    private func storeFolderSortOrders(_ entries: [[String]]) {
        if entries.isEmpty { preferences.removeObject(forKey: Self.folderSortKey) } else { preferences.set(entries, forKey: Self.folderSortKey) }
    }
    /// Forgets the trusted key of the saved endpoint, never unsaved edits in the connection form.
    func resetTrust(for profile: ConnectionProfile) async {
        await disconnect()
        do { try await trust.reset(endpoint: HostEndpoint(host: profile.host, port: profile.port)) }
        catch { errorMessage = error.localizedDescription }
    }
    func resetJumpHostTrust(for profile: ConnectionProfile) async {
        guard let jump = profile.jumpHost else { return }
        await disconnect()
        do { try await trust.reset(endpoint: HostEndpoint(host: jump.host, port: jump.port)) }
        catch { errorMessage = error.localizedDescription }
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
            try await identities.delete(value, referencedBy: Set(metadata.connections.flatMap { $0.identityIDs }))
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
    func removeRecent(_ location: SavedLocation) async {
        do {
            if !demo { try await metadataStore.removeRecent(id: location.id) }
            metadata.recents.removeAll { $0.id == location.id }
        } catch { errorMessage = "Couldn’t remove this recent entry. \(error.localizedDescription)" }
    }
    func handle(_ error: Error, profile: ConnectionProfile) {
        guard !isDisconnecting else { return }
        connectionStates[profile.id] = "Disconnected"
        if let trustError = error as? HostTrustError {
            switch trustError {
            case .unknown(let endpoint, let key): sheet = .trust(endpoint, key)
            case .changed(let endpoint, let previous, let current): sheet = .changed(endpoint, previous, current)
            default: errorMessage = error.localizedDescription
            }
        } else if let locked = error as? ConnectionIdentityUnlockRequired {
            sheet = .unlock(locked.identity)
        } else if (error as? IdentityError) == .missingPassphrase,
                  let key = metadata.identities.first(where: { $0.id == profile.identityID }) {
            sheet = .unlock(key)
        }
    }
    /// Unlocks with the passphrase, keeps a copy for `biometryName` when given, then reconnects.
    /// Throws `CancellationError` without reconnecting when the sheet is dismissed meanwhile.
    func unlockAndConnect(_ identity: IdentityMetadata, passphrase: String, rememberWith biometryName: String?) async throws {
        _ = try await identities.unlock(identity, passphrase: passphrase)
        try Task.checkCancellation()
        if let biometryName {
            // The key is already unlocked; failing to store the copy must not block connecting.
            do { try await identities.enableBiometricUnlock(identity) }
            catch {
                try Task.checkCancellation()
                errorMessage = "The key is unlocked, but \(biometryName) unlock couldn't be turned on. \(error.localizedDescription)"
            }
            // Cancelling does not interrupt the actor call, so check again before reconnecting.
            try Task.checkCancellation()
        }
        sheet = nil; sessionRevision += 1
    }
    func isSecurityError(_ error: Error) -> Bool {
        if error is HostTrustError || error is IdentityError || error is ConnectionIdentityUnlockRequired { return true }
        if let boundary = error as? RemoteDocumentLinkError, boundary == .outsideConnection { return true }
        if case RemoteResourceError.outsideDocument = error { return true }
        return false
    }
    func disconnect() async {
        if let disconnectWork { await disconnectWork.value; return }
        let task = Task { await closeSession() }
        disconnectWork = task
        await task.value
        disconnectWork = nil
    }
    /// Explicit Disconnect differs from background suspension: discard the whole route stack.
    func disconnectAndGoHome() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        sessionRevision += 1
        routes = []; sheet = nil; errorMessage = nil
        connectionStates = [:]; clearCaches()
        await disconnect()
        isDisconnecting = false
    }
    private func closeSession() async {
        let previousPin = pinTask
        cancelOfflinePin()
        let previousExporter = exportService
        await previousExporter?.cancelAll()
        await resourceService?.cancelAll(); resourceService = nil
        await publicKeyInstaller.cancelAll()
        await service.disconnect()
        await previousPin?.value
        await RemoteImageDecoder.shared.clear()
        await SourceHighlighting.shared.clear()
        await previousExporter?.cancelAndDrain()
        exportService = nil
        await identities.clearSession()
        connectionStates = [:]; clearCaches()
    }
    func background() async {
        // Offline navigation owns no connection or credentials. Keep its stack while the reader
        // releases protected local resources; transient trust/key/edit sheets still disappear.
        if case .offlineFiles = sheet { } else { sheet = nil }
        await disconnect()
    }
    /// Breadcrumb navigation: pop back to a folder already in the stack instead of pushing a
    /// duplicate. A route may hold a non-canonical request such as ".", so its cached listing's
    /// canonical path also counts as a match.
    func showFolder(_ id: UUID, path: String) {
        let existing = routes.lastIndex { route in
            guard case .folder(let routeID, let requested) = route, routeID == id else { return false }
            return requested == path || cachedListing(id, path: requested)?.path == path
        }
        if let existing { routes.removeSubrange((existing + 1)...) }
        else {
            // A split-view breadcrumb can be tapped while the reader is visible.
            // Retire that preview before adding a folder, just like a folder-row selection.
            openInWorkspace(.folder(id, path))
        }
    }
    /// The folder column stays mounted when a file opens, retaining search and scroll state.
    var workspaceFolder: Route? {
        guard let last = routes.last else { return nil }
        let id = last.connectionID
        if let folder = routes.last(where: { if case .folder(let value, _) = $0 { return value == id }; return false }) { return folder }
        // A recent file has no folder route yet. Show its containing directory alongside it.
        if case .file(_, let entry) = last { return .folder(id, RemotePath.parent(of: entry.path)) }
        return nil
    }
    var workspaceFile: Route? {
        if case .file = routes.last { return routes.last }
        return nil
    }
    func openInWorkspace(_ route: Route) {
        let currentFolder = workspaceFolder
        // A compact reader may have several linked-file routes when the window widens.
        removeTrailingPreviews()
        // A recent file projects its parent without a folder route. Seed it before drilling down.
        if let currentFolder, currentFolder.connectionID == route.connectionID, !routes.contains(currentFolder) {
            routes.append(currentFolder)
        }
        if routes.last != route { routes.append(route) }
    }
    private func removeTrailingPreviews() {
        while case .file = routes.last { routes.removeLast() }
    }
    var canGoBackInWorkspace: Bool {
        routes.filter { if case .folder = $0 { return true }; return false }.count > 1
    }
    func goBackInWorkspace() {
        removeTrailingPreviews()
        guard canGoBackInWorkspace else { return }
        routes.removeLast()
        removeTrailingPreviews()
    }
    func clearCaches() { directories.removeAll(); documents.removeAll(); directoryOrder.removeAll(); documentOrder.removeAll() }
    private func key(_ id: UUID, _ path: String) -> String { "\(id.uuidString):\(path)" }
    func cachedListing(_ id: UUID, path: String) -> FolderListing? { directories[key(id, path)] }
    func cache(_ value: FolderListing, id: UUID, requestedPath: String) {
        let k = key(id, requestedPath)
        directories[k] = value; directoryOrder.removeAll { $0 == k }; directoryOrder.append(k)
        while directoryOrder.count > 10 { directories.removeValue(forKey: directoryOrder.removeFirst()) }
    }
    func cachedDocument(_ id: UUID, path: String) -> Data? { documents[key(id, path)]?.bytes }
    /// The remote version the cached bytes were read at, when the transport reports one.
    func cachedDocumentVersion(_ id: UUID, path: String) -> RemoteFileVersion? { documents[key(id, path)]?.version }
    func cache(_ value: Data, version: RemoteFileVersion? = nil, id: UUID, path: String) {
        let k = key(id, path)
        documents[k] = (value, version); documentOrder.removeAll { $0 == k }; documentOrder.append(k)
        while documentOrder.count > 4 || documents.values.reduce(0, { $0 + $1.bytes.count }) > 6 * 1024 * 1024 {
            documents.removeValue(forKey: documentOrder.removeFirst())
        }
    }
    func setDemo(_ enabled: Bool) async {
        await disconnect(); routes = []
        if enabled {
            realMetadata = metadata
            metadata = AppMetadata()
            let profile = ConnectionProfile(id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!, name: "Studio Server · Demo", host: "demo.invalid", username: "demo", identityID: UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!, startingDirectory: "/Projects")
            metadata.connections = [profile]
            metadata.favourites = [.init(connectionID: profile.id, path: "/Projects", name: "Projects"), .init(connectionID: profile.id, path: "/Projects/Reports", name: "Reports")]
            service = CoalescingFileService(base: DemoRemoteFileService())
        } else {
            metadata = realMetadata
            service = connectionService
        }
        demo = enabled
        await loadOfflineLibrary()
    }
}

#endif
