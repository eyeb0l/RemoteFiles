#if os(iOS)
import XCTest
import Foundation
import UIKit
import UniformTypeIdentifiers
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
        // Fixture paths: names with an extension are files, the rest are folders.
        .init(name: RemotePath.name(of: path), path: path, kind: RemotePath.name(of: path).contains(".") ? .file : .directory)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { bytes }
    /// Chosen files use the exact canonical contract; like the real transports, confine the
    /// path to its root, then transfer exactly as an ordinary download.
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        guard RemoteResourcePath.contains(path, in: canonicalRoot) else { throw RemoteDocumentLinkError.outsideConnection }
        return try await downloadFile(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination, limit: limit)
    }
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

private actor MediaConnectionService: RemoteFileService {
    private var failure: Error?
    private var held: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private(set) var checks = 0
    private(set) var downloads = 0
    func fail(_ error: Error?) { failure = error }
    func holdNextCheck() { holdNext = true }
    func isWaiting() -> Bool { held != nil }
    func release() { held?.resume(); held = nil }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        checks += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
        }
        if let failure { throw failure }
        return .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        downloads += 1
        try Data("cached media".utf8).write(to: destination)
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: 12)
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func disconnect() async { }
}

/// One window's transport. A download whose path is held waits until it is released or its task is
/// cancelled, as a managed transfer drains when its worker is. `disconnect` only counts: in these tests one
/// service is both a window's browsing and its download transport, and closing browsing must not look like
/// stopping a download.
private actor WindowDownloadService: RemoteFileService {
    private var held: Set<String> = []
    private var failures: [String: Error] = [:]
    private(set) var waiting: [String] = []
    private(set) var cancelled: [String] = []
    private(set) var finished: [String] = []
    func hold(_ path: String) { held.insert(path) }
    func release(_ path: String) { held.remove(path) }
    func fail(_ path: String, with error: Error) { failures[path] = error }
    /// Chosen files use the exact canonical contract, as in `BackgroundExportService`.
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        guard RemoteResourcePath.contains(path, in: canonicalRoot) else { throw RemoteDocumentLinkError.outsideConnection }
        return try await downloadFile(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination, limit: limit)
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        if let failure = failures[path] { throw failure }
        if held.contains(path) {
            waiting.append(path)
            defer { waiting.removeAll { $0 == path } }
            do { while held.contains(path) { try await Task.sleep(for: .milliseconds(10)) } }
            catch { cancelled.append(path); throw CancellationError() }
        }
        try Data("bytes".utf8).write(to: destination)
        finished.append(path)
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: 5)
    }
    func disconnect() {}
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: []) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
}

/// Downloads that need a key, as the SFTP transport does: an encrypted key that isn't unlocked asks for its
/// passphrase. `disconnect()` locks every key, as `SFTPRemoteFileService.disconnect()` does; closing the
/// session while keeping unlocked identities does not. One path can be held to keep the queue busy.
private actor KeyedDownloadService: RemoteFileService, RemoteFileSessionClosing {
    private let identities: IdentityStore
    private var keys: [UUID: IdentityMetadata] = [:]
    private var held: Set<String> = []
    private(set) var finished: [String] = []
    init(identities: IdentityStore) { self.identities = identities }
    func know(_ keys: [IdentityMetadata]) { self.keys = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) }) }
    func hold(_ path: String) { held.insert(path) }
    func release(_ path: String) { held.remove(path) }
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        guard RemoteResourcePath.contains(path, in: canonicalRoot) else { throw RemoteDocumentLinkError.outsideConnection }
        return try await downloadFile(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination, limit: limit)
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        while held.contains(path) { try await Task.sleep(for: .milliseconds(10)) }
        if let key = keys[profile.identityID] {
            do { _ = try await identities.unlock(key) }
            catch IdentityError.missingPassphrase { throw ConnectionIdentityUnlockRequired(identity: key) }
        }
        try Data("bytes".utf8).write(to: destination)
        finished.append(path)
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: 5)
    }
    func disconnect() async { await identities.clearSession() }
    func closeSessionPreservingUnlockedIdentities() {}
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: []) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
}

