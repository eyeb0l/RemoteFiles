#if os(iOS)
import XCTest
import Foundation
import Crypto
import NIOSSH
import RemoteFilesCore
@testable import RemoteFilesUI

private actor BackgroundExportService: RemoteFileService {
    private var blocked: CheckedContinuation<Void, Error>?
    private(set) var destination: URL?
    private(set) var disconnects = 0
    private(set) var downloads = 0
    private var bytes = Data("old server bytes".utf8)
    private var downloadFailure: Error?
    func failDownloads(_ error: Error) { downloadFailure = error }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        .init(path: path, entries: [])
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { bytes }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                      destination: URL, limit: Int) async throws -> RemoteEntry {
        downloads += 1
        if let downloadFailure { throw downloadFailure }
        self.destination = destination
        try bytes.write(to: destination)
        if disconnects == 0 {
            // Intentionally ignore task cancellation; only transport teardown retires it.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in blocked = continuation }
        }
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: UInt64(bytes.count))
    }
    func disconnect() {
        disconnects += 1
        bytes = Data("changed server bytes\r\n東京  ".utf8)
        blocked?.resume(throwing: CancellationError()); blocked = nil
    }
    func waiting() -> Bool { blocked != nil }
}

private actor NestedDisconnectService: RemoteFileService {
    private var readWaiter: CheckedContinuation<Data, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private(set) var disconnects = 0
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: []) }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { .init(name: "report.md", path: path, kind: .file) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        // Simulate an uncooperative completed request racing with explicit transport teardown.
        await withCheckedContinuation { readWaiter = $0 }
    }
    func disconnect() async {
        disconnects += 1
        readWaiter?.resume(returning: Data("late bytes".utf8)); readWaiter = nil
        await withCheckedContinuation { closeWaiter = $0 }
    }
    func reading() -> Bool { readWaiter != nil }
    func closing() -> Bool { closeWaiter != nil }
    func finishClose() { closeWaiter?.resume(); closeWaiter = nil }
}

private actor DisconnectKeyInstaller: PublicKeyInstalling {
    private(set) var cancellations = 0
    func install(_ request: PublicKeyInstallationRequest, password: String) async throws -> PublicKeyInstallationResult { .installed }
    func cancelAll() { cancellations += 1 }
}

