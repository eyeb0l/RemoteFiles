#if os(iOS)
import SwiftUI
import UIKit
import RemoteFilesCore

/// Cancels a subscription when its window goes away, without requiring actor-isolated work
/// in AppModel's nonisolated deinitializer.
private final class OfflineLibraryObservation {
    let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    deinit { task.cancel() }
}

/// The registration tracks one window without retaining its model or credentials.
private final class DownloadSceneRegistration {
    let id = UUID()
    let manager: DownloadManager
    private let protectedDataObserver: NSObjectProtocol
    init(manager: DownloadManager) {
        self.manager = manager
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak manager] _ in
            Task { @MainActor in manager?.finalizePendingDownloads() }
        }
    }
    deinit {
        NotificationCenter.default.removeObserver(protectedDataObserver)
        let manager = manager, id = id
        Task { @MainActor in
            manager.removeScene(id)
            if !manager.isForeground, !BackgroundDownloadCoordinator.shared(for: manager).canContinue {
                await manager.interrupt(reason: "The download window closed. Retry to continue.")
            }
        }
    }
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
        case connection(UUID?), settings, offlineFiles, downloads, trust(HostEndpoint, HostKeyDetails), changed(HostEndpoint, HostKeyDetails, HostKeyDetails), unlock(IdentityMetadata)
        var id: String {
            switch self {
            case .connection: return "connection"
            case .settings: return "settings"
            case .offlineFiles: return "offlineFiles"
            case .downloads: return "downloads"
            case .trust: return "trust"
            case .changed: return "changed"
            case .unlock: return "unlock"
            }
        }
    }
    let metadataStore: MetadataStore
    let readingPositions: ReadingPositionStore
    let searchIndexDirectory: URL
    func searchIndexStore() async -> SearchIndexStore {
        await SearchIndexStore.shared(directory: demo ? searchIndexDirectory.appendingPathComponent("Demo") : searchIndexDirectory)
    }
    /// Saved indexes set to update automatically, updated while this window is connected.
    let indexUpdates = AutomaticSearchIndexUpdater()
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
    let downloadDirectory: URL
    private(set) var downloads: DownloadManager?
    private(set) var downloadError: String?
    private(set) var backgroundDownloads = BackgroundDownloadCoordinator()
    private let downloadTransport: any RemoteFileService
    private let demoDownloadTransport = DemoRemoteFileService()
    private var downloadSceneRegistration: DownloadSceneRegistration?
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
    @ObservationIgnored private var libraryObservation: OfflineLibraryObservation?
    /// Names this window's own saves among those the shared library reports.
    @ObservationIgnored private let libraryOrigin = UUID()
    /// The newest save of the library this window has taken in. See `takeIn`.
    @ObservationIgnored private var libraryRevision = 0
    /// Counts the times this window's copy of the library was replaced by a saved one.
    @ObservationIgnored private var libraryReplacements = 0
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
    private var mediaSecurityFailures: [UUID: String] = [:]
    @ObservationIgnored private var connectionFailureRevisions: [UUID: Int] = [:]
    func mediaSecurityFailure(_ id: UUID) -> String? { mediaSecurityFailures[id] }

    /// Owns media connection status before decoding/playback. Local preparation can
    /// neither verify a connection nor overwrite a later failed check.
    func loadMediaResource(for reference: String, in location: RemoteDocumentLocation,
                           progress: @escaping DownloadProgressHandler = { _ in }) async throws -> RemoteResourcePreview {
        try Task.checkCancellation()
        guard isForeground, !isDisconnecting else { throw CancellationError() }
        let profile = location.profile
        let revision = sessionRevision, failureRevision = connectionFailureRevisions[profile.id, default: 0]
        func isCurrent() -> Bool {
            isForeground && !isDisconnecting && sessionRevision == revision
                && connectionFailureRevisions[profile.id, default: 0] == failureRevision
        }
        do {
            let result = try await resources.localFileForPreview(for: reference, in: location,
                allowCachedFallback: mediaSecurityFailures[profile.id] == nil, progress: progress)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if let error = result.connectionFailure { handle(error, profile: profile) }
            else {
                mediaSecurityFailures[profile.id] = nil
                connectionStates[profile.id] = "Connected"
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            handle(error, profile: profile)
            throw error
        }
    }
    var demo = false
    var isForeground = true
    private(set) var isDisconnecting = false
    private var disconnectWork: Task<Void, Never>?
    private var disconnectKeepsKeys = false
    private var realMetadata = AppMetadata()
    // Read while a view is being made, and written from the background. Observing them would remake
    // every mounted folder each time one more listing is remembered.
    @ObservationIgnored private var directories: [CacheKey: (listing: FolderListing, storedAt: ContinuousClock.Instant?, nameBytes: Int)] = [:]
    @ObservationIgnored private var folderPrefetchQueue: [(profile: ConnectionProfile, path: String)] = []
    @ObservationIgnored private var folderPrefetch: Task<Void, Never>?
    @ObservationIgnored private var folderPrefetchToken: UUID?
    @ObservationIgnored private var foregroundConnectionID: UUID?
    /// Counts how often a connection's listings were forgotten, so one read before that isn't kept.
    @ObservationIgnored private var forgottenListings: [UUID: Int] = [:]
    func listingGeneration(_ id: UUID) -> Int { forgottenListings[id, default: 0] }
    @ObservationIgnored private var documents: [CacheKey: (bytes: Data, version: RemoteFileVersion?)] = [:]
    @ObservationIgnored private var directoryOrder: [CacheKey] = []
    @ObservationIgnored private var documentOrder: [CacheKey] = []

    let preferences: UserDefaults
    /// Remote folder paths, so kept beside the library with its protection, not in the preferences file.
    private let folderSortFile: URL
    init(directory: URL, fileService: (any RemoteFileService)? = nil, publicKeyInstaller: (any PublicKeyInstalling)? = nil,
         preferences: UserDefaults = .standard, identities: IdentityStore = IdentityStore()) throws {
        searchIndexDirectory = directory.appendingPathComponent("SearchIndexes-v1", isDirectory: true)
        folderSortFile = directory.appendingPathComponent("folder-sort-orders-v1.json")
        self.preferences = preferences
        self.identities = identities
        downloadDirectory = directory.appendingPathComponent("Downloads-v1", isDirectory: true)
        offlineDirectory = directory.appendingPathComponent("Offline-v1", isDirectory: true)
        resourceDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteImages-v1")
        // Shared with every other window on this library: each has its own model, and with a store
        // apiece each would write back its own copy of these files over what another had saved.
        metadataStore = try MetadataStore.shared(fileURL: directory.appendingPathComponent("library-v1.json"))
        readingPositions = ReadingPositionStore.shared(fileURL: directory.appendingPathComponent("reading-positions-v1.json"))
        trust = try HostTrustStore.shared(fileURL: directory.appendingPathComponent("known-hosts-v1.json"))
        self.publicKeyInstaller = publicKeyInstaller ?? SSHPublicKeyInstaller(trust: trust)
        connectionService = fileService ?? CoalescingFileService(base: SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadataStore))
        service = connectionService
        downloadTransport = fileService ?? SFTPRemoteFileService(identityStore: identities, trustStore: trust, metadataStore: metadataStore)
    }
    func load() async {
        let saved = await metadataStore.current()
        metadata = saved.metadata; libraryRevision = saved.revision
        observeLibrary()
        await loadOfflineLibrary()
        loadDownloads()
    }
    /// Follows the saved library, so a connection, key, favourite or recent changed in another window
    /// shows in this one.
    private func observeLibrary() {
        let store = metadataStore
        libraryObservation = OfflineLibraryObservation(Task { [weak self] in
            for await saved in await store.changes() {
                guard !Task.isCancelled, let self else { return }
                self.takeIn(saved)
            }
        })
    }
    /// Takes in a save of the library, reported by the store or returned from this window's own change.
    /// Saves are numbered. One this window already has is ignored, however late it is reported, so it
    /// can't replace what was saved since. This window's own, when nothing else was saved before it, is
    /// already in its copy. Anything else replaces the copy: it holds what another window changed.
    private func takeIn(_ saved: MetadataStore.Saved) {
        guard saved.revision > libraryRevision else { return }
        let nothingBetween = saved.revision == libraryRevision + 1
        libraryRevision = saved.revision
        if saved.origin == libraryOrigin, nothingBetween { return }
        libraryChanged(to: saved.metadata)
    }
    private func libraryChanged(to value: AppMetadata) {
        // Demo shows its own library; the real one is kept current for leaving it.
        if demo {
            libraryReplacements += 1
            let changed = realMetadata.connections.contains { !value.connections.contains($0) }
            realMetadata = value
            // Keys are kept through Demo, so one the connection edited or removed elsewhere used must go now.
            if changed { Task { await lockUnreferencedKeys() } }
            return
        }
        guard value != metadata else { return }
        let previous = metadata.connections
        metadata = value
        libraryReplacements += 1
        // A connection edited or removed elsewhere is treated as one edited or removed here: what
        // was read through its old settings isn't shown under the new ones, and its session ends.
        let affected = Set(previous.filter { !value.connections.contains($0) }.map(\.id))
        guard !affected.isEmpty else { return }
        // Its downloads stop as they did in the window that changed it. That window stopped those it knew of;
        // these are any this one started on the connection as it was, before it heard. A download started on the
        // connection as it is now goes on, however late this window hears.
        let current = value.connections
        if let downloads {
            Task { await downloads.interrupt(reason: Self.changedConnectionDownloadMessage) { affected.contains($0.profile.id) && !current.contains($0.profile) } }
        }
        routes.removeAll { affected.contains($0.connectionID) }
        affected.forEach { forgetListings(of: $0) }
        guard affected.contains(where: { connectionStates[$0] != nil || foregroundConnectionID == $0 }) else {
            // No session to end, but keys are kept after a reset or Demo, so one nothing uses now is locked.
            Task { await lockUnreferencedKeys() }
            return
        }
        sessionRevision += 1
        Task {
            await disconnect(preservingDownloads: true, keepingKeys: true)
            await lockUnreferencedKeys()
        }
    }
    /// Changes this window's copy of the library at once and then the saved one. The change is made
    /// to the library as it is saved now, never by writing this copy over it, so a window that hasn't
    /// yet heard of a connection or key added in another can't remove it by saving something else.
    private func updateLibrary(_ change: @escaping @Sendable (inout AppMetadata) -> Void) async {
        change(&metadata)
        guard !demo else { return }
        let replacements = libraryReplacements
        do { ownSaveFinished(try await metadataStore.update(origin: libraryOrigin, change), replacements: replacements) }
        catch { errorMessage = error.localizedDescription }
    }
    /// This window's copy held its own change before it was saved. If another window's save replaced
    /// the copy while this one waited, the copy no longer does, and the save just made is the one
    /// that holds both. A newer save already taken in holds it too.
    private func ownSaveFinished(_ saved: MetadataStore.Saved, replacements: Int) {
        guard libraryReplacements != replacements else { takeIn(saved); return }
        guard saved.revision >= libraryRevision else { return }
        libraryRevision = saved.revision
        libraryChanged(to: saved.metadata)
    }
    private func loadDownloads() {
        do {
            let manager = try DownloadManager.shared(directory: demo ? downloadDirectory.appendingPathComponent("Demo", isDirectory: true) : downloadDirectory)
            manager.protectedDataAvailable = { UIApplication.shared.isProtectedDataAvailable }
            let coordinator = BackgroundDownloadCoordinator.shared(for: manager)
            backgroundDownloads = coordinator
            manager.didChange = { [weak coordinator, weak manager] in
                guard let coordinator, let manager else { return }
                coordinator.update(manager)
            }
            if downloadSceneRegistration?.manager !== manager {
                downloadSceneRegistration = DownloadSceneRegistration(manager: manager)
            }
            manager.setForeground(isForeground, sceneID: downloadSceneRegistration?.id)
            downloads = manager; downloadError = nil
        } catch { downloads = nil; downloadSceneRegistration = nil; downloadError = error.localizedDescription }
    }
    func enqueueDownload(profile: ConnectionProfile, entry: RemoteEntry) {
        guard isForeground, !isDisconnecting, disconnectWork == nil, let downloads else { return }
        do {
            try downloads.enqueue(profile: profile, entry: entry.selectedForTransfer, service: demo ? demoDownloadTransport : downloadTransport,
                onFailure: downloadFailureHandler())
            sheet = .downloads
        }
        catch { errorMessage = error.localizedDescription }
    }
    func retryDownload(_ item: ManagedDownload) {
        guard isForeground, !isDisconnecting, disconnectWork == nil, let profile = profile(item.profile.id) else { return }
        do {
            try downloads?.retry(item.id, profile: profile, service: demo ? demoDownloadTransport : downloadTransport,
                onFailure: downloadFailureHandler())
        }
        catch { errorMessage = error.localizedDescription }
    }
    /// A download this window queued keeps its place if the window enters or leaves Demo, as when it goes to the
    /// background, and other windows keep the queue going. Its failure is then shown only in Downloads: a trust
    /// or unlock prompt for a real server doesn't appear over Demo, nor one for Demo's over the real library.
    private func downloadFailureHandler() -> (Error, ConnectionProfile) -> Void {
        let queuedInDemo = demo
        return { [weak self] error, profile in
            guard let self, self.demo == queuedInDemo else { return }
            self.handleDownloadFailure(error, profile: profile)
        }
    }
    private func handleDownloadFailure(_ error: Error, profile: ConnectionProfile) {
        guard isForeground, isSecurityError(error) else { return }
        handleTransferFailure(error, profile: profile)
    }
    func foregroundDownloads() { downloads?.setForeground(true, sceneID: downloadSceneRegistration?.id) }
    /// The scene is active again. Only the background ends a session, so only a return from it starts
    /// a new one, which has every folder, reader and search on screen read again. Control Centre,
    /// Notification Centre, a system prompt and Face ID leave the scene inactive with its connection
    /// open: starting again then would list the folder again, restart a search from nothing, close
    /// the Saved Search Index sheet on its build and reload a video from its first frame.
    /// A connection that had failed is still tried again, since what made the scene inactive may be
    /// what it was waiting for: the Local Network prompt, or Wi-Fi turned on in Control Centre.
    func sceneBecameActive() {
        let returning = !isForeground
        isForeground = true
        foregroundDownloads()
        if returning || connectionStates.values.contains(Self.disconnectedState) { sessionRevision += 1 }
    }
    private static let disconnectedState = "Disconnected"
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
                    _ = try await store.pin(profile: profile, entry: entry.selectedForTransfer, allowedRoot: entry.selectionRoot,
                                            service: transport, operationID: token) { [weak self] progress in
                        await self?.updatePinProgress(progress, token: token)
                    }
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, revision == sessionRevision, isForeground {
                    if isSecurityError(error) { handleTransferFailure(error, profile: profile) }
                    else if let remote = error as? RemoteFileError {
                        switch remote {
                        case .connectionEnded, .timedOut, .unavailable: handle(error, profile: profile)
                        default: break
                        }
                    }
                    if sheet == nil || sheet?.id == "offlineFiles" { errorMessage = Self.transferMessage(for: error) }
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
    func prepareReadingPosition(_ position: DocumentReadingPosition, text: String, profile: ConnectionProfile, path: String, discardingCurrent: Bool = false) async {
        await position.prepare(text: text, store: demo ? nil : readingPositions, connectionID: profile.id, path: path, discardingCurrent: discardingCurrent)
    }
    /// Returns false when the preview should open without a saved position.
    func preparePDFReadingPosition(_ position: DocumentReadingPosition, fileURL: URL, profile: ConnectionProfile, path: String) async -> Bool {
        await position.preparePDF(fileURL: fileURL, store: demo ? nil : readingPositions, connectionID: profile.id, path: path)
    }
    func profile(_ id: UUID) -> ConnectionProfile? { metadata.connections.first { $0.id == id } }
    /// Offline copies share the connected reader's history. A removed connection's history was
    /// deleted with it; its surviving copies must not start writing new history under that id.
    func offlineReadingPositions(for pin: OfflinePin) -> ReadingPositionStore? {
        demo || profile(pin.connectionID) == nil ? nil : readingPositions
    }
    /// Installation is direct: a bastion-only identity must not prefill the destination account.
    func installationConnection(for identity: IdentityMetadata) -> ConnectionProfile? {
        metadata.connections.first { $0.identityID == identity.id }
    }
    /// Saves this window's whole copy of the library, replacing whatever is saved. That is only
    /// right for the library's one writer, which a test seeding a library is. The app's own changes
    /// go through `updateLibrary`.
    func persist() async {
        guard !demo else { return }
        let replacements = libraryReplacements
        do { ownSaveFinished(try await metadataStore.save(metadata, origin: libraryOrigin), replacements: replacements) }
        catch { errorMessage = error.localizedDescription }
    }
    func saveConnection(_ value: ConnectionProfile) async {
        // Its downloads stop, in every window: its server, account or key may have changed, and Retry won't
        // continue one across a changed connection. Other connections' downloads go on.
        await downloads?.interrupt(reason: Self.changedConnectionDownloadMessage) { $0.profile.id == value.id }
        await disconnect(preservingDownloads: true, keepingKeys: true)
        // The iPad sidebar can edit the connection whose reader is still on screen.
        routes.removeAll { $0.connectionID == value.id }
        sessionRevision += 1
        do { try await searchIndexStore().remove(connectionID: value.id) }
        catch { errorMessage = error.localizedDescription }
        await updateLibrary { library in
            library.connections.removeAll { $0.id == value.id }
            library.connections.append(value)
        }
        // An edit may have moved the connection to another key. The old one stays unlocked only while
        // something else uses it.
        await lockUnreferencedKeys()
    }
    func removeConnection(_ profile: ConnectionProfile) async {
        await downloads?.interrupt(reason: Self.changedConnectionDownloadMessage) { $0.profile.id == profile.id }
        await disconnect(preservingDownloads: true, keepingKeys: true)
        routes.removeAll { $0.connectionID == profile.id }
        sessionRevision += 1
        do { try await searchIndexStore().remove(connectionID: profile.id) }
        catch { errorMessage = error.localizedDescription }
        let id = profile.id
        if !demo {
            do { try await readingPositions.remove(connectionID: id) }
            catch { errorMessage = error.localizedDescription }
            storeFolderSortOrders(folderSortOrders().filter { !$0[0].hasPrefix(id.uuidString + "|") })
        }
        await updateLibrary { library in
            library.connections.removeAll { $0.id == id }
            library.favourites.removeAll { $0.connectionID == id }
            library.recents.removeAll { $0.connectionID == id }
        }
        await lockUnreferencedKeys()
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
    /// Stored as [key, order] pairs, oldest first. Read from the file each time: every window has
    /// its own model, and a copy held here would be written back over another window's choice.
    func folderSortOrders() -> [[String]] {
        moveFolderSortOrdersOutOfPreferences()
        guard let bytes = try? Data(contentsOf: folderSortFile),
              let entries = try? JSONDecoder().decode([[String]].self, from: bytes) else { return [] }
        return entries.filter { $0.count == 2 }
    }
    private func storeFolderSortOrders(_ entries: [[String]]) {
        moveFolderSortOrdersOutOfPreferences()
        writeFolderSortOrders(entries)
    }
    @discardableResult private func writeFolderSortOrders(_ entries: [[String]]) -> Bool {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: folderSortFile)
            return !FileManager.default.fileExists(atPath: folderSortFile.path)
        }
        do {
            try FileManager.default.createDirectory(at: folderSortFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(entries)
            #if os(iOS)
            try bytes.write(to: folderSortFile, options: [.atomic, .completeFileProtection])
            #else
            try bytes.write(to: folderSortFile, options: .atomic)
            #endif
            // Which folders exist on a server is not something a backup needs to carry.
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var file = folderSortFile
            try? file.setResourceValues(values)
            return true
        } catch { return false }
    }
    /// Earlier versions kept these in the preferences file, the one place remote paths were stored
    /// without complete file protection. The preference goes only once the file holds its entries.
    private func moveFolderSortOrdersOutOfPreferences() {
        guard let legacy = preferences.array(forKey: Self.folderSortKey) else { return }
        let entries = (legacy as? [[String]])?.filter { $0.count == 2 } ?? []
        guard FileManager.default.fileExists(atPath: folderSortFile.path) || writeFolderSortOrders(entries) else { return }
        preferences.removeObject(forKey: Self.folderSortKey)
    }
    /// Forgets the trusted key of the saved endpoint, never unsaved edits in the connection form.
    func resetTrust(for profile: ConnectionProfile) async {
        await interruptDownloads(through: HostEndpoint(host: profile.host, port: profile.port))
        await disconnect(preservingDownloads: true, keepingKeys: true)
        do { try await searchIndexStore().remove(connectionID: profile.id) }
        catch { errorMessage = error.localizedDescription }
        // Forgetting trust must remain possible even when the local search cache is damaged.
        do { try await trust.reset(endpoint: HostEndpoint(host: profile.host, port: profile.port)) }
        catch { errorMessage = error.localizedDescription }
    }
    func resetJumpHostTrust(for profile: ConnectionProfile) async {
        guard let jump = profile.jumpHost else { return }
        await interruptDownloads(through: HostEndpoint(host: jump.host, port: jump.port))
        await disconnect(preservingDownloads: true, keepingKeys: true)
        do { try await searchIndexStore().remove(connectionID: profile.id) }
        catch { errorMessage = error.localizedDescription }
        do { try await trust.reset(endpoint: HostEndpoint(host: jump.host, port: jump.port)) }
        catch { errorMessage = error.localizedDescription }
    }
    /// Stops every download that reaches a server whose trusted key is being forgotten, directly or through it
    /// as a jump host, whichever connection it was started from. Downloads from other servers go on.
    private func interruptDownloads(through endpoint: HostEndpoint) async {
        func reaches(_ profile: ConnectionProfile) -> Bool {
            HostEndpoint(host: profile.host, port: profile.port) == endpoint ||
            profile.jumpHost.map { HostEndpoint(host: $0.host, port: $0.port) == endpoint } == true
        }
        await downloads?.interrupt(reason: "This server's trusted key was forgotten. Retry to check it again and continue.") { reaches($0.profile) }
    }
    static let changedConnectionDownloadMessage = "This download's connection was changed or removed. Download the file again."
    func addIdentity(_ value: IdentityMetadata) async throws {
        guard !demo else { throw RemoteFileError.unavailable("Leave Demo before saving keys.") }
        // Shown only once it's saved.
        let saved = try await metadataStore.update(origin: libraryOrigin) { $0.identities.append(value) }
        if !metadata.identities.contains(where: { $0.id == value.id }) { metadata.identities.append(value) }
        takeIn(saved)
    }
    func deleteIdentity(_ value: IdentityMetadata) async {
        do {
            // Asked of the saved library as well as this window's copy: a connection made in another
            // window a moment ago uses its key too.
            let saved = demo ? [] : await metadataStore.snapshot().connections
            try await identities.delete(value, referencedBy: Set((metadata.connections + saved).flatMap { $0.identityIDs }))
            let id = value.id
            await updateLibrary { $0.identities.removeAll { $0.id == id } }
        } catch { errorMessage = error.localizedDescription }
    }
    func favourite(profile: ConnectionProfile, path: String) async {
        let id = profile.id
        if metadata.favourites.contains(where: { $0.connectionID == id && $0.path == path }) {
            await updateLibrary { $0.favourites.removeAll { $0.connectionID == id && $0.path == path } }
        } else {
            // Made once, so this window's copy and the saved library hold the same entry.
            let added = SavedLocation(connectionID: id, path: path, name: RemotePath.name(of: path))
            await updateLibrary { library in
                if !library.favourites.contains(where: { $0.connectionID == id && $0.path == path }) { library.favourites.append(added) }
            }
        }
    }
    func isFavourite(_ id: UUID, path: String) -> Bool { metadata.favourites.contains { $0.connectionID == id && $0.path == path } }
    func recordRecent(profile: ConnectionProfile, entry: RemoteEntry) async {
        // Every load and every check of an open file comes here. When it's already the newest recent
        // there is nothing to record, and recording it anyway would rewrite the library, give the
        // row a new identity and have every screen that reads the library made again.
        if let newest = metadata.recents.first, newest.connectionID == profile.id,
           newest.path.utf8.elementsEqual(entry.path.utf8), newest.name == entry.name { return }
        let id = profile.id, path = entry.path
        let added = SavedLocation(connectionID: id, path: path, name: entry.name)
        await updateLibrary { library in
            library.recents.removeAll { $0.connectionID == id && $0.path == path }
            library.recents.insert(added, at: 0)
            library.recents = Array(library.recents.prefix(8))
        }
    }
    func removeRecent(_ location: SavedLocation) async {
        do {
            if !demo { try await metadataStore.removeRecent(id: location.id, origin: libraryOrigin) }
            metadata.recents.removeAll { $0.id == location.id }
            if !demo { takeIn(await metadataStore.current()) }
        } catch { errorMessage = "Couldn’t remove this recent entry. \(error.localizedDescription)" }
    }
    /// Escalates like `handle`, but describes a chosen file or folder that moved or now leads
    /// elsewhere in its own terms. The document-link message would blame the starting folder,
    /// which no longer bounds downloads, Keep Offline or Save Original.
    func handleTransferFailure(_ error: Error, profile: ConnectionProfile) {
        handle(error, profile: profile)
        if errorMessage == error.localizedDescription { errorMessage = Self.transferMessage(for: error) }
    }
    static func transferMessage(for error: Error) -> String {
        switch error {
        case RemoteDocumentLinkError.outsideConnection, RemoteResourceError.outsideDocument:
            return OriginalFileExportError.outsideRoot.localizedDescription
        default: return error.localizedDescription
        }
    }
    func handle(_ error: Error, profile: ConnectionProfile) {
        guard !isDisconnecting else { return }
        connectionFailureRevisions[profile.id, default: 0] += 1
        connectionStates[profile.id] = Self.disconnectedState
        // A path outside its boundary says nothing about the connection; these do.
        if isConnectionSecurityError(error) {
            mediaSecurityFailures[profile.id] = error.localizedDescription
            forgetListings(of: profile.id)
        }
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
    private func isConnectionSecurityError(_ error: Error) -> Bool {
        if error is HostTrustError || error is IdentityError || error is ConnectionIdentityUnlockRequired { return true }
        if case RemoteFileError.authenticationFailed = error { return true }
        return false
    }
    func isSecurityError(_ error: Error) -> Bool {
        if isConnectionSecurityError(error) { return true }
        if let boundary = error as? RemoteDocumentLinkError, boundary == .outsideConnection { return true }
        if case RemoteResourceError.outsideDocument = error { return true }
        return false
    }
    /// Ends this window's session. Unlocked keys lock again unless `keepingKeys`: that is for changes to
    /// connections, trust or Demo, which close the connection but must not make every key in this window,
    /// including those downloads and other connections use, ask for its passphrase again. Disconnect and
    /// backgrounding lock them.
    func disconnect(preservingDownloads: Bool = false, keepingListings: Bool = false, keepingKeys: Bool = false) async {
        if let disconnectWork {
            // Joining a close that keeps keys must not leave them unlocked for a call that locks them.
            let joinedKeepsKeys = disconnectKeepsKeys
            await disconnectWork.value
            if joinedKeepsKeys, !keepingKeys { await identities.clearSession() }
            return
        }
        let task = Task {
            if !preservingDownloads {
                await downloads?.interrupt(reason: "Transfer interrupted. Retry to continue.")
                backgroundDownloads.finish(success: false)
            }
            await closeSession(keepingListings: keepingListings, keepingKeys: keepingKeys)
        }
        disconnectWork = task; disconnectKeepsKeys = keepingKeys
        await task.value
        disconnectWork = nil
    }
    /// Locks the keys no saved connection or jump host uses. Used after an edit or removal, so a key whose
    /// last connection moved to another key or went doesn't stay unlocked. What counts as used is the real
    /// library, even in Demo, whose own connections use no real key, and the saved one as well as this
    /// window's copy: a connection another window has just made uses its key too.
    private func lockUnreferencedKeys() async {
        let saved = await metadataStore.snapshot()
        let referenced = Set((realLibrary.connections + saved.connections).flatMap(\.identityIDs))
        await identities.clearSession(keeping: referenced)
    }
    private var realLibrary: AppMetadata { demo ? realMetadata : metadata }
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
    private func closeSession(keepingListings: Bool = false, keepingKeys: Bool = false) async {
        let previousPin = pinTask
        cancelPrefetch()
        cancelOfflinePin()
        indexUpdates.cancelAll()
        let previousExporter = exportService
        await previousExporter?.cancelAll()
        await resourceService?.cancelAll(); resourceService = nil
        await publicKeyInstaller.cancelAll()
        // The base service's own disconnect locks keys, so a close that keeps them uses the one that doesn't.
        // A service without one, such as Demo's, holds no keys.
        if keepingKeys, let closer = service as? any RemoteFileSessionClosing { await closer.closeSessionPreservingUnlockedIdentities() }
        else { await service.disconnect() }
        await previousPin?.value
        await RemoteImageDecoder.shared.clear()
        await SourceHighlighting.shared.clear()
        await previousExporter?.cancelAndDrain()
        exportService = nil
        if !keepingKeys { await identities.clearSession() }
        connectionStates = [:]
        // Names already seen stay in memory for an instant return from the background, unless they
        // were read with a key that locks again now. All are checked with the server when next
        // shown; an explicit disconnect forgets them.
        if keepingListings {
            documents.removeAll(); documentOrder.removeAll()
            for profile in metadata.connections where profile.identityIDs.contains(where: { id in
                metadata.identities.contains { $0.id == id && $0.requiresPassphrase }
            }) { forgetListings(of: profile.id) }
            for key in directories.keys { directories[key]?.storedAt = nil }
        } else { clearCaches() }
    }
    func background() async {
        // Offline navigation owns no connection or credentials. Keep its stack while the reader
        // releases protected local resources; transient trust/key/edit sheets still disappear.
        if case .offlineFiles = sheet { } else if case .downloads = sheet { } else { sheet = nil }
        downloads?.setForeground(false, sceneID: downloadSceneRegistration?.id)
        await disconnect(preservingDownloads: downloads?.isForeground == true || backgroundDownloads.canContinue, keepingListings: true)
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
    func clearCaches() {
        clearListings()
        documents.removeAll(); documentOrder.removeAll()
    }
    private func clearListings() {
        directories.removeAll(); directoryOrder.removeAll()
        cancelPrefetch()
    }
    /// By the path's bytes: two names that differ only in Unicode normalisation are two files.
    private struct CacheKey: Hashable { let id: UUID; let path: RemotePathKey }
    private func key(_ id: UUID, _ path: String) -> CacheKey { CacheKey(id: id, path: RemotePathKey(path)) }
    func cachedListing(_ id: UUID, path: String) -> FolderListing? { directories[key(id, path)]?.listing }
    /// Whether a remembered listing is recent enough to show without asking the server again.
    func isListingFresh(_ id: UUID, path: String, within window: Duration = AppModel.listingFreshness) -> Bool {
        guard let stored = directories[key(id, path)]?.storedAt else { return false }
        return ContinuousClock.now - stored < window
    }
    /// A listing younger than this was very likely prefetched moments ago.
    static let listingFreshness: Duration = .seconds(20)
    static let listingLimit = 48
    /// Bytes of names and paths remembered across folders. Rows alone don't bound memory: a server
    /// chooses how long each name is.
    static let listingByteLimit = 16 * 1_024 * 1_024
    func cache(_ value: FolderListing, id: UUID, requestedPath: String) {
        let k = key(id, requestedPath)
        directories[k] = (value, .now, value.rows.reduce(0) { $0 + $1.entry.nameBytes })
        directoryOrder.removeAll { $0 == k }; directoryOrder.append(k)
        // Bound the names kept in memory as well as the folders: a few huge listings can't pile up.
        // The newest always stays, since it is on screen or about to be.
        while directoryOrder.count > Self.listingLimit
                || (directoryOrder.count > 1 && (directories.values.reduce(0, { $0 + $1.listing.rows.count }) > 40_000
                                                  || directories.values.reduce(0, { $0 + $1.nameBytes }) > Self.listingByteLimit)) {
            directories.removeValue(forKey: directoryOrder.removeFirst())
        }
    }
    /// Lists the first few subfolders of a folder on screen, one at a time, so opening one shows its
    /// rows straight away. A newer folder replaces the waiting ones without cancelling the one in
    /// flight. It stops at the first failure and leaves anything already remembered to be checked
    /// when opened, so an unreadable or slow server sees almost nothing from this.
    func prefetchFolders(in listing: FolderListing, profile: ConnectionProfile, limit: Int = 6) {
        guard isForeground, !isDisconnecting, foregroundConnectionID == profile.id, !PrefetchConditions.shared.discouraged else { return }
        folderPrefetchQueue = listing.defaultRows.lazy
            .compactMap { row -> String? in
                guard row.entry.link == nil, row.entry.kind == .directory else { return nil }
                return row.entry.path
            }
            .filter { self.cachedListing(profile.id, path: $0) == nil }
            .prefix(limit)
            .map { (profile, $0) }
        guard folderPrefetch == nil, !folderPrefetchQueue.isEmpty else { return }
        let revision = sessionRevision, token = UUID()
        folderPrefetchToken = token
        folderPrefetch = Task { [weak self] in
            while let self, !Task.isCancelled, !self.folderPrefetchQueue.isEmpty,
                  self.sessionRevision == revision, self.isForeground, !self.isDisconnecting {
                let next = self.folderPrefetchQueue.removeFirst()
                guard next.profile.id == self.foregroundConnectionID, !PrefetchConditions.shared.discouraged else { break }
                guard self.cachedListing(next.profile.id, path: next.path) == nil else { continue }
                let generation = self.listingGeneration(next.profile.id)
                guard let found = try? await self.quietListing(next.profile, path: next.path), !Task.isCancelled, next.profile.id == self.foregroundConnectionID else {
                    self.folderPrefetchQueue.removeAll(); break
                }
                let prepared = await Task.detached(priority: .utility) { FolderListing(found) }.value
                guard !Task.isCancelled, self.sessionRevision == revision, self.isForeground, !self.isDisconnecting else { break }
                // Nothing was remembered when this was asked for, so anything there now came from opening
                // the folder, and is newer than this.
                guard self.listingGeneration(next.profile.id) == generation,
                      self.cachedListing(next.profile.id, path: next.path) == nil else { continue }
                self.cache(prepared, id: next.profile.id, requestedPath: next.path)
            }
            if self?.folderPrefetchToken == token { self?.folderPrefetch = nil; self?.folderPrefetchToken = nil }
        }
    }
    /// A listing that won't connect, cancel or queue behind foreground work when the transport can
    /// offer that. Nil means there's no session to ask over.
    func quietListing(_ profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot? {
        if let background = searchService as? BackgroundFolderListing {
            return try await background.listDirectoryInBackground(profile: profile, path: path)
        }
        return try await service.listDirectory(profile: profile, path: path)
    }
    /// Which connection the screen is using. Work prepared ahead for another one stops here.
    func noteForegroundConnection(_ id: UUID) {
        guard foregroundConnectionID != id else { return }
        foregroundConnectionID = id
        folderPrefetchQueue.removeAll()
        // The transport keeps one session, so opening this one ends any other.
        connectionStates = connectionStates.filter { $0.key == id }
    }
    private func cancelPrefetch() {
        folderPrefetchQueue.removeAll()
        folderPrefetch?.cancel(); folderPrefetch = nil; folderPrefetchToken = nil
    }
    /// A key or host that fails verification takes what was read through it out of memory, so
    /// reopening a folder or file can't show it without getting past that check.
    private func forgetListings(of id: UUID) {
        for key in directoryOrder where key.id == id { directories.removeValue(forKey: key) }
        directoryOrder.removeAll { $0.id == id }
        for key in documentOrder where key.id == id { documents.removeValue(forKey: key) }
        documentOrder.removeAll { $0.id == id }
        folderPrefetchQueue.removeAll { $0.profile.id == id }
        forgottenListings[id, default: 0] += 1
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
    /// Keeps a document's bytes only if reopening them can't bring back a key its preview hides.
    /// The reader then reads such a file again, and an older copy of it doesn't linger.
    func cache(_ value: Data, decodedAs preview: DocumentPreview, version: RemoteFileVersion? = nil, id: UUID, path: String) {
        if preview.allowsKeepingOriginalBytes {
            cache(value, version: version, id: id, path: path)
        } else {
            let k = key(id, path)
            documents.removeValue(forKey: k); documentOrder.removeAll { $0 == k }
        }
    }
    /// The switch under way. Requests run one at a time, so a second request made while the first
    /// is disconnecting can't save the Demo library as the one to restore.
    private var demoSwitch: Task<Void, Never>?
    func setDemo(_ enabled: Bool) async {
        while let pending = demoSwitch { await pending.value }
        guard enabled != demo else { return }
        // Cleared by the switch itself, before any waiting request resumes: one that found it still
        // set would await the finished task again without suspending, and never let this one finish.
        let work = Task { await switchDemo(to: enabled); demoSwitch = nil }
        demoSwitch = work
        await work.value
    }
    private func switchDemo(to enabled: Bool) async {
        // Other windows' downloads go on. This window's place among the queue's windows goes when `loadDownloads`
        // replaces its registration; if no window is then left in the foreground, the queue is interrupted as when
        // the last window closes.
        await disconnect(preservingDownloads: true, keepingKeys: true); routes = []
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
        loadDownloads()
    }
}

#endif