@MainActor final class AppModelLifecycleTests: XCTestCase {
    func testCachedMediaAfterFailedConnectionCheckStaysDisconnectedAndRecoversWithoutDownloading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MediaConnectionService()
        let model = try AppModel(directory: directory, fileService: service)
        let profile = ConnectionProfile(name: "Media", host: "media.invalid", username: "reader", identityID: UUID())
        let location = RemoteDocumentLocation(profile: profile, path: "/media/a.mp4")
        let first = try await model.loadMediaResource(for: "a.mp4", in: location)
        defer { try? FileManager.default.removeItem(at: first.file) }
        XCTAssertEqual(model.connectionStates[profile.id], "Connected")
        await service.fail(RemoteFileError.timedOut)
        model.handle(RemoteFileError.timedOut, profile: profile)
        let cached = try await model.loadMediaResource(for: "a.mp4", in: location)
        XCTAssertEqual(cached.file, first.file)
        XCTAssertNotNil(cached.connectionFailure)
        XCTAssertEqual(model.connectionStates[profile.id], "Disconnected", "Cached bytes cannot verify SSH")
        await service.fail(nil)
        _ = try await model.loadMediaResource(for: "a.mp4", in: location)
        XCTAssertEqual(model.connectionStates[profile.id], "Connected")
        let downloads = await service.downloads
        XCTAssertEqual(downloads, 1)
    }

    func testFailedSecurityCheckBlocksCachedMediaUntilLiveVerification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MediaConnectionService()
        let model = try AppModel(directory: directory, fileService: service)
        let profile = ConnectionProfile(name: "Media", host: "media.invalid", username: "reader", identityID: UUID())
        let location = RemoteDocumentLocation(profile: profile, path: "/media/a.mp4")
        let first = try await model.loadMediaResource(for: "a.mp4", in: location)
        defer { try? FileManager.default.removeItem(at: first.file) }
        for securityError in [HostTrustError.invalidStore as Error, IdentityError.missingSecret,
                              RemoteFileError.authenticationFailed] {
            model.handle(securityError, profile: profile)
            XCTAssertNotNil(model.mediaSecurityFailure(profile.id))
            await service.fail(RemoteFileError.timedOut)
            do {
                _ = try await model.loadMediaResource(for: "a.mp4", in: location)
                XCTFail("A later network failure must not erase the failed security check")
            } catch RemoteFileError.timedOut { }
            XCTAssertNotNil(model.mediaSecurityFailure(profile.id))
            XCTAssertEqual(model.connectionStates[profile.id], "Disconnected")
            await service.fail(nil)
            let recovered = try await model.loadMediaResource(for: "a.mp4", in: location)
            XCTAssertEqual(recovered.file, first.file)
            XCTAssertNil(model.mediaSecurityFailure(profile.id))
            XCTAssertEqual(model.connectionStates[profile.id], "Connected")
        }
    }

    func testMediaCheckOvertakenByAFailureCannotVerifyOrPublishCachedBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MediaConnectionService()
        let model = try AppModel(directory: directory, fileService: service)
        let profile = ConnectionProfile(name: "Media", host: "media.invalid", username: "reader", identityID: UUID())
        let location = RemoteDocumentLocation(profile: profile, path: "/media/a.mp4")
        let first = try await model.loadMediaResource(for: "a.mp4", in: location)
        defer { try? FileManager.default.removeItem(at: first.file) }
        for error in [RemoteFileError.timedOut as Error, HostTrustError.invalidStore, RemoteFileError.authenticationFailed] {
            await service.holdNextCheck()
            let task = Task { try await model.loadMediaResource(for: "a.mp4", in: location) }
            let deadline = ContinuousClock.now + .seconds(30)
            while !(await service.isWaiting()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let waiting = await service.isWaiting()
            XCTAssertTrue(waiting)
            model.handle(error, profile: profile)
            await service.release()
            do { _ = try await task.value; XCTFail("An overtaken check must not publish") } catch is CancellationError { }
            XCTAssertEqual(model.connectionStates[profile.id], "Disconnected")
            _ = try await model.loadMediaResource(for: "a.mp4", in: location)
        }
    }

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

    private func file(_ name: String) -> RemoteEntry { .init(name: name, path: "/" + name, kind: .file) }
    /// Waits for what must happen, with room for a loaded CI runner.
    private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let met = await condition()
        XCTAssertTrue(met, what)
    }
    /// Checks for a while that what must not happen doesn't.
    private func holds(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(500)
        while ContinuousClock.now < deadline {
            guard await condition() else { return XCTFail(what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func twoWindows(_ directory: URL) async throws -> (AppModel, WindowDownloadService, AppModel, WindowDownloadService) {
        let firstService = WindowDownloadService(), secondService = WindowDownloadService()
        let first = try AppModel(directory: directory, fileService: firstService)
        let second = try AppModel(directory: directory, fileService: secondService)
        await first.load(); await second.load()
        return (first, firstService, second, secondService)
    }

    func testEnteringDemoInOneWindowKeepsAnotherWindowsDownloadRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, _, second, secondService) = try await twoWindows(directory)
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID())
        await secondService.hold("/file.bin")
        second.enqueueDownload(profile: profile, entry: file("file.bin"))
        let manager = try XCTUnwrap(second.downloads)
        try await waitUntil("The download started") { await secondService.waiting == ["/file.bin"] }
        await first.setDemo(true)
        XCTAssertFalse(first.downloads === manager, "Demo keeps its own downloads")
        try await holds("Another window entering Demo stopped this window's download") {
            manager.items.first?.state == .downloading
        }
        var cancelled = await secondService.cancelled
        XCTAssertEqual(cancelled, [])
        await first.setDemo(false)
        XCTAssertTrue(first.downloads === manager)
        XCTAssertEqual(manager.items.first?.state, .downloading)
        // The last window left on the queue entering Demo stops it, as closing that window would.
        await first.setDemo(true)
        await second.setDemo(true)
        try await waitUntil("The last window entering Demo stopped its download") { manager.items.first?.state == .interrupted }
        // The queue marks the item before the transfer's own task has seen its cancellation.
        try await waitUntil("The transfer was cancelled") { await secondService.cancelled == ["/file.bin"] }
    }

    /// Editing, removing or forgetting the host key of a connection in one window stops that connection's
    /// downloads in every window, and nothing else.
    func testChangingOneConnectionStopsOnlyItsDownloadsInEveryWindow() async throws {
        enum Change: CaseIterable { case edit, remove, resetTrust, resetJumpHostTrust }
        for change in Change.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (first, _, second, secondService) = try await twoWindows(directory)
            func profile(_ name: String) -> ConnectionProfile {
                ConnectionProfile(name: name, host: name + ".invalid", username: "reader", identityID: UUID(),
                                  jumpHost: JumpHost(host: "jump-" + name + ".invalid", username: "reader", identityID: UUID()))
            }
            let x = profile("x"), y = profile("y"), z = profile("z")
            first.metadata.connections = [x, y, z]
            await first.persist()
            try await waitUntil("The other window took in the library") { second.metadata.connections.count == 3 }
            func apply(to target: ConnectionProfile) async {
                switch change {
                case .edit: var edited = target; edited.username = "changed"; await first.saveConnection(edited)
                case .remove: await first.removeConnection(target)
                case .resetTrust: await first.resetTrust(for: target)
                case .resetJumpHostTrust: await first.resetJumpHostTrust(for: target)
                }
                if change == .edit || change == .remove {
                    try? await waitUntil("The other window took in the change") {
                        !second.metadata.connections.contains(target)
                    }
                }
            }
            await secondService.hold("/x.bin")
            second.enqueueDownload(profile: x, entry: file("x.bin"))
            second.enqueueDownload(profile: y, entry: file("y.bin"))
            second.enqueueDownload(profile: z, entry: file("z.bin"))
            let manager = try XCTUnwrap(second.downloads)
            try await waitUntil("\(change): the download started") { await secondService.waiting == ["/x.bin"] }

            await apply(to: y)
            XCTAssertEqual(manager.items.map(\.state), [.downloading, .interrupted, .queued], "\(change)")
            try await holds("\(change) of another connection stopped this one's download") {
                manager.items.map(\.state) == [.downloading, .interrupted, .queued]
            }
            var cancelled = await secondService.cancelled
            XCTAssertEqual(cancelled, [], "\(change)")

            await apply(to: x)
            XCTAssertEqual(manager.items.first?.state, .interrupted, "\(change)")
            cancelled = await secondService.cancelled
            XCTAssertEqual(cancelled, ["/x.bin"], "\(change)")
            try await waitUntil("\(change): the queue went on") { manager.items.last?.state == .completed }
            XCTAssertEqual(manager.items.map(\.state), [.interrupted, .interrupted, .completed], "\(change)")
        }
    }

    /// A window that hears another changed a connection stops its own downloads of the connection as it was,
    /// as the window that changed it did. Here the window started its download before hearing of the change.
    func testDownloadOfAConnectionChangedInAnotherWindowStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = WindowDownloadService(), model = try AppModel(directory: directory, fileService: service)
        await model.load()
        let x = ConnectionProfile(name: "X", host: "x.invalid", username: "reader", identityID: UUID())
        let y = ConnectionProfile(name: "Y", host: "y.invalid", username: "reader", identityID: UUID())
        model.metadata.connections = [x, y]
        await model.persist()
        await service.hold("/x.bin")
        model.enqueueDownload(profile: x, entry: file("x.bin"))
        model.enqueueDownload(profile: y, entry: file("y.bin"))
        let manager = try XCTUnwrap(model.downloads)
        try await waitUntil("The download started") { await service.waiting == ["/x.bin"] }
        var moved = x; moved.host = "moved.invalid"
        _ = try await model.metadataStore.update(origin: UUID()) { $0.connections = [moved, y] }
        try await waitUntil("The window took in the change") { model.metadata.connections == [moved, y] }
        try await waitUntil("The download of the connection as it was stopped") { manager.items.first?.state == .interrupted }
        let cancelled = await service.cancelled
        XCTAssertEqual(cancelled, ["/x.bin"])
        try await waitUntil("The other connection's download went on") { manager.items.last?.state == .completed }
    }

    /// Downloads a window queued keep their place when it enters Demo, as when it goes to the background. One
    /// that then needs a trust or unlock prompt fails with its message in Downloads, rather than raising a
    /// prompt for a real server over Demo.
    func testWindowInDemoDoesNotRaisePromptsForDownloadsItQueuedBefore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, firstService, second, _) = try await twoWindows(directory)
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "reader", identityID: UUID())
        first.metadata.connections = [profile]
        let key = try HostKeyDetails(publicKey: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey)
        await firstService.hold("/held.bin")
        await firstService.fail("/trust.bin", with: HostTrustError.unknown(endpoint: .init(host: "fixture.invalid"), key: key))
        first.enqueueDownload(profile: profile, entry: file("held.bin"))
        first.enqueueDownload(profile: profile, entry: file("trust.bin"))
        first.sheet = nil
        let manager = try XCTUnwrap(first.downloads)
        try await waitUntil("The download started") { await firstService.waiting == ["/held.bin"] }
        await first.setDemo(true)
        await firstService.release("/held.bin")
        try await waitUntil("The queue went on in the other window") { manager.items.last?.state == .failed }
        XCTAssertEqual(manager.items.first?.state, .completed)
        XCTAssertNil(first.sheet); XCTAssertNil(second.sheet)
        // Back in the real library, a download it starts raises its prompt as before.
        await first.setDemo(false)
        first.retryDownload(try XCTUnwrap(manager.items.last))
        try await waitUntil("The retried download failed") { manager.activeID == nil && manager.items.last?.state == .failed }
        XCTAssertEqual(first.sheet?.id, "trust")
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

    func testRepeatedDemoRequestsWhileSwitchingKeepTheRealLibraryToRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        await model.load()
        let profile = ConnectionProfile(name: "Real", host: "real.invalid", username: "me", identityID: UUID())
        model.metadata.connections = [profile]
        // Settings' Explore Demo stays on screen while the first request disconnects, so it can be chosen twice.
        async let first: Void = model.setDemo(true)
        async let second: Void = model.setDemo(true)
        _ = await (first, second)
        XCTAssertTrue(model.demo)
        XCTAssertNotEqual(model.metadata.connections, [profile])
        await model.setDemo(false)
        XCTAssertFalse(model.demo)
        XCTAssertEqual(model.metadata.connections, [profile], "Leaving Demo restores the library it replaced")
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
        let hop = HostEndpoint(host: "jump.invalid", port: 2222), target = HostEndpoint.destination(of: profile)
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
        model.sheet = .settings; model.errorMessage = "old failure"; model.cache(Data("stale".utf8), id: profile.id, path: entry.path)
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
    /// A build from before servers behind jump hosts had their own trusted keys saved such a
    /// server's key under its bare address. At launch the connection that reaches it through a jump
    /// host takes that record over, so opening it does not ask to verify the key again.
    func testLoadingGivesAnEarlierTrustRecordToTheConnectionBehindAJumpHost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let details = try HostKeyDetails(publicKey: key)
        struct EarlierEndpoint: Encodable { let host: String; let port: Int }
        struct EarlierRecord: Encodable { let endpoint: EarlierEndpoint; let key: HostKeyDetails }
        struct EarlierDocument: Encodable { let version = 1; let records: [EarlierRecord] }
        let earlier = EarlierDocument(records: [.init(endpoint: .init(host: "10.0.0.5", port: 22), key: details),
                                                .init(endpoint: .init(host: "hop.example", port: 22), key: details)])
        try JSONEncoder().encode(earlier).write(to: directory.appendingPathComponent("known-hosts-v1.json"))

        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        let profile = ConnectionProfile(name: "Behind the hop", host: "10.0.0.5", username: "reader", identityID: UUID(),
                                        jumpHost: JumpHost(host: "hop.example", username: "jump", identityID: UUID()))
        model.metadata.connections = [profile]
        await model.persist()
        await model.load()

        try await model.trust.validate(endpoint: .destination(of: profile), publicKey: key)
        try await model.trust.validate(endpoint: HostEndpoint(host: "hop.example", port: 22), publicKey: key)
        do { try await model.trust.validate(endpoint: HostEndpoint(host: "10.0.0.5", port: 22), publicKey: key); XCTFail("Nothing reaches that address directly") }
        catch HostTrustError.unknown { }
    }

    /// A trusted key can only be reset from a connection that uses it, so the last such
    /// connection takes it with it. One still in use by another connection stays.
    func testDeletingAConnectionForgetsAHostKeyNothingElseUses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let shared = HostEndpoint(host: "shared.example", port: 22), lone = HostEndpoint(host: "lone.example", port: 2222)
        let hop = HostEndpoint(host: "hop.example", port: 22)
        let first = ConnectionProfile(name: "First", host: "Shared.Example", username: "reader", identityID: UUID())
        let alsoDirect = ConnectionProfile(name: "Also direct", host: "shared.example", username: "other", identityID: UUID())
        let second = ConnectionProfile(name: "Second", host: "shared.example", username: "other", identityID: UUID(),
                                       jumpHost: JumpHost(host: "hop.example", username: "jump", identityID: UUID()))
        let third = ConnectionProfile(name: "Third", host: "lone.example", port: 2222, username: "reader", identityID: UUID())
        // The same address behind the jump host is a server of its own, with its own key.
        let behindHop = HostEndpoint.destination(of: second)
        model.metadata.connections = [first, alsoDirect, second, third]
        await model.persist()
        for endpoint in [shared, behindHop, lone, hop] { try await model.trust.trustUnknown(endpoint: endpoint, key: HostKeyDetails(publicKey: key)) }
        func isTrusted(_ endpoint: HostEndpoint) async -> Bool { (try? await model.trust.validate(endpoint: endpoint, publicKey: key)) != nil }

        await model.removeConnection(third)
        var trusted = [await isTrusted(lone), await isTrusted(shared), await isTrusted(behindHop), await isTrusted(hop)]
        XCTAssertEqual(trusted, [false, true, true, true], "Only the key nothing else uses goes")
        await model.removeConnection(first)
        trusted = [await isTrusted(shared), await isTrusted(behindHop), await isTrusted(hop)]
        XCTAssertEqual(trusted, [true, true, true], "Another connection still reaches that server directly")
        await model.removeConnection(alsoDirect)
        trusted = [await isTrusted(shared), await isTrusted(behindHop), await isTrusted(hop)]
        XCTAssertEqual(trusted, [false, true, true], "A connection through a jump host does not keep the directly reached server's key")
        await model.removeConnection(second)
        trusted = [await isTrusted(behindHop), await isTrusted(hop)]
        XCTAssertEqual(trusted, [false, false], "The last connection takes its server's and its jump host's keys")
        XCTAssertNil(model.errorMessage)
    }

    /// The "Host Key Changed" sheet and a connection's settings reset trust the same way: what was
    /// previewed through the old key goes too, and the connection is dropped.
    func testEveryTrustResetForgetsPreviewedFilesAndDisconnects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BackgroundExportService(), model = try AppModel(directory: directory, fileService: service)
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let endpoint = HostEndpoint(host: "studio.example", port: 22)
        try await model.trust.trustUnknown(endpoint: endpoint, key: HostKeyDetails(publicKey: key))
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteImages-v1")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let previewed = cache.appendingPathComponent(UUID().uuidString + ".resource")
        try Data("from the server trusted before".utf8).write(to: previewed)

        let forgotten = await model.resetTrust(endpoint: endpoint)
        XCTAssertTrue(forgotten)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewed.path), "A file previewed through the old key is not kept for the next one")
        do { try await model.trust.validate(endpoint: endpoint, publicKey: key); XCTFail("The key must be verified again") } catch HostTrustError.unknown { }
        let disconnects = await service.disconnects; XCTAssertEqual(disconnects, 1)
    }

    func testDeletingAConnectionRemovesItsDownloadsOnlyWhenAsked() async throws {
        for removing in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (model, service, _, _) = try await twoWindows(directory)
            let kept = ConnectionProfile(name: "Kept", host: "kept.invalid", username: "reader", identityID: UUID())
            let deleted = ConnectionProfile(name: "Deleted", host: "deleted.invalid", username: "reader", identityID: UUID())
            model.metadata.connections = [kept, deleted]
            await model.persist()
            await service.hold("/held.bin")
            model.enqueueDownload(profile: kept, entry: file("held.bin"))
            model.enqueueDownload(profile: deleted, entry: file("one.bin"))
            model.enqueueDownload(profile: deleted, entry: file("two.bin"))
            XCTAssertEqual(model.downloads(from: deleted).count, 2)
            await model.removeConnection(deleted, removingDownloads: removing)
            XCTAssertEqual(model.downloads(from: deleted).count, removing ? 0 : 2, removing ? "Removed on request" : "Kept unless asked")
            XCTAssertEqual(model.downloads(from: kept).count, 1, "Another connection's downloads are never touched")
            await service.release("/held.bin")
        }
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
    func testTheDocumentCacheNeverKeepsTheBytesOfAHiddenKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        let id = UUID(), key = Data(SyntheticKey.pem().utf8), mixed = Data(("first\n" + SyntheticKey.pem() + "needle\n").utf8)
        let plain = Data("plain report".utf8)
        model.cache(plain, decodedAs: DocumentPolicy.decode(plain, filename: "report.txt"), id: id, path: "/report.txt")
        XCTAssertEqual(model.cachedDocument(id, path: "/report.txt"), plain)
        for (bytes, name) in [(key, "id_rsa"), (mixed, "notes.txt")] {
            let path = "/" + name
            model.cache(plain, id: id, path: path)
            let decoded = DocumentPolicy.decode(bytes, filename: name)
            model.cache(bytes, decodedAs: decoded, id: id, path: path)
            XCTAssertNil(model.cachedDocument(id, path: path), "\(name) was cached, and an older copy doesn't linger")
        }
        XCTAssertEqual(model.cachedDocument(id, path: "/report.txt"), plain, "Other documents stay")
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
        // The two models share a store while both live, so what reached the file is read separately.
        let onDisk = await (try MetadataStore(fileURL: directory.appendingPathComponent("library-v1.json"))).snapshot()
        XCTAssertTrue(onDisk.recents.isEmpty); XCTAssertEqual(onDisk.favourites, [recent])
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
    func testAutomaticIndexUpdateRunsOnlyWhenEnabledAndDueAndStopsWithTheSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        await model.load(); await model.setDemo(true)
        let demo = try XCTUnwrap(model.searchService as? DemoRemoteFileService)
        await demo.configure(delayNanoseconds: 0, failure: nil)
        let profile = try XCTUnwrap(model.metadata.connections.first), root = "/Projects/Reports"
        let store = await model.searchIndexStore(), updates = model.indexUpdates
        let built = try await RemoteFolderSearch.buildIndex(below: root, profile: profile, service: demo, includeHidden: false)
        let old = SearchIndexSnapshot(createdAt: Date().addingTimeInterval(-3_600), documents: built.documents,
                                      includeHidden: built.includeHidden, extraction: built.extraction, isPartial: built.isPartial)
        try await store.save(old, profile: profile, root: root)
        func waitUntilIdle() async throws {
            // Outlast the update's own 30-second scheduling budget on loaded hosted runners.
            let deadline = ContinuousClock.now + .seconds(60)
            while updates.isUpdating(profile, root: root), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(updates.isUpdating(profile, root: root), "The automatic update did not finish")
        }

        let whileOff = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertFalse(whileOff, "An index updates automatically only when asked to")
        try await store.setUpdatesAutomatically(true, profile: profile, root: root)
        let otherFolder = await updates.updateIfDue(profile, root: "/Projects", model: model)
        XCTAssertFalse(otherFolder, "Only the indexed folder itself starts an update")

        // An index younger than the interval is left alone.
        let fresh = await updates.updateIfDue(profile, root: root, model: model, now: old.createdAt.addingTimeInterval(60))
        XCTAssertFalse(fresh)

        // Leaving the app ends the update without saving, and it starts again on return.
        await demo.configure(delayNanoseconds: 200_000_000, failure: nil)
        let started = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertTrue(started)
        let duplicate = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertFalse(duplicate, "One index has at most one automatic update")
        model.isForeground = false; await model.background()
        XCTAssertFalse(updates.isUpdating(profile, root: root))
        let background = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertFalse(background, "Nothing updates in the background")
        let afterBackground = try await store.load(profile: profile, root: root)
        XCTAssertEqual(afterBackground?.createdAt, old.createdAt)
        XCTAssertEqual(updates.savedRevision, 0); XCTAssertNil(updates.outcome(profile, root: root))
        model.isForeground = true
        await demo.configure(delayNanoseconds: 0, failure: nil)

        let resumed = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertTrue(resumed, "A cancelled update does not wait out the interval")
        try await waitUntilIdle()
        XCTAssertEqual(updates.savedRevision, 1)
        let outcome = try XCTUnwrap(updates.outcome(profile, root: root))
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(outcome.message, "Updated automatically. Read 3 new or changed files and kept 2 unchanged.")
        let loaded = try await store.load(profile: profile, root: root)
        let updated = try XCTUnwrap(loaded)
        XCTAssertGreaterThan(updated.createdAt, old.createdAt)
        XCTAssertEqual(updated.documents.count, old.documents.count)
        let stillOn = try await store.updatesAutomatically(profile: profile, root: root)
        XCTAssertTrue(stillOn)
        let justUpdated = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertFalse(justUpdated, "The new snapshot is not due yet")

        // A failure is reported, keeps the saved index, and waits a full interval before retrying.
        updates.interval = 0
        await demo.configure(delayNanoseconds: 0, failure: "Server unavailable")
        let failing = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertTrue(failing)
        try await waitUntilIdle()
        XCTAssertEqual(updates.outcome(profile, root: root)?.failed, true)
        XCTAssertEqual(updates.savedRevision, 1)
        let kept = try await store.load(profile: profile, root: root)
        XCTAssertEqual(kept?.createdAt, updated.createdAt)
        updates.interval = 3_600
        let retry = await updates.updateIfDue(profile, root: root, model: model, now: Date().addingTimeInterval(2_000))
        XCTAssertFalse(retry, "A failed update waits a full interval")
        let later = await updates.updateIfDue(profile, root: root, model: model, now: Date().addingTimeInterval(3_700))
        XCTAssertTrue(later)
        try await waitUntilIdle()

        // A manual build replaces a running automatic update.
        await demo.configure(delayNanoseconds: 200_000_000, failure: nil)
        updates.interval = 0
        let replaced = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertTrue(replaced)
        updates.cancel(profile, root: root)
        XCTAssertFalse(updates.isUpdating(profile, root: root))
        XCTAssertEqual(updates.savedRevision, 1)

        // Cancelling while the check is still reading the store stops it from starting afterwards.
        let suspended = Task { await updates.updateIfDue(profile, root: root, model: model) }
        await Task.yield()
        updates.cancel(profile, root: root)
        let startedAfterCancel = await suspended.value
        XCTAssertFalse(startedAfterCancel, "A manual build or deletion must not be superseded by a check it outran")
        XCTAssertFalse(updates.isUpdating(profile, root: root))

        // Turning the setting off stops future updates.
        try await store.setUpdatesAutomatically(false, profile: profile, root: root)
        let turnedOff = await updates.updateIfDue(profile, root: root, model: model)
        XCTAssertFalse(turnedOff)
    }

    func testIndexDeletedInAnotherWindowBeforeAnAutomaticUpdateReservesItStaysDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let updating = try AppModel(directory: directory, fileService: BackgroundExportService())
        let deleting = try AppModel(directory: directory, fileService: BackgroundExportService())
        await updating.load(); await updating.setDemo(true)
        await deleting.load(); await deleting.setDemo(true)
        let demo = try XCTUnwrap(updating.searchService as? DemoRemoteFileService)
        await demo.configure(delayNanoseconds: 0, failure: nil)
        let profile = try XCTUnwrap(updating.metadata.connections.first), root = "/Projects/Reports"
        let store = await updating.searchIndexStore()
        let built = try await RemoteFolderSearch.buildIndex(below: root, profile: profile, service: demo, includeHidden: false)
        try await store.save(.init(createdAt: Date().addingTimeInterval(-3_600), documents: built.documents, includeHidden: false,
                                   extraction: built.extraction, isPartial: built.isPartial), profile: profile, root: root)
        try await store.setUpdatesAutomatically(true, profile: profile, root: root)
        let otherWindowStore = await deleting.searchIndexStore()
        let started = await updating.indexUpdates.updateIfDue(profile, root: root, model: updating)
        XCTAssertTrue(started)
        // The other window deletes the index before the update task has run and reserved its build.
        try await otherWindowStore.remove(profile: profile, root: root)
        let deadline = ContinuousClock.now + .seconds(60)
        while updating.indexUpdates.isUpdating(profile, root: root), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let resurrected = try await store.load(profile: profile, root: root)
        XCTAssertNil(resurrected, "An automatic update must not save an index another window deleted")
        XCTAssertEqual(updating.indexUpdates.savedRevision, 0)
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
        model.sheet = .settings
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
        // Both completing an activity and cancelling its UI must release cached providers.
        for completed in [true, false] {
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
            weak var retainedLease = lease
            let url = try XCTUnwrap(lease?.url)
            var share: OfflineShareItem? = OfflineShareItem(lease: try XCTUnwrap(lease))
            // Inspect the exact input supplied to UIKit, not UIResponder's unrelated
            // activityItemsConfiguration property (which can legitimately be nil).
            let (controller, provider) = try XCTUnwrap(share).makeActivity()
            XCTAssertEqual(provider.suggestedName, "copy.txt")
            lease = nil; share = nil
            await model.removeOfflinePin(pin)
            XCTAssertNotNil(retainedLease, "An active share must outlive both its reader and its pin")
            let copy: (URL, Data) = try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, error in
                    do {
                        if let error { throw error }
                        guard let url else { throw OfflineFileError.missing }
                        continuation.resume(returning: (url, try Data(contentsOf: url)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            XCTAssertEqual(copy.1, Data("changed server bytes\r\n東京  ".utf8))
            XCTAssertNotEqual(copy.0, url, "The receiving service gets a copy, not in-place access")
            XCTAssertNotNil(retainedLease)
            controller.completionWithItemsHandler?(nil, completed, nil, nil)
            let completionDeadline = ContinuousClock.now + .seconds(5)
            while retainedLease != nil, ContinuousClock.now < completionDeadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(retainedLease)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            // Cached completed activity controllers/providers must no longer own the file.
            withExtendedLifetime((controller, provider)) {}
        }
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
        let onDisk = await (try MetadataStore(fileURL: directory.appendingPathComponent("library-v1.json"))).snapshot()
        XCTAssertTrue(onDisk.connections.isEmpty, "Read from the file, since the two models share a store while both live")
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

    /// Control Centre, Notification Centre, a system prompt and Face ID make a scene inactive and then
    /// active again with its connection still open. Only the background ends the session.
    func testBecomingActiveStartsANewSessionOnlyAfterTheBackgroundOrAFailedConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        await model.load()
        let profile = ConnectionProfile(name: "Lifecycle", host: "fixture.invalid", username: "reader", identityID: UUID())
        let revision = model.sessionRevision
        model.sceneBecameActive()
        model.connectionStates[profile.id] = "Connected"
        model.sceneBecameActive()
        XCTAssertEqual(model.sessionRevision, revision, "Nothing is read again after Control Centre: folders, searches and readers key on this")
        XCTAssertTrue(model.isForeground)

        model.isForeground = false
        await model.background()
        model.sceneBecameActive()
        XCTAssertEqual(model.sessionRevision, revision + 1, "A return from the background starts a new session")
        XCTAssertTrue(model.isForeground)
        model.sceneBecameActive()
        XCTAssertEqual(model.sessionRevision, revision + 1)

        // What made the scene inactive may be what a failed connection was waiting for: the Local
        // Network prompt, or Wi-Fi turned on in Control Centre.
        model.handle(RemoteFileError.timedOut, profile: profile)
        model.sceneBecameActive()
        XCTAssertEqual(model.sessionRevision, revision + 2, "A connection that had failed is tried again")
        model.connectionStates[profile.id] = "Connected"
        model.sceneBecameActive()
        XCTAssertEqual(model.sessionRevision, revision + 2)
    }

    func testRecordingTheNewestRecentAgainChangesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: BackgroundExportService())
        await model.load()
        let profile = ConnectionProfile(name: "Recents", host: "fixture.invalid", username: "reader", identityID: UUID())
        let first = RemoteEntry(name: "one.md", path: "/docs/one.md", kind: .file)
        let second = RemoteEntry(name: "two.md", path: "/docs/two.md", kind: .file)
        await model.recordRecent(profile: profile, entry: first)
        await model.recordRecent(profile: profile, entry: second)
        let library = directory.appendingPathComponent("library-v1.json")
        let recents = model.metadata.recents, saved = try Data(contentsOf: library)
        let written = try FileManager.default.attributesOfItem(atPath: library.path)[.modificationDate] as? Date
        XCTAssertEqual(recents.map(\.path), [second.path, first.path])
        // Every check of an open file records it. Recording the newest again rewrote the library and
        // gave its row a new identity each time.
        await model.recordRecent(profile: profile, entry: second)
        XCTAssertEqual(model.metadata.recents, recents)
        XCTAssertEqual(try Data(contentsOf: library), saved)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: library.path)[.modificationDate] as? Date, written)
        await model.recordRecent(profile: profile, entry: first)
        XCTAssertEqual(model.metadata.recents.map(\.path), [first.path, second.path], "An older recent still moves to the top")
    }

    /// Each window has its own model. They share one library, one set of trusted host keys and one
    /// reading history; with a store apiece, each wrote its own copy back over what another had saved.
    func testWindowsShareOneLibraryAndNeverWriteAnOlderCopyOverIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try AppModel(directory: directory, fileService: BackgroundExportService())
        let second = try AppModel(directory: directory, fileService: BackgroundExportService())
        // Never loaded, so its copy of the library stays as empty as a window that hasn't heard yet.
        let stale = try AppModel(directory: directory, fileService: BackgroundExportService())
        await first.load(); await second.load()
        let library = directory.appendingPathComponent("library-v1.json")
        func saved() async throws -> AppMetadata { await (try MetadataStore(fileURL: library)).snapshot() }

        let identity = IdentityMetadata(name: "Shared key", publicKey: "ssh-ed25519 fixture", fingerprint: "SHA256:fixture",
                                        requiresPassphrase: false, keychainReference: "fixture")
        var profile = ConnectionProfile(name: "Added in one window", host: "fixture.invalid", username: "reader", identityID: identity.id)
        try await first.addIdentity(identity)
        await first.saveConnection(profile)
        try await waitForOfflineState { second.metadata.connections == [profile] && second.metadata.identities == [identity] }
        XCTAssertEqual(first.metadata.identities, [identity], "Told of its own change, a window doesn't add it twice")

        // Opening a file and favouriting a folder in windows that haven't heard of the connection.
        await stale.recordRecent(profile: profile, entry: .init(name: "one.md", path: "/docs/one.md", kind: .file))
        await stale.favourite(profile: profile, path: "/docs")
        var onDisk = try await saved()
        XCTAssertEqual(onDisk.connections, [profile], "A window's older copy must not replace a connection saved since")
        XCTAssertEqual(onDisk.identities, [identity])
        XCTAssertEqual(onDisk.recents.map(\.path), ["/docs/one.md"]); XCTAssertEqual(onDisk.favourites.map(\.path), ["/docs"])
        try await waitForOfflineState { first.metadata == onDisk && second.metadata == onDisk }
        await second.favourite(profile: profile, path: "/docs")
        try await waitForOfflineState { first.metadata.favourites.isEmpty }

        // The key is still in use by a connection another window made, whatever this window's copy says.
        await stale.deleteIdentity(identity)
        onDisk = try await saved()
        XCTAssertEqual(onDisk.identities, [identity]); XCTAssertNotNil(stale.errorMessage)

        // Trust and history are one store each: a reset in one window holds in every other.
        XCTAssertTrue(first.trust === second.trust); XCTAssertTrue(first.readingPositions === second.readingPositions)
        XCTAssertTrue(first.metadataStore === second.metadataStore)
        let endpoint = HostEndpoint(host: "rotated.invalid", port: 22), other = HostEndpoint(host: "other.invalid", port: 22)
        let oldKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let otherKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        try await first.trust.trustUnknown(endpoint: endpoint, key: HostKeyDetails(publicKey: oldKey))
        try await second.trust.validate(endpoint: endpoint, publicKey: oldKey)
        try await first.trust.reset(endpoint: endpoint)
        try await second.trust.trustUnknown(endpoint: other, key: HostKeyDetails(publicKey: otherKey))
        for store in [second.trust, try HostTrustStore(fileURL: directory.appendingPathComponent("known-hosts-v1.json"))] {
            do { try await store.validate(endpoint: endpoint, publicKey: oldKey); XCTFail("A key whose trust was reset is trusted again") }
            catch HostTrustError.unknown { }
            try await store.validate(endpoint: other, publicKey: otherKey)
        }

        // A connection edited or removed in one window is retired in the others, as it is where it was edited.
        let listing = FolderListing(.init(path: "/docs", entries: []))
        second.routes = [.folder(profile.id, "/docs")]; second.cache(listing, id: profile.id, requestedPath: "/docs")
        profile.host = "moved.invalid"
        await first.saveConnection(profile)
        try await waitForOfflineState { second.metadata.connections == [profile] && second.routes.isEmpty }
        XCTAssertNil(second.cachedListing(profile.id, path: "/docs"), "Names read from the old server aren't shown under the new one")
        second.routes = [.folder(profile.id, "/docs")]
        await first.removeConnection(profile)
        try await waitForOfflineState { second.metadata.connections.isEmpty && second.routes.isEmpty }
        onDisk = try await saved()
        XCTAssertTrue(onDisk.connections.isEmpty); XCTAssertTrue(onDisk.recents.isEmpty)

        // Demo shows its own library and keeps the real one current for leaving it.
        await second.setDemo(true)
        let demoConnections = second.metadata.connections
        let later = ConnectionProfile(name: "Added during Demo", host: "later.invalid", username: "reader", identityID: identity.id)
        await first.saveConnection(later)
        // A favourite saved after it marks the point by which this window has heard of both.
        await first.favourite(profile: later, path: "/later")
        XCTAssertEqual(second.metadata.connections, demoConnections)
        await second.setDemo(false)
        try await waitForOfflineState { second.metadata.connections == [later] && second.metadata.favourites.map(\.path) == ["/later"] }
        onDisk = try await saved()
        XCTAssertEqual(second.metadata, onDisk)
    }

    // MARK: Keys stay unlocked through changes to connections

    /// A window with connections X (its own key, and a jump host key) and Y (its own key), all encrypted, and
    /// the keys of Y, X and the jump host unlocked. Saved in the library, as the app has them.
    private struct KeyedLibrary {
        let model: AppModel
        let store: IdentityStore
        let x: ConnectionProfile, y: ConnectionProfile
        let xKey: IdentityMetadata, yKey: IdentityMetadata, jumpKey: IdentityMetadata
        let directory: URL
        var all: [IdentityMetadata] { [xKey, yKey, jumpKey] }
    }

    private func keyedLibrary(fileService: (any RemoteFileService)? = nil, store existing: IdentityStore? = nil) async throws -> KeyedLibrary {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = existing ?? EncryptedKeyFixture.makeStore()
        let xKey = try await EncryptedKeyFixture.importKey(into: store, name: "X")
        let yKey = try await EncryptedKeyFixture.importKey(into: store, name: "Y")
        let jumpKey = try await EncryptedKeyFixture.importKey(into: store, name: "Jump")
        for key in [xKey, yKey, jumpKey] { try await EncryptedKeyFixture.unlock(key, in: store) }
        let x = ConnectionProfile(name: "X", host: "x.invalid", username: "reader", identityID: xKey.id,
                                  jumpHost: JumpHost(host: "jump.invalid", username: "reader", identityID: jumpKey.id))
        let y = ConnectionProfile(name: "Y", host: "y.invalid", username: "reader", identityID: yKey.id)
        let model = try AppModel(directory: directory, fileService: fileService, identities: store)
        _ = try await model.metadataStore.update(origin: UUID()) { $0.identities = [xKey, yKey, jumpKey]; $0.connections = [x, y] }
        await model.load()
        return KeyedLibrary(model: model, store: store, x: x, y: y, xKey: xKey, yKey: yKey, jumpKey: jumpKey, directory: directory)
    }

    private func assertUnlocked(_ keys: [IdentityMetadata], in store: IdentityStore, _ context: String,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for key in keys {
            let unlocked = try await EncryptedKeyFixture.isUnlocked(key, in: store)
            XCTAssertTrue(unlocked, "\(context): \(key.name) locked", file: file, line: line)
        }
    }
    private func assertLocked(_ keys: [IdentityMetadata], in store: IdentityStore, _ context: String,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        for key in keys {
            let unlocked = try await EncryptedKeyFixture.isUnlocked(key, in: store)
            XCTAssertFalse(unlocked, "\(context): \(key.name) still unlocked", file: file, line: line)
        }
    }

    /// Editing, removing, forgetting trust, entering or leaving Demo and hearing another window edit a
    /// connection each close this window's connection, but the keys other connections use stay unlocked.
    func testChangingConnectionsKeepsTheKeysOfOtherConnectionsUnlocked() async throws {
        enum Action: CaseIterable { case edit, remove, resetTrust, resetJumpHostTrust, enterDemo, leaveDemo, editedElsewhere }
        for action in Action.allCases {
            let library = try await keyedLibrary()
            let model = library.model, store = library.store, context = "\(action)"
            switch action {
            case .edit:
                var edited = library.x; edited.host = "moved.invalid"
                await model.saveConnection(edited)
                try await assertUnlocked(library.all, in: store, context)
            case .remove:
                await model.removeConnection(library.x)
                try await assertUnlocked([library.yKey], in: store, context)
                // Nothing uses X's own key or its jump host's any more.
                try await assertLocked([library.xKey, library.jumpKey], in: store, context)
            case .resetTrust:
                await model.resetTrust(for: library.x)
                try await assertUnlocked(library.all, in: store, context)
            case .resetJumpHostTrust:
                await model.resetJumpHostTrust(for: library.x)
                try await assertUnlocked(library.all, in: store, context)
            case .enterDemo:
                await model.setDemo(true)
                try await assertUnlocked(library.all, in: store, context)
            case .leaveDemo:
                await model.setDemo(true)
                await model.setDemo(false)
                try await assertUnlocked(library.all, in: store, context)
            case .editedElsewhere:
                // Another window moves X to another key. This window had X open, so its session ends; the keys
                // other connections use stay unlocked, and the one no connection uses any more does not.
                let other = try await EncryptedKeyFixture.importKey(into: library.store, name: "Other")
                let second = try AppModel(directory: library.directory, identities: EncryptedKeyFixture.makeStore())
                await second.load()
                model.connectionStates = [library.x.id: "Connected"]
                var edited = library.x; edited.identityID = other.id
                _ = try await model.metadataStore.update(origin: UUID()) { $0.identities.append(other) }
                await second.saveConnection(edited)
                try await waitUntil("\(context): the window ended X's session") { model.connectionStates.isEmpty && model.metadata.connections.contains(edited) }
                try await waitUntil("\(context): X's old key locked") { (try? await EncryptedKeyFixture.isUnlocked(library.xKey, in: store)) == false }
                try await assertUnlocked([library.yKey, library.jumpKey], in: store, context)
            }
        }
    }

    /// Demo shows its own library, but the keys in use are the real library's: editing or removing a Demo
    /// connection must not lock a real connection's key.
    func testEditingInDemoKeepsTheRealLibrarysKeysUnlocked() async throws {
        let library = try await keyedLibrary()
        let model = library.model
        await model.setDemo(true)
        var demoConnection = try XCTUnwrap(model.metadata.connections.first)
        XCTAssertFalse(model.metadata.connections.contains(library.y), "Demo has its own library")
        demoConnection.name = "Renamed demo"
        await model.saveConnection(demoConnection)
        try await assertUnlocked(library.all, in: library.store, "Editing in Demo")
        await model.removeConnection(demoConnection)
        try await assertUnlocked(library.all, in: library.store, "Removing in Demo")
        await model.setDemo(false)
        XCTAssertEqual(Set(model.metadata.connections.map(\.id)), [library.x.id, library.y.id])
    }

    /// Explicit Disconnect and backgrounding still lock every key, as does deleting the key itself.
    func testDisconnectAndBackgroundStillLockEveryKey() async throws {
        let library = try await keyedLibrary()
        await library.model.disconnectAndGoHome()
        try await assertLocked(library.all, in: library.store, "Disconnect")
        for key in library.all { try await EncryptedKeyFixture.unlock(key, in: library.store) }
        await library.model.background()
        try await assertLocked(library.all, in: library.store, "Background")
        for key in library.all { try await EncryptedKeyFixture.unlock(key, in: library.store) }
        try await library.store.delete(library.yKey, referencedBy: [])
        do { _ = try await library.store.unlock(library.yKey); XCTFail("A deleted key must not stay unlocked") }
        catch IdentityError.missingSecret { }
    }

    /// An explicit Disconnect that arrives while an edit's close is still running locks the keys once it ends.
    func testDisconnectJoiningAnEditsCloseStillLocksTheKeys() async throws {
        let base = NestedDisconnectService()
        let library = try await keyedLibrary(fileService: base)
        var edited = library.x; edited.host = "moved.invalid"
        let edit = Task { await library.model.saveConnection(edited) }
        try await wait { await base.closing() }
        try await assertUnlocked(library.all, in: library.store, "While the edit's close runs")
        let home = Task { await library.model.disconnectAndGoHome() }
        try await Task.sleep(for: .milliseconds(50))
        await base.finishClose()
        await edit.value; await home.value
        try await assertLocked(library.all, in: library.store, "Disconnect after an edit's close")
    }

    /// An edit or removal drops the key a connection used when nothing else saved uses it, whether the
    /// other use is a connection's own key or a jump host's. The new key unlocks as usual.
    func testEditingOrRemovingAConnectionDropsItsOldKeyOnlyWhenNothingElseUsesIt() async throws {
        enum Other: CaseIterable { case nothing, connection, jumpHost }
        for removal in [false, true] {
            for other in Other.allCases {
                let store = EncryptedKeyFixture.makeStore()
                let library = try await keyedLibrary(store: store)
                let k1 = library.xKey, k2 = try await EncryptedKeyFixture.importKey(into: store, name: "K2")
                let model = library.model
                // X uses K1 alone; Z may use it too.
                let x = ConnectionProfile(name: "X", host: "x.invalid", username: "reader", identityID: k1.id)
                let z: ConnectionProfile?
                switch other {
                case .nothing: z = nil
                case .connection: z = ConnectionProfile(name: "Z", host: "z.invalid", username: "reader", identityID: k1.id)
                case .jumpHost: z = ConnectionProfile(name: "Z", host: "z.invalid", username: "reader", identityID: library.yKey.id,
                                                      jumpHost: JumpHost(host: "jump.invalid", username: "reader", identityID: k1.id))
                }
                _ = try await model.metadataStore.update(origin: UUID()) {
                    $0.identities.append(k2); $0.connections = [x, library.y] + (z.map { [$0] } ?? [])
                }
                await model.load()
                let context = "\(removal ? "Removing" : "Editing") with \(other)"
                if removal { await model.removeConnection(x) }
                else { var edited = x; edited.identityID = k2.id; await model.saveConnection(edited) }
                if other == .nothing { try await assertLocked([k1], in: store, context) }
                else { try await assertUnlocked([k1], in: store, context) }
                try await assertUnlocked([library.yKey], in: store, context)
                if !removal {
                    // The new key was not unlocked, and unlocks as any key does.
                    try await assertLocked([k2], in: store, context)
                    try await EncryptedKeyFixture.unlock(k2, in: store)
                    try await assertUnlocked([k2], in: store, context)
                }
            }
        }
    }

    /// Keys outlive the connection that used them (after a trust reset or Demo), so a window that hears of
    /// another's edit or removal of that connection locks the key even with no session to end, in Demo too.
    func testKeyOfAConnectionRemovedElsewhereLocksWithoutAnActiveSession() async throws {
        for inDemo in [false, true] {
            let library = try await keyedLibrary()
            let model = library.model
            let second = try AppModel(directory: library.directory, identities: EncryptedKeyFixture.makeStore())
            await second.load()
            await model.resetTrust(for: library.x)
            if inDemo { await model.setDemo(true) }
            try await assertUnlocked(library.all, in: library.store, "Demo \(inDemo): before")
            await second.removeConnection(library.x)
            try await waitUntil("Demo \(inDemo): X's key locked") {
                (try? await EncryptedKeyFixture.isUnlocked(library.xKey, in: library.store)) == false
            }
            try await assertLocked([library.jumpKey], in: library.store, "Demo \(inDemo)")
            try await assertUnlocked([library.yKey], in: library.store, "Demo \(inDemo)")
        }
    }

    /// A download of another connection that is queued while one connection is edited still has its key when
    /// it starts, instead of failing for a passphrase.
    func testQueuedDownloadNeedingAKeyCompletesAfterAnotherConnectionIsEdited() async throws {
        let store = EncryptedKeyFixture.makeStore()
        let service = KeyedDownloadService(identities: store)
        let library = try await keyedLibrary(fileService: service, store: store)
        await service.know(library.all)
        let model = library.model
        await service.hold("/first.bin")
        model.enqueueDownload(profile: library.y, entry: file("first.bin"))
        model.enqueueDownload(profile: library.y, entry: file("second.bin"))
        let manager = try XCTUnwrap(model.downloads)
        try await waitUntil("The first download started") { manager.items.first?.state == .downloading }
        var edited = library.x; edited.host = "moved.invalid"
        await model.saveConnection(edited)
        await model.resetTrust(for: library.x)
        await service.release("/first.bin")
        try await waitUntil("The queued download finished") { manager.items.last?.state == .completed }
        XCTAssertEqual(manager.items.map(\.state), [.completed, .completed])
        let finished = await service.finished
        XCTAssertEqual(finished, ["/first.bin", "/second.bin"])
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