@MainActor final class AppModelLifecycleTests: XCTestCase {
    func testDownloadRetryUsesRequestingWindowsTransportAndUnlockSheet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstService = BackgroundExportService(), secondService = BackgroundExportService()
        await firstService.failDownloads(IdentityError.missingPassphrase)
        await secondService.failDownloads(IdentityError.missingPassphrase)
        let first = try AppModel(directory: directory, fileService: firstService)
        let second = try AppModel(directory: directory, fileService: secondService)
        await first.load(); await second.load()
        let identity = IdentityMetadata(name: "Encrypted", publicKey: "fixture", fingerprint: "fixture", requiresPassphrase: true, keychainReference: "fixture")
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: identity.id)
        first.metadata.identities = [identity]; first.metadata.connections = [profile]
        second.metadata.identities = [identity]; second.metadata.connections = [profile]
        first.enqueueDownload(profile: profile, entry: .init(name: "file.bin", path: "/file.bin", kind: .file))
        let manager = try XCTUnwrap(first.downloads)
        let deadline = ContinuousClock.now + .seconds(3)
        while manager.activeID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(first.sheet?.id, "unlock"); XCTAssertNil(second.sheet)
        let item = try XCTUnwrap(manager.items.first)
        first.sheet = nil
        second.retryDownload(item)
        while manager.activeID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(second.sheet?.id, "unlock"); XCTAssertNil(first.sheet)
        let firstRequests = await firstService.downloads, secondRequests = await secondService.downloads
        XCTAssertEqual(firstRequests, 1); XCTAssertEqual(secondRequests, 1)
    }

    func testBackgroundWindowKeepsOtherWindowsDownloadRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstService = BackgroundExportService(), secondService = BackgroundExportService()
        let first = try AppModel(directory: directory, fileService: firstService)
        let second = try AppModel(directory: directory, fileService: secondService)
        await first.load(); await second.load()
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID())
        first.enqueueDownload(profile: profile, entry: .init(name: "file.bin", path: "/file.bin", kind: .file))
        let manager = try XCTUnwrap(first.downloads)
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await firstService.waiting()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        second.isForeground = false
        await second.background()
        XCTAssertTrue(manager.isForeground)
        XCTAssertEqual(manager.items.first?.state, .downloading)
        let disconnects = await firstService.disconnects
        XCTAssertEqual(disconnects, 0)
        await first.disconnect()
    }

    func testDownloadUnknownHostPresentsTrustSheet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService()
        let key = try HostKeyDetails(publicKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey)
        await service.failDownloads(HostTrustError.unknown(endpoint: .init(host: "fixture.invalid"), key: key))
        let model = try AppModel(directory: directory, fileService: service)
        await model.load()
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID())
        model.enqueueDownload(profile: profile, entry: .init(name: "file.bin", path: "/file.bin", kind: .file))
        let deadline = ContinuousClock.now + .seconds(3)
        while model.downloads?.activeID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.sheet?.id, "trust")
    }

    func testOfflineStoreIsSharedWhenAnotherWindowOpensAfterLibraryCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try AppModel(directory: directory, fileService: BackgroundExportService())
        await owner.load()
        let realStore = try XCTUnwrap(owner.offlineStore)
        let second = try AppModel(directory: directory, fileService: BackgroundExportService())
        await second.load()
        XCTAssertTrue(realStore === second.offlineStore)
        await owner.setDemo(true)
        let demoStore = try XCTUnwrap(owner.offlineStore)
        await second.setDemo(true)
        XCTAssertTrue(demoStore === second.offlineStore)
        XCTAssertFalse(realStore === demoStore)
        await second.setDemo(false)
        XCTAssertTrue(realStore === second.offlineStore)
    }

    func testOfflineFoldersPropagateAcrossWindowsKeepRouteChecksAndRemainLocalAfterConnectionRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try AppModel(directory: directory, fileService: BackgroundExportService())
        let second = try AppModel(directory: directory, fileService: BackgroundExportService())
        await owner.load(); await owner.setDemo(true)
        await second.load(); await second.setDemo(true)
        if let demo = owner.searchService as? DemoRemoteFileService {
            await demo.configure(delayNanoseconds: 0, failure: nil)
        }
        let profile = try XCTUnwrap(owner.metadata.connections.first)
        owner.pinOffline(profile: profile, entry: .init(name: "Reports", path: "/Projects/Reports", kind: .directory))
        try await waitForOfflineState { owner.pinningName == nil && second.offlineFolders.count == 1 }
        let folder = try XCTUnwrap(owner.offlineFolders.first)
        XCTAssertEqual(folder.fileIDs.count, 5); XCTAssertEqual(owner.offlinePins.count, 5)
        XCTAssertTrue(owner.standaloneOfflinePins.isEmpty); XCTAssertNil(owner.folderPinProgress)
        XCTAssertEqual(second.offlineFolders, [folder]); XCTAssertEqual(second.offlinePins.count, 5)
        owner.metadata.connections[0].host = "changed.invalid"
        owner.refreshOfflineFolder(folder)
        XCTAssertNotNil(owner.errorMessage); XCTAssertNil(owner.pinningName)
        await owner.removeConnection(owner.metadata.connections[0])
        XCTAssertEqual(owner.offlineFolders, [folder])
        let store = try XCTUnwrap(owner.offlineStore), lease = try await store.lease(try XCTUnwrap(folder.fileIDs.first))
        XCTAssertFalse(try Data(contentsOf: lease.url).isEmpty)
        await owner.removeOfflineFolder(folder)
        try await waitForOfflineState { second.offlineFolders.isEmpty && second.offlinePins.isEmpty }
    }

    func testBackgroundCancelsFolderTraversalAndDemoSwitchDoesNotMixLibraries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        await model.load(); await model.setDemo(true)
        let profile = try XCTUnwrap(model.metadata.connections.first)
        model.pinOffline(profile: profile, entry: .init(name: "Reports", path: "/Projects/Reports", kind: .directory))
        XCTAssertNotNil(model.folderPinProgress)
        model.isForeground = false; await model.background()
        XCTAssertNil(model.pinningName); XCTAssertTrue(model.offlineFolders.isEmpty); XCTAssertTrue(model.offlinePins.isEmpty)
        model.isForeground = true
        await model.setDemo(false)
        XCTAssertTrue(model.offlineFolders.isEmpty); XCTAssertTrue(model.offlinePins.isEmpty)
    }

    func testWorkspaceKeepsFolderAlongsidePreviewAndSharesRoutesWithCompactNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        let id = UUID(), folder = AppModel.Route.folder(UUID(), "/work")
        let root = AppModel.Route.folder(id, "/"), nested = AppModel.Route.folder(id, "/docs")
        model.routes = [root, nested]
        let first = RemoteEntry(name: "one.md", path: "/docs/one.md", kind: .file)
        let second = RemoteEntry(name: "two.md", path: "/docs/two.md", kind: .file)
        model.openInWorkspace(.file(id, first))
        XCTAssertEqual(model.workspaceFolder, nested); XCTAssertEqual(model.workspaceFile, .file(id, first))
        model.openInWorkspace(.file(id, second))
        XCTAssertEqual(model.routes, [root, nested, .file(id, second)], "Preview changes replace rather than grow a hidden stack")
        model.goBackInWorkspace(); XCTAssertEqual(model.routes, [root]); XCTAssertNil(model.workspaceFile)
        model.openInWorkspace(.file(id, first))
        model.showFolder(id, path: "/new")
        XCTAssertEqual(model.routes, [root, .folder(id, "/new")], "A new breadcrumb must not retain a hidden preview")
        model.goBackInWorkspace(); XCTAssertEqual(model.routes, [root]); XCTAssertNil(model.workspaceFile)
        model.routes = [folder]; XCTAssertEqual(model.workspaceFolder, folder)
        model.routes = [root, .file(id, first), .file(id, second)]
        model.openInWorkspace(.folder(id, "/next"))
        XCTAssertEqual(model.routes, [root, .folder(id, "/next")], "Widening a linked-reader stack must not retain hidden previews")
        model.goBackInWorkspace(); XCTAssertEqual(model.routes, [root]); XCTAssertNil(model.workspaceFile)
        model.routes = [.file(id, first)]; XCTAssertEqual(model.workspaceFolder, .folder(id, "/docs"))
        model.showFolder(id, path: "/docs")
        XCTAssertEqual(model.routes, [.folder(id, "/docs")], "Choosing a recent's parent breadcrumb must not duplicate it")
        model.openInWorkspace(.file(id, first))
        model.openInWorkspace(.folder(id, "/docs/subfolder"))
        model.goBackInWorkspace(); XCTAssertEqual(model.routes, [.folder(id, "/docs")], "A recent's containing folder stays in folder history")
        await model.disconnectAndGoHome(); XCTAssertNil(model.workspaceFile); XCTAssertNil(model.workspaceFolder)
    }

    func testWorkspaceLayoutFollowsSizeClassesRatherThanDevice() {
        XCTAssertTrue(AppNavigation.usesWorkspace(horizontal: .regular, vertical: .regular), "A regular iPad window or unfolded iPhone Duo")
        XCTAssertFalse(AppNavigation.usesWorkspace(horizontal: .regular, vertical: .compact), "A landscape phone keeps stack navigation")
        XCTAssertFalse(AppNavigation.usesWorkspace(horizontal: .compact, vertical: .regular), "A folded phone or narrow window")
        XCTAssertFalse(AppNavigation.usesWorkspace(horizontal: .compact, vertical: .compact))
        XCTAssertFalse(AppNavigation.usesWorkspace(horizontal: nil, vertical: nil))
    }

    func testEditingAndDeletingTheVisibleConnectionRetireItsWorkspaceRoutes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        var profile = ConnectionProfile(name: "Server", host: "old.invalid", username: "reader", identityID: UUID())
        model.metadata.connections = [profile]
        model.routes = [.folder(profile.id, "/docs"), .file(profile.id, .init(name: "one.md", path: "/docs/one.md", kind: .file))]
        let revision = model.sessionRevision
        profile.host = "new.invalid"
        await model.saveConnection(profile)
        XCTAssertTrue(model.routes.isEmpty, "Old server content must not remain in the new connection's pane")
        XCTAssertEqual(model.sessionRevision, revision + 1)
        model.routes = [.folder(profile.id, "/docs")]
        await model.removeConnection(profile)
        XCTAssertTrue(model.routes.isEmpty); XCTAssertNil(model.workspaceFolder); XCTAssertNil(model.workspaceFile)
        XCTAssertTrue(model.metadata.connections.isEmpty)
    }

    func testJumpHostTrustResetAndIdentityReferencesStaySeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService(), identities: IdentityStore(secretStore: JumpLifecycleSecrets()))
        let identity = try await model.identities.generate(name: "Jump")
        let profile = ConnectionProfile(name: "Target", host: "target.invalid", username: "reader", identityID: UUID(), jumpHost: JumpHost(host: "jump.invalid", port: 2222, username: "jump", identityID: identity.id))
        model.metadata.identities = [identity]; model.metadata.connections = [profile]
        XCTAssertNil(model.installationConnection(for: identity), "A jump-only identity must not suggest installation into the destination account")
        var destinationUse = profile; destinationUse.identityID = identity.id
        model.metadata.connections = [destinationUse]
        XCTAssertEqual(model.installationConnection(for: identity), destinationUse)
        model.metadata.connections = [profile]
        await model.deleteIdentity(identity)
        XCTAssertEqual(model.metadata.identities, [identity]); XCTAssertNotNil(model.errorMessage)
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let hop = HostEndpoint(host: "jump.invalid", port: 2222), target = HostEndpoint(host: "target.invalid", port: 22)
        try await model.trust.trustUnknown(endpoint: hop, key: HostKeyDetails(publicKey: key))
        try await model.trust.trustUnknown(endpoint: target, key: HostKeyDetails(publicKey: key))
        await model.resetJumpHostTrust(for: profile)
        do { try await model.trust.validate(endpoint: hop, publicKey: key); XCTFail("Hop trust must reset") } catch HostTrustError.unknown { }
        try await model.trust.validate(endpoint: target, publicKey: key)
        model.handle(ConnectionIdentityUnlockRequired(identity: identity), profile: profile)
        guard case .unlock(let requested) = model.sheet else { return XCTFail("Missing unlock sheet") }
        XCTAssertEqual(requested.id, identity.id)
    }

    private func wait(_ predicate: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "LifecycleFixtureDeadline", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testNestedDisconnectReturnsHomeBeforeDrainAndCancelsLateReadAndKeyWorkOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = NestedDisconnectService(), keys = DisconnectKeyInstaller()
        let service = CoalescingFileService(base: base)
        let model = try AppModel(directory: directory, fileService: service, publicKeyInstaller: keys)
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "fixture", identityID: UUID())
        let entry = RemoteEntry(name: "report.md", path: "/nested/report.md", kind: .file)
        model.metadata.connections = [profile]
        let recent = SavedLocation(connectionID: profile.id, path: entry.path, name: entry.name); model.metadata.recents = [recent]
        model.routes = [.folder(profile.id, "/"), .folder(profile.id, "/nested"), .file(profile.id, entry)]
        model.sheet = .keys; model.errorMessage = "old failure"; model.cache(Data("stale".utf8), id: profile.id, path: entry.path)
        let read = Task { try await service.readFile(profile: profile, path: entry.path, limit: 1024) }
        try await wait { await base.reading() }
        let revision = model.sessionRevision
        let disconnect = Task { await model.disconnectAndGoHome() }
        try await wait { await base.closing() }
        XCTAssertTrue(model.routes.isEmpty, "Home appears while teardown is still suspended")
        XCTAssertNil(model.sheet); XCTAssertNil(model.errorMessage); XCTAssertTrue(model.isDisconnecting)
        XCTAssertEqual(model.sessionRevision, revision + 1); XCTAssertNil(model.cachedDocument(profile.id, path: entry.path))
        await model.disconnectAndGoHome()
        var joinedStarted = false
        let joined = Task { joinedStarted = true; await model.disconnect() }
        try await wait { joinedStarted }
        await base.finishClose(); await disconnect.value; await joined.value
        do { _ = try await read.value; XCTFail("A completed late read must still be rejected after cancellation") } catch is CancellationError { }
        XCTAssertFalse(model.isDisconnecting); XCTAssertTrue(model.routes.isEmpty)
        XCTAssertEqual(model.metadata.recents, [recent]); XCTAssertEqual(model.metadata.connections, [profile])
        let disconnects = await base.disconnects, cancelledKeys = await keys.cancellations
        XCTAssertEqual(disconnects, 1); XCTAssertEqual(cancelledKeys, 1)
    }
    func testResetTrustForgetsOnlyTheSavedConnectionEndpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        let saved = ConnectionProfile(name: "Studio", host: "Studio.Example", port: 2222, username: "reader", identityID: UUID())
        let savedKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let editedKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        // An edited, unsaved host in the form must keep its trust.
        let edited = HostEndpoint(host: "other.example", port: 22)
        try await model.trust.trustUnknown(endpoint: HostEndpoint(host: "studio.example", port: 2222), key: HostKeyDetails(publicKey: savedKey))
        try await model.trust.trustUnknown(endpoint: edited, key: HostKeyDetails(publicKey: editedKey))
        await model.resetTrust(for: saved)
        do {
            try await model.trust.validate(endpoint: HostEndpoint(host: saved.host, port: saved.port), publicKey: savedKey)
            XCTFail("The saved endpoint must require fresh verification")
        } catch HostTrustError.unknown { }
        try await model.trust.validate(endpoint: edited, publicKey: editedKey)
        XCTAssertNil(model.errorMessage)
        let disconnects = await service.disconnects; XCTAssertEqual(disconnects, 1)
    }
    func testBreadcrumbsPopToAnExistingFolderAndPushOnlyNewOnes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        let id = UUID(), other = UUID()
        let report = RemoteEntry(name: "report.md", path: "/Projects/Reports/report.md", kind: .file)
        // The starting folder was requested as "." and canonicalized by its listing.
        model.cache(FolderListing(DirectorySnapshot(path: "/Projects", entries: [])), id: id, requestedPath: ".")
        let stack: [AppModel.Route] = [.folder(id, "."), .folder(other, "/Projects"), .folder(id, "/Projects/Reports"), .file(id, report)]
        model.routes = stack
        model.showFolder(id, path: "/Projects/Reports")
        XCTAssertEqual(model.routes, Array(stack.prefix(3)), "An ancestor already in the stack is popped to")
        model.showFolder(id, path: "/Projects")
        XCTAssertEqual(model.routes, [.folder(id, ".")], "A canonical match pops past another connection's route")
        model.showFolder(id, path: "/Projects")
        XCTAssertEqual(model.routes, [.folder(id, ".")], "Choosing the current folder is a no-op")
        model.showFolder(id, path: "/")
        XCTAssertEqual(model.routes, [.folder(id, "."), .folder(id, "/")], "A folder not in the stack is pushed")
    }
    func testLeavingDemoRestoresTheInjectedService() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        await model.setDemo(true)
        XCTAssertFalse(model.service as AnyObject === service, "Demo uses its own sample transport")
        let demoProfile = try XCTUnwrap(model.metadata.connections.first)
        let samples = try await model.service.listDirectory(profile: demoProfile, path: "/Projects")
        XCTAssertFalse(samples.entries.isEmpty)
        await model.setDemo(false)
        XCTAssertTrue(model.service as AnyObject === service, "Leaving Demo must restore the injected transport")
        XCTAssertTrue(model.metadata.connections.isEmpty)
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 1, "Entering Demo closes the injected transport; leaving closes only the sample one")
    }
    func testBackgroundPreservesNestedRoutesWhileExplicitDisconnectClearsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        let id = UUID(); model.routes = [.folder(id, "/"), .folder(id, "/nested")]
        await model.background(); XCTAssertEqual(model.routes.count, 2)
        await model.disconnectAndGoHome(); XCTAssertTrue(model.routes.isEmpty)
    }
    func testRecentSwipeModelPersistsOnlyEntryRemovalWithoutDisconnectOrCacheDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        let id = UUID(), recent = SavedLocation(connectionID: UUID(), path: "/report.md", name: "report.md")
        model.metadata.recents = [recent]; model.metadata.favourites = [recent]; await model.persist()
        model.cache(Data("cached report".utf8), id: id, path: recent.path)
        await model.removeRecent(recent); await model.removeRecent(recent)
        XCTAssertTrue(model.metadata.recents.isEmpty); XCTAssertEqual(model.metadata.favourites, [recent])
        XCTAssertNotNil(model.cachedDocument(id, path: recent.path))
        let disconnects = await service.disconnects; XCTAssertEqual(disconnects, 0)
        let relaunched = try AppModel(directory: directory, fileService: service); await relaunched.load()
        XCTAssertTrue(relaunched.metadata.recents.isEmpty); XCTAssertEqual(relaunched.metadata.favourites, [recent])
    }
    func testOfflineChangesReachOtherWindowsAndDemoObserversStaySeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService()
        await service.disconnect() // Complete subsequent downloads without blocking.
        let owner = try AppModel(directory: directory, fileService: service)
        var second: AppModel? = try AppModel(directory: directory, fileService: BackgroundExportService())
        await owner.load(); await second?.load()
        let profile = ConnectionProfile(name: "Shared copies", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/fixture")
        let entry = RemoteEntry(name: "copy.txt", path: "/fixture/copy.txt", kind: .file)
        let store = try XCTUnwrap(owner.offlineStore)
        let first = try await store.pin(profile: profile, entry: entry, allowedRoot: "/fixture", service: service)
        try await waitForOfflineState { owner.offlinePins == [first] && second?.offlinePin(profile: profile, path: entry.path) == first }
        let updated = try await store.pin(profile: profile, entry: entry, allowedRoot: "/fixture", service: service)
        try await waitForOfflineState { second?.offlinePins == [updated] }
        XCTAssertEqual(second?.offlinePins.first?.id, first.id)
        await owner.removeOfflinePin(updated)
        try await waitForOfflineState { second?.offlinePins.isEmpty == true }
        XCTAssertNil(second?.offlinePin(profile: profile, path: entry.path))
        await second?.setDemo(true)
        _ = try await store.pin(profile: profile, entry: entry, allowedRoot: "/fixture", service: service)
        try await waitForOfflineState { owner.offlinePins.count == 1 }
        XCTAssertTrue(second?.offlinePins.isEmpty == true, "An old observer must not publish real copies into Demo")
        await second?.setDemo(false)
        XCTAssertEqual(second?.offlinePins.count, 1)
        weak var released = second
        second = nil
        XCTAssertNil(released, "A store subscription must not retain its window model")
    }
    private func waitForOfflineState(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Offline state did not propagate within five seconds")
    }
    func testBackgroundPreservesOfflinePresentationButDismissesCredentialSheets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        await model.load(); model.sheet = .offlineFiles; model.isForeground = false
        await model.background()
        XCTAssertEqual(model.sheet?.id, "offlineFiles")
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 1, "Keeping the local reader must not keep the SSH session alive")
        model.sheet = .keys
        await model.background()
        XCTAssertNil(model.sheet, "Credential presentation remains transient")
    }

    func testLocalOfflineRejectionKeepsHealthyConnectionButTransportFailureDoesNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        await model.load()
        let profile = ConnectionProfile(name: "Healthy SSH", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/fixture")
        model.connectionStates[profile.id] = "Connected"
        model.pinOffline(profile: profile, entry: .init(name: "large.bin", path: "/fixture/large.bin", kind: .file,
            size: UInt64(OfflineFileStore.maximumFileBytes) + 1))
        try await waitForOfflineState { model.pinningName == nil }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.connectionStates[profile.id], "Connected", "A local size limit is not an SSH failure")
        let downloads = await service.downloads
        XCTAssertEqual(downloads, 0)
        await service.failDownloads(RemoteFileError.connectionEnded)
        model.errorMessage = nil
        model.pinOffline(profile: profile, entry: .init(name: "copy.txt", path: "/fixture/copy.txt", kind: .file))
        try await waitForOfflineState { model.pinningName == nil }
        XCTAssertEqual(model.connectionStates[profile.id], "Disconnected", "Transport failures still update connection state")
        let identity = IdentityMetadata(id: profile.identityID, name: "Locked", publicKey: "", fingerprint: "", requiresPassphrase: true, keychainReference: "fixture")
        await service.failDownloads(ConnectionIdentityUnlockRequired(identity: identity))
        model.pinOffline(profile: profile, entry: .init(name: "copy.txt", path: "/fixture/copy.txt", kind: .file))
        try await waitForOfflineState { model.pinningName == nil }
        XCTAssertEqual(model.sheet?.id, "unlock", "Security failures still present the unlock flow")
    }
    func testBusySaveAndBackgroundNeverWaitForAnotherWindowsDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), secondService = BackgroundExportService()
        let second = try AppModel(directory: directory, fileService: secondService)
        await second.load()
        let store = try XCTUnwrap(second.offlineStore)
        addTeardownBlock { await service.disconnect(); await store.cancelAndDrain() }
        let profile = ConnectionProfile(name: "Other window", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/fixture")
        let entry = RemoteEntry(name: "copy.txt", path: "/fixture/copy.txt", kind: .file)
        let owner = Task { try await store.pin(profile: profile, entry: entry, allowedRoot: "/fixture", service: service) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await service.waiting()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let waiting = await service.waiting()
        XCTAssertTrue(waiting)
        owner.cancel()
        do { _ = try await owner.value; XCTFail("Owner must return cancellation after installing its drain") }
        catch is CancellationError { }
        second.connectionStates[profile.id] = "Connected"
        second.pinOffline(profile: profile, entry: entry)
        try await waitForOfflineState { second.pinningName == nil }
        XCTAssertNotNil(second.errorMessage)
        XCTAssertEqual(second.connectionStates[profile.id], "Connected", "Busy is local, not a connection failure")
        var backgroundFinished = false
        let background = Task { await second.background(); backgroundFinished = true }
        try await waitForOfflineState { backgroundFinished }
        let ownerStillWaiting = await service.waiting()
        XCTAssertTrue(ownerStillWaiting, "Neither rejection nor another window's background may drain/cancel the owner")
        // Always unblock the fixture, including on a failed assertion, so a regression cannot hang tests.
        await service.disconnect(); await background.value
    }

    func testBusyOfflineSaveInAnotherWindowDoesNotCancelTheOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService()
        let owner = try AppModel(directory: directory, fileService: service)
        let second = try AppModel(directory: directory, fileService: BackgroundExportService())
        await owner.load(); await second.load()
        XCTAssertTrue(owner.offlineStore === second.offlineStore)
        let profile = ConnectionProfile(name: "Shared offline", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/fixture")
        let file = RemoteEntry(name: "original.txt", path: "/fixture/original.txt", kind: .file)
        owner.pinOffline(profile: profile, entry: file)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await service.waiting()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        second.pinOffline(profile: profile, entry: file)
        let settled = ContinuousClock.now + .seconds(5)
        while second.pinningName != nil, ContinuousClock.now < settled { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(second.errorMessage)
        let waiting = await service.waiting()
        XCTAssertTrue(waiting, "A busy caller must not cancel another window’s transfer")
        XCTAssertNotNil(owner.pinningName)
        owner.isForeground = false; await owner.background()
        XCTAssertNil(owner.pinningName); XCTAssertTrue(owner.offlinePins.isEmpty)
    }

    func testOfflineShareItemRetainsTheFileWhenReaderAndPinAreRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        await service.disconnect(); await model.load()
        let profile = ConnectionProfile(name: "Offline share", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/fixture")
        model.pinOffline(profile: profile, entry: .init(name: "copy.txt", path: "/fixture/copy.txt", kind: .file))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.pinningName != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let store = try XCTUnwrap(model.offlineStore), pin = try XCTUnwrap(model.offlinePins.first)
        var lease: OfflineFileLease? = try await store.lease(pin.id)
        let url = try XCTUnwrap(lease?.url)
        var share: OfflineShareItem? = OfflineShareItem(lease: try XCTUnwrap(lease))
        lease = nil
        await model.removeOfflinePin(pin)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(share?.lease.url)), Data("changed server bytes\r\n東京  ".utf8))
        share = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOfflineSaveCancelsOnBackgroundAndLeavesNoLateCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        await model.load()
        let profile = ConnectionProfile(name: "Offline lifecycle", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/fixture")
        let entry = RemoteEntry(name: "original.txt", path: "/fixture/original.txt", kind: .file)
        model.pinOffline(profile: profile, entry: entry)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await service.waiting()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let waiting = await service.waiting()
        XCTAssertTrue(waiting)
        let partial = await service.destination
        model.isForeground = false
        await model.background()
        XCTAssertNil(model.pinningName)
        XCTAssertTrue(model.offlinePins.isEmpty)
        XCTAssertNil(model.errorMessage, "An abandoned save must not show a late failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(partial).path))
        model.isForeground = true
        model.pinOffline(profile: profile, entry: entry)
        let resumed = ContinuousClock.now + .seconds(5)
        while model.pinningName != nil, ContinuousClock.now < resumed { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.offlinePins.count, 1)
        let store = try XCTUnwrap(model.offlineStore), pin = try XCTUnwrap(model.offlinePins.first)
        let lease = try await store.lease(pin.id)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("changed server bytes\r\n東京  ".utf8))
    }

    func testOfflineCopySurvivesConnectionDeletionAndRejectsChangedRefreshRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        await service.disconnect() // This mock's subsequent downloads complete without suspension.
        await model.load()
        var profile = ConnectionProfile(name: "Offline route", host: "fixture.invalid", username: "reader", identityID: UUID(), startingDirectory: "/fixture")
        model.metadata.connections = [profile]; await model.persist()
        model.pinOffline(profile: profile, entry: .init(name: "copy.txt", path: "/fixture/copy.txt", kind: .file))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.pinningName != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pin = try XCTUnwrap(model.offlinePins.first)
        profile.host = "another.invalid"; model.metadata.connections = [profile]
        model.refreshOfflinePin(pin)
        XCTAssertNotNil(model.errorMessage); XCTAssertNil(model.pinningName)
        await model.removeConnection(profile)
        let reopened = try AppModel(directory: directory, fileService: service); await reopened.load()
        XCTAssertTrue(reopened.metadata.connections.isEmpty)
        XCTAssertEqual(reopened.offlinePins.count, 1)
        let store = try XCTUnwrap(reopened.offlineStore), lease = try await store.lease(pin.id)
        XCTAssertEqual(try Data(contentsOf: lease.url), Data("changed server bytes\r\n東京  ".utf8))
        let downloads = await service.downloads
        XCTAssertEqual(downloads, 1, "Refresh on a changed route and local reading must not download")
    }

    func testProductionBackgroundCancelsAndDrainsExportClearsCacheAndNewExporterReadsChangedBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService()
        let model = try AppModel(directory: directory, fileService: service)
        let profile = ConnectionProfile(name: "Lifecycle", host: "fixture.invalid", username: "fixture",
                                        identityID: UUID(), startingDirectory: "/fixture")
        let entry = RemoteEntry(name: "original.txt", path: "/fixture/original.txt", kind: .file)
        model.cache(Data("stale preview".utf8), id: profile.id, path: entry.path)
        let oldExporter = model.originalExporter
        let pending = Task { try await oldExporter.prepare(profile: profile, entry: entry, allowedRoot: "/fixture") }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await service.waiting()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await service.waiting()
        guard waiting else { pending.cancel(); await service.disconnect(); XCTFail("Export never reached transport"); return }
        let destination = await service.destination
        let partial = try XCTUnwrap(destination)
        model.isForeground = false
        await model.background()
        do { _ = try await pending.value; XCTFail("Background export must be cancelled") }
        catch is CancellationError { }
        XCTAssertNil(model.cachedDocument(profile.id, path: entry.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "Partial export must be removed")
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 1)
        model.isForeground = true; model.sessionRevision += 1
        let newExporter = model.originalExporter
        XCTAssertFalse(oldExporter === newExporter, "Reconnect must use an exporter after the old transfer drained")
        let fresh = try await newExporter.prepare(profile: profile, entry: entry, allowedRoot: "/fixture")
        XCTAssertEqual(try Data(contentsOf: fresh.url), Data("changed server bytes\r\n東京  ".utf8))
        await newExporter.release(fresh.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.url.path))
    }
}

private final class JumpLifecycleSecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func save(_ data: Data, reference: String) throws { lock.lock(); defer { lock.unlock() }; values[reference] = data }
    func load(reference: String) throws -> Data { lock.lock(); defer { lock.unlock() }; guard let data = values[reference] else { throw IdentityError.missingSecret }; return data }
    func delete(reference: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference) }
}
#endif
