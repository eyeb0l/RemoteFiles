#if os(iOS)
import XCTest
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import RemoteFilesCore
@testable import RemoteFilesUI

/// A transport that hands over a few bytes for any download asked of it.
private actor DownloadingService: RemoteFileService {
    let bytes: Data
    var fails = false
    init(bytes: Data) { self.bytes = bytes }
    func failNext() { fails = true }
    func disconnect() async {}
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: []) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { .init(name: RemotePath.name(of: path), path: path, kind: .file) }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        if fails { fails = false; throw RemoteFileError.connectionEnded }
        try bytes.write(to: destination)
        return .init(name: RemotePath.name(of: path), path: path, kind: .file, size: UInt64(bytes.count))
    }
}

/// A queue with one transfer, as the background coordinator sees it.
@MainActor private final class WatchedQueue: BackgroundTransferQueue {
    var isForeground = true
    private(set) var activeID: UUID?
    private var running: BackgroundTransferProgress?
    private var succeeded = false
    private(set) var interruptions: [String] = []
    let wording = (one: "transfer", doing: "transferring", all: "Transfers")
    private var size: UInt64?
    /// `id` is given for a row that is retried, which keeps its id.
    func start(_ id: UUID = UUID(), completed: UInt64, remaining: UInt64?) {
        activeID = id; size = remaining.map { completed + $0 }
        running = .init(title: "Uploading file", detail: "", completed: completed, total: size ?? max(completed, 1), remaining: remaining)
    }
    func progress(completed: UInt64) {
        running = .init(title: "Uploading file", detail: "", completed: completed, total: size ?? max(completed, 1),
                        remaining: size.map { $0 > completed ? $0 - completed : 0 })
    }
    func end(succeeded: Bool) { self.succeeded = succeeded; running = nil; activeID = nil }
    func runningTransfer(_ id: UUID) -> BackgroundTransferProgress? { id == activeID ? running : nil }
    func transferSucceeded(_ id: UUID) -> Bool { succeeded }
    func interruptNow(reason: String) -> Task<Void, Never> { interruptions.append(reason); end(succeeded: false); return Task { } }
}

/// Stands in for the short time iOS gives an app as it leaves the screen and for the clock the coordinator
/// looks at a short transfer by, and records what is asked of iOS.
@MainActor private final class ShortTime {
    var held = UIBackgroundTaskIdentifier(rawValue: 41)
    private(set) var begun = 0
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var asked: [UUID?] = []
    /// The short time taken and given back, in order.
    private(set) var log: [String] = []
    /// Run as the short time is given back, before the call returns.
    var onEnd: (() -> Void)?
    private var expired: (@MainActor () -> Void)?
    func expire() { expired?() }

    /// How many times the coordinator has begun to wait for its next look.
    private(set) var waits = 0
    private let began = ContinuousClock.now
    private var elapsed = Duration.zero
    private let (looks, next) = AsyncStream<Void>.makeStream()

    /// The coordinator keeps this object: a look that was waiting when a test ended still reads its clock.
    func coordinator() -> BackgroundDownloadCoordinator {
        let coordinator = BackgroundDownloadCoordinator(wording: ("transfer", "transferring", "Transfers"))
        coordinator.beginShortTime = { _, expired in
            MainActor.assumeIsolated { self.begun += 1; self.log.append("taken"); self.expired = expired; return self.held }
        }
        coordinator.endShortTime = { id in MainActor.assumeIsolated { self.ended.append(id); self.log.append("given back"); self.onEnd?() } }
        coordinator.askedForTask = { id in MainActor.assumeIsolated { self.asked.append(id) } }
        coordinator.now = { self.began + self.elapsed }
        coordinator.pause = { _ in
            self.waits += 1
            var iterator = self.looks.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
            try Task.checkCancellation()
        }
        return coordinator
    }
    /// Waits until the coordinator is waiting for a look, as it is a moment after a short transfer starts.
    func waiting(_ count: Int) async -> Bool {
        for _ in 0..<400 where waits < count { try? await Task.sleep(for: .milliseconds(5)) }
        return waits >= count
    }
    /// Lets the look that is waited for happen, `seconds` later by the coordinator's clock. True if the
    /// coordinator then waits for another look, false if it has stopped looking.
    func look(after seconds: Double = 2) async -> Bool {
        let before = waits
        elapsed += .seconds(seconds)
        next.yield()
        for _ in 0..<60 where waits == before { try? await Task.sleep(for: .milliseconds(5)) }
        return waits > before
    }
}

/// A transport that keeps a session for each server and takes uploads, recording what the window asks of it.
private actor HostService: RemoteFileService, HostSessionClosing, RemoteFileSessionClosing, RemoteFileUploading {
    private(set) var closedHosts: [UUID] = []
    private(set) var closes = 0, disconnects = 0
    private(set) var uploads: [(profile: ConnectionProfile, request: UploadRequest)] = []
    private(set) var waiting: [String] = []
    private var held: Set<String> = []
    func hold(_ name: String) { held.insert(name) }
    func release(_ name: String) { held.remove(name) }
    private func isHeld(_ name: String) -> Bool { held.contains(name) }

    func closeSession(of connectionID: UUID) async { closedHosts.append(connectionID) }
    func closeSessionPreservingUnlockedIdentities() async { closes += 1 }
    func disconnect() async { disconnects += 1 }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: []) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
    func uploadFile(profile: ConnectionProfile, request: UploadRequest, source: any TransferSource,
                    started: @escaping UploadStartHandler, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        uploads.append((profile, request))
        let version = try await source.describe()
        await started(version, 0)
        if isHeld(request.name) {
            waiting.append(request.name)
            while isHeld(request.name) { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await source.send(from: 0, expecting: version) { _ in }
        return .init(name: request.name, path: request.directory + "/" + request.name, kind: .file, size: version.size)
    }
    func removePartialUpload(profile: ConnectionProfile, directory: String, partialName: String, restoring name: String?) async throws {}
}

@MainActor final class AppModelTransferTests: XCTestCase {
    private let first = ConnectionProfile(name: "Web", host: "web.invalid", username: "deploy", identityID: UUID(), startingDirectory: "/srv")
    private let second = ConnectionProfile(name: "Backup", host: "backup.invalid", username: "deploy", identityID: UUID(), startingDirectory: "/data")

    private func makeModel(_ service: HostService) async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-transfers-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: service)
        await model.load()
        model.metadata.connections = [first, second]
        await model.persist()
        return model
    }
    private func connect(_ model: AppModel, _ profile: ConnectionProfile) {
        model.noteForegroundConnection(profile.id)
        model.connectionStates[profile.id] = "Connected"
    }
    private func file(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("model-upload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data("contents of \(name)".utf8).write(to: url)
        return url
    }
    /// A list drawn for the first time just after a simulator boots can take many seconds on a loaded
    /// runner, so the tests that host one wait as long as a UI journey would (docs/CI.md).
    private static let hostedView = Duration.seconds(60)
    private func wait(for what: String = "the condition", within limit: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    func testOpeningAnotherServerKeepsTheFirstConnectedAndItsRowReturnsToItsPlace() async throws {
        let service = HostService()
        let model = try await makeModel(service)
        let report = RemoteEntry(name: "report.md", path: "/srv/logs/report.md", kind: .file)
        connect(model, first)
        let place: [AppModel.Route] = [.folder(first.id, "/srv"), .folder(first.id, "/srv/logs"), .file(first.id, report)]
        model.routes = place

        model.openFromLibrary(.folder(second.id, second.startingDirectory))
        XCTAssertEqual(model.routes, [.folder(second.id, "/data")])
        connect(model, second)
        XCTAssertEqual(model.connectionStates[first.id], "Connected", "Opening a second server leaves the first connected")
        var closed = await service.closedHosts
        XCTAssertEqual(closed, [])

        // The first server's row returns to the folder and file it was showing.
        model.routes.append(.folder(second.id, "/data/archive"))
        model.openFromLibrary(.folder(first.id, first.startingDirectory))
        XCTAssertEqual(model.routes, place)
        XCTAssertEqual(model.workspaceFile, .file(first.id, report))
        // Chosen again while it is on screen, it goes to its starting folder.
        model.openFromLibrary(.folder(first.id, first.startingDirectory))
        XCTAssertEqual(model.routes, [.folder(first.id, "/srv")])
        // And the second server is where it was left.
        model.openFromLibrary(.folder(second.id, second.startingDirectory))
        XCTAssertEqual(model.routes, [.folder(second.id, "/data"), .folder(second.id, "/data/archive")])
        // A favourite or recent file goes where it says, whatever was left on that server.
        model.openFromLibrary(.folder(first.id, "/srv/releases"))
        XCTAssertEqual(model.routes, [.folder(first.id, "/srv/releases")])
        closed = await service.closedHosts
        XCTAssertEqual(closed, [])
    }

    /// Adding a server is how a second one comes to be open, so it must not close the first.
    func testAddingAConnectionLeavesConnectedServersConnectedAndEditingOneStillEndsEverySession() async throws {
        let service = HostService()
        let model = try await makeModel(service)
        connect(model, first)
        model.routes = [.folder(first.id, "/srv")]
        let revision = model.sessionRevision

        let third = ConnectionProfile(name: "Staging", host: "staging.invalid", username: "deploy", identityID: UUID(), startingDirectory: "/var")
        await model.saveConnection(third)
        XCTAssertEqual(model.metadata.connections.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(model.connectionStates[first.id], "Connected")
        XCTAssertEqual(model.routes, [.folder(first.id, "/srv")])
        XCTAssertEqual(model.sessionRevision, revision, "The folder on screen has no reason to list itself again")
        var closes = await service.closes, disconnects = await service.disconnects
        XCTAssertEqual([closes, disconnects], [0, 0])

        // An edit may have changed the server, the account or the key: every session ends, as before.
        var edited = second; edited.host = "moved.invalid"
        await model.saveConnection(edited)
        XCTAssertNil(model.connectionStates[first.id])
        XCTAssertGreaterThan(model.sessionRevision, revision)
        closes = await service.closes; disconnects = await service.disconnects
        XCTAssertEqual(closes + disconnects, 1)
    }

    func testDisconnectingOneServerLeavesTheOthersAndTheLastOneDisconnectsEverything() async throws {
        let service = HostService()
        let model = try await makeModel(service)
        connect(model, first)
        model.routes = [.folder(first.id, "/srv")]
        model.openFromLibrary(.folder(second.id, second.startingDirectory))
        connect(model, second)

        await model.disconnect(first)
        var closed = await service.closedHosts, disconnects = await service.disconnects
        XCTAssertEqual(closed, [first.id])
        XCTAssertEqual(disconnects, 0, "The other server's session and keys are untouched")
        XCTAssertNil(model.connectionStates[first.id])
        XCTAssertEqual(model.connectionStates[second.id], "Connected")
        XCTAssertEqual(model.routes, [.folder(second.id, "/data")], "The server on screen stays where it is")
        // Its place went with its connection: the row opens its starting folder.
        model.openFromLibrary(.folder(first.id, first.startingDirectory))
        XCTAssertEqual(model.routes, [.folder(first.id, "/srv")])
        model.openFromLibrary(.folder(second.id, second.startingDirectory))

        // With nothing else connected, Disconnect is what it has always been.
        await model.disconnect(second)
        closed = await service.closedHosts; disconnects = await service.disconnects
        XCTAssertEqual(closed, [first.id])
        XCTAssertGreaterThanOrEqual(disconnects, 1)
        XCTAssertEqual(model.routes, [])
        XCTAssertTrue(model.connectionStates.isEmpty)
    }

    func testPastTheLimitTheServerUsedLongestAgoCloses() async throws {
        let service = HostService()
        let model = try await makeModel(service)
        let profiles = (0...AppModel.liveHostLimit).map {
            ConnectionProfile(name: "Server \($0)", host: "s\($0).invalid", username: "deploy", identityID: UUID())
        }
        for profile in profiles.dropLast() { connect(model, profile) }
        var closed = await service.closedHosts
        XCTAssertEqual(closed, [], "Up to the limit every server stays connected")
        // The first is used again, so the second is now the one used longest ago.
        connect(model, profiles[0])
        connect(model, profiles[AppModel.liveHostLimit])
        try await wait { await service.closedHosts.count == 1 }
        closed = await service.closedHosts
        XCTAssertEqual(closed, [profiles[1].id])
        XCTAssertNil(model.connectionStates[profiles[1].id])
        XCTAssertEqual(model.connectionStates[profiles[0].id], "Connected")
    }

    func testUploadsLeaveOutOrAnswerTakenNamesAndAFinishedOneRefreshesItsFolder() async throws {
        let service = HostService()
        let model = try await makeModel(service)
        XCTAssertTrue(model.supportsTransfers)
        let kept = try file("kept.txt"), taken = try file("taken.txt")
        XCTAssertEqual(model.folderChangeCount(first.id, path: "/srv"), 0)
        // No answer for a taken name: that file is left out, and the rest are sent.
        model.enqueueUploads([kept, taken], to: first, directory: "/srv", taken: ["taken.txt"], answer: nil)
        XCTAssertEqual(model.transfers?.items.map(\.filename), ["kept.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: taken.path), "A copy that isn't sent isn't kept")
        try await wait { model.transfers?.items.allSatisfy { $0.state == .completed } == true }
        XCTAssertEqual(model.folderChangeCount(first.id, path: "/srv"), 1)
        XCTAssertEqual(model.transferNotice, "Uploaded kept.txt to srv")
        XCTAssertNil(model.sheet, "Starting an upload doesn't take the folder away")

        // An answer goes with the taken name only, and two files of one name are kept beside each other.
        let again = try file("taken.txt"), one = try file("same.txt"), two = try file("same.txt")
        model.enqueueUploads([again, one, two], to: first, directory: "/srv", taken: ["taken.txt"], answer: .replace)
        try await wait { model.transfers?.items.allSatisfy { $0.state == .completed } == true }
        let conflicts = await service.uploads.suffix(3).map(\.request.conflict)
        XCTAssertEqual(conflicts, [.replace, .fail, .keepBoth])
        XCTAssertEqual(model.folderChangeCount(first.id, path: "/srv"), 4)
        XCTAssertEqual(model.transferNotice, "Uploaded 3 files")

        // Nothing is queued from the background, and what was offered is not kept.
        model.isForeground = false
        let late = try file("late.txt")
        model.enqueueUploads([late], to: first, directory: "/srv")
        XCTAssertEqual(model.transfers?.items.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    /// A photo or video copied out of the library and never queued, as when the app is closed while it asks
    /// about a taken name, has no transfer to own it. The next launch removes it and nothing else.
    func testCopiesOfLibraryItemsLeftByAnEarlierRunAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("picked-sweep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let abandoned = directory.appendingPathComponent(PickedLibraryFile.folderPrefix + UUID().uuidString)
        let other = directory.appendingPathComponent("something-else")
        for folder in [abandoned, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("video".utf8).write(to: folder.appendingPathComponent("IMG_0001.mov"))
        }
        PickedLibraryFile.removeAbandoned(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("IMG_0001.mov").path))
    }

    /// What a drag from another app hands over: files are copied out under their own names while the
    /// provider's copy still exists, and a dragged link or piece of selected text is not taken for a file.
    func testDroppedFilesAreCopiedUnderTheirNamesAndLinksAndSelectedTextAreLeftOut() async throws {
        let sources = FileManager.default.temporaryDirectory.appendingPathComponent("drop-sources-" + UUID().uuidString)
        let incoming = FileManager.default.temporaryDirectory.appendingPathComponent("drop-incoming-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sources); try? FileManager.default.removeItem(at: incoming) }
        let report = sources.appendingPathComponent("Quarterly report.pdf"), notes = sources.appendingPathComponent("notes.txt")
        let pdf = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try pdf.write(to: report); try Data("plain notes".utf8).write(to: notes)
        // A link dragged from a page can carry the page's title as its name and its address as text, and a
        // selection of styled text an archive of itself. Neither is a file, whatever else it offers.
        func offering(_ types: [UTType], named name: String?) -> NSItemProvider {
            let provider = NSItemProvider()
            for type in types {
                provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { done in
                    done(Data("https://example.com/page".utf8), nil); return nil
                }
            }
            provider.suggestedName = name
            return provider
        }
        // A file whose bytes never arrive, as one in iCloud that can't be fetched, and a folder.
        let unreadable = NSItemProvider()
        unreadable.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { done in
            done(nil, false, CocoaError(.fileReadNoSuchFile)); return nil
        }
        unreadable.suggestedName = "Not here.pdf"
        let folder = sources.appendingPathComponent("A folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let providers = [try XCTUnwrap(NSItemProvider(contentsOf: report)), NSItemProvider(object: "some selected text" as NSString),
                         NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.com/page")) as NSURL),
                         offering([.url, .utf8PlainText], named: "Example page"),
                         offering([.webArchive, .flatRTFD, .html, .utf8PlainText], named: nil),
                         unreadable, try XCTUnwrap(NSItemProvider(contentsOf: folder)),
                         try XCTUnwrap(NSItemProvider(contentsOf: notes))]
        let dropped: (files: [URL], skipped: Int, unread: Int) = await withCheckedContinuation { continuation in
            UploadDrop.load(providers, into: incoming) { files, skipped, unread in continuation.resume(returning: (files, skipped, unread)) }
        }
        XCTAssertEqual(dropped.files.map(\.lastPathComponent), ["Quarterly report.pdf", "notes.txt"],
                       "In the order dropped, under their own names. Providers: \(providers.map { "\($0.registeredTypeIdentifiers) \($0.suggestedName ?? "-")" })")
        XCTAssertEqual(dropped.skipped, 5, "The selected text, the link, the named link, the styled selection and the folder")
        XCTAssertEqual(dropped.unread, 1, "The file that couldn't be read is not counted as something that wasn't a file")
        // What is handed over is a folder only if it is known to be one: something that can't be looked at
        // is a file that couldn't be read, and is not told that folders can't be uploaded.
        XCTAssertEqual(UploadDrop.isRegularFile(report), true)
        XCTAssertEqual(UploadDrop.isRegularFile(folder), false)
        XCTAssertNil(UploadDrop.isRegularFile(sources.appendingPathComponent("gone since.pdf")))
        XCTAssertNil(UploadDrop.message(skipped: 0, unread: 0))
        XCTAssertEqual(UploadDrop.message(skipped: 0, unread: 1), "One file couldn’t be read and wasn’t uploaded.")
        XCTAssertEqual(UploadDrop.message(skipped: 1, unread: 0), "One item wasn’t a file and wasn’t uploaded. Folders can’t be uploaded yet.")
        XCTAssertEqual(UploadDrop.message(skipped: 2, unread: 3),
                       "2 items weren’t files and weren’t uploaded. Folders can’t be uploaded yet. 3 files couldn’t be read and weren’t uploaded.")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(dropped.files.first)), pdf)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(dropped.files.last)), Data("plain notes".utf8))
        XCTAssertTrue(dropped.files.allSatisfy { $0.path.hasPrefix(incoming.path) }, "Copies live in the queue's own folder")
        // The copies are the app's own to queue: the originals are untouched.
        XCTAssertEqual(try Data(contentsOf: report), pdf)
    }

    /// A drag from another app is taken by the list's own collection view, where a SwiftUI `onDrop` around
    /// the list was not offered it, and only while the folder can take an upload. It is taken as the list's
    /// drop delegate, in front of SwiftUI's: beside it, as a second drop interaction, it lost every drop made
    /// on a row to SwiftUI's refusal of one.
    func testAFoldersListTakesFilesDroppedOnItOnlyWhileTheFolderAccepts() async throws {
        var accepts = true, targeted: [Bool] = [], dropped: [NSItemProvider] = []
        let drop = FileDrop(accepts: { accepts }, targeted: { targeted.append($0) }) { dropped += $0 }
        let window = try window(showing: UIHostingController(rootView: List { Text("row") }.background(FileDropTarget(drop: drop))))
        var found: UICollectionView?
        try await wait(for: "the list's drop target", within: Self.hostedView) {
            found = views(UICollectionView.self, in: window).first { self.target(on: $0) != nil }
            return found != nil
        }
        let list = try XCTUnwrap(found), coordinator = try XCTUnwrap(target(on: list))
        XCTAssertTrue(list.interactions.filter { $0 is UIDropInteraction }.count == 1, "One drop interaction, the list's own: \(list.interactions)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dropped-" + UUID().uuidString + ".bin")
        try Data([1, 2, 3]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let session = DropSession(items: [UIDragItem(itemProvider: try XCTUnwrap(NSItemProvider(contentsOf: file)))])

        XCTAssertTrue(coordinator.collectionView(list, canHandle: session))
        coordinator.collectionView(list, dropSessionDidEnter: session)
        // Over a row as over the space below the rows: the folder is where the file goes.
        for destination in [IndexPath(item: 0, section: 0), nil] {
            XCTAssertEqual(coordinator.collectionView(list, dropSessionDidUpdate: session, withDestinationIndexPath: destination).operation, .copy,
                           "Over \(destination.map { "row \($0.item)" } ?? "no row")")
        }
        XCTAssertEqual(targeted, [true], "The folder marks itself as the place the files will go")
        coordinator.collectionView(list, performDropWith: DropCoordinator(session: session))
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(targeted.last, false)

        // A folder that can't take an upload now, as while disconnecting, takes neither the drag nor a drop:
        // the list's own delegate answers, as it would have with no target here. SwiftUI's is stood in for,
        // so that what reaches it can be seen, and the target finds its way back in front of it.
        let own = OwnDelegate()
        list.dropDelegate = own
        try XCTUnwrap(coordinator.marker).listMayHaveChanged()
        XCTAssertTrue(target(on: list) === coordinator, "Put back in front of a delegate the list was given since")
        accepts = false
        XCTAssertFalse(coordinator.takes(session, on: list))
        XCTAssertTrue(coordinator.collectionView(list, canHandle: session))
        XCTAssertEqual(coordinator.collectionView(list, dropSessionDidUpdate: session, withDestinationIndexPath: nil).operation, .forbidden)
        coordinator.collectionView(list, performDropWith: DropCoordinator(session: session))
        XCTAssertEqual(own.asked, ["canHandle", "update", "perform"])
        XCTAssertEqual(dropped.count, 1)
        // And while it can, it answers itself and the list's own delegate hears nothing of the drop.
        accepts = true
        XCTAssertEqual(coordinator.collectionView(list, dropSessionDidUpdate: session, withDestinationIndexPath: IndexPath(item: 0, section: 0)).operation, .copy)
        XCTAssertEqual(own.asked, ["canHandle", "update", "perform"])

        // Once the view is taken down, a look for the list that was already waiting to run puts nothing back,
        // even with the marker still in the window; the list has its own delegate again, and the target that
        // answered for it takes nothing.
        let marker = try XCTUnwrap(coordinator.marker)
        FileDropTarget.dismantleUIView(marker, coordinator: coordinator)
        XCTAssertNotNil(marker.window)
        marker.listMayHaveChanged(); marker.didMoveToWindow()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(target(on: list))
        XCTAssertTrue(list.dropDelegate === own, "The list is left with the delegate it had")
        XCTAssertFalse(coordinator.takes(session, on: list))
        coordinator.collectionView(list, performDropWith: DropCoordinator(session: session))
        XCTAssertEqual(dropped.count, 1, "Nothing more than the one drop made while the view was up")
        XCTAssertEqual(own.asked, ["canHandle", "update", "perform"], "Nor is anything passed on by a target that has let go")
    }

    private func window(showing controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return window
    }
    private func views<Kind: UIView>(_ kind: Kind.Type, in view: UIView) -> [Kind] {
        (view as? Kind).map { [$0] } ?? view.subviews.flatMap { views(kind, in: $0) }
    }
    /// The drop target answering for a list, if one is.
    private func target(on list: UICollectionView) -> FileDropTarget.Coordinator? { list.dropDelegate as? FileDropTarget.Coordinator }
    private func rows(_ list: UICollectionView) -> Int { (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) } }

    /// A push or pop has two folders' lists in the same place for a moment. A drop target that took the other
    /// folder's list would send a file to a folder that isn't the one it was dropped on.
    func testADropTargetNeverTakesAListOnAnotherScreenAndAListItHasLeftTakesNothing() async throws {
        var dropped = 0
        let drop = FileDrop(accepts: { true }, targeted: { _ in }) { dropped += $0.count }
        // Two screens in the same place, as during a push: one with a list, one with only a drop target.
        let container = UIViewController()
        let alone = UIHostingController(rootView: Color.clear.background(FileDropTarget(drop: drop)))
        let other = UIHostingController(rootView: List { Text("another folder's row") })
        for child in [other, alone] {
            container.addChild(child); container.view.addSubview(child.view)
            child.view.frame = container.view.bounds; child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            child.didMove(toParent: container)
        }
        let window = try window(showing: container)
        var marker: FileDropTarget.Marker?, list: UICollectionView?
        try await wait(for: "both screens to be laid out", within: Self.hostedView) {
            marker = views(FileDropTarget.Marker.self, in: alone.view).first { $0.bounds.width > 0 }
            list = views(UICollectionView.self, in: other.view).first { $0.bounds.width > 0 }
            return marker != nil && list != nil
        }
        let own = try XCTUnwrap(marker), foreign = try XCTUnwrap(list)
        XCTAssertTrue(foreign.superview?.convert(foreign.frame, to: window).contains(own.convert(own.bounds, to: window).insetBy(dx: 1, dy: 1)) == true,
                      "The other screen's list covers the marker, so only the screen boundary keeps them apart")
        own.listMayHaveChanged()
        XCTAssertNil(own.nearestList())
        XCTAssertNil(target(on: foreign))

        // Left answering for a list it is no longer behind, however that came about, it takes neither the
        // drag nor the drop, which go to the delegate that list had.
        let coordinator = try XCTUnwrap(own.coordinator)
        let listsOwn = OwnDelegate()
        foreign.dropDelegate = listsOwn
        coordinator.attach(to: foreign)
        XCTAssertTrue(target(on: foreign) === coordinator)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dropped-" + UUID().uuidString + ".bin")
        try Data([1]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let session = DropSession(items: [UIDragItem(itemProvider: try XCTUnwrap(NSItemProvider(contentsOf: file)))])
        XCTAssertFalse(coordinator.takes(session, on: foreign))
        XCTAssertEqual(coordinator.collectionView(foreign, dropSessionDidUpdate: session, withDestinationIndexPath: nil).operation, .forbidden)
        coordinator.collectionView(foreign, performDropWith: DropCoordinator(session: session))
        XCTAssertEqual(listsOwn.asked, ["update", "perform"])
        XCTAssertEqual(dropped, 0)

        // Were a second target ever behind the same list, neither passes on to the other, however often
        // each puts itself back in front: what neither takes reaches the list's own delegate once.
        let second = FileDropTarget.Coordinator()
        second.attach(to: foreign); coordinator.attach(to: foreign); second.attach(to: foreign); coordinator.attach(to: foreign)
        XCTAssertTrue(target(on: foreign) === coordinator)
        listsOwn.asked = []
        XCTAssertTrue(coordinator.collectionView(foreign, canHandle: session))
        XCTAssertTrue(second.collectionView(foreign, canHandle: session))
        XCTAssertEqual(listsOwn.asked, ["canHandle", "canHandle"])
        // Letting go in either order leaves the list with its own delegate.
        second.attach(to: nil)
        XCTAssertTrue(target(on: foreign) === coordinator, "One that isn't in front changes nothing by letting go")
        coordinator.attach(to: nil)
        XCTAssertTrue(foreign.dropDelegate === listsOwn)
        coordinator.attach(to: foreign); second.attach(to: foreign); coordinator.attach(to: nil); second.attach(to: nil)
        XCTAssertTrue(foreign.dropDelegate === listsOwn)
    }

    /// Through a real push and pop, each folder's list carries its own folder's drop target and no other.
    func testEachPushedFoldersListCarriesItsOwnDropTarget() async throws {
        var asked: String?, dropped: [String] = []
        func drop(_ name: String) -> FileDrop { FileDrop(accepts: { true }, targeted: { _ in asked = name }) { _ in dropped.append(name) } }
        let path = DropTargetPath()
        let window = try window(showing: UIHostingController(rootView: DropTargetStack(path: path, first: drop("first"), second: drop("second"))))
        // Every drop target on every list in the window belongs to the folder that list shows.
        func checkOwnership() {
            for list in views(UICollectionView.self, in: window) {
                if let target = target(on: list) {
                    asked = nil; target.drop?.targeted(true)
                    XCTAssertEqual(asked, rows(list) == 3 ? "first" : "second", "A list of \(rows(list)) rows")
                }
            }
        }
        func visibleTarget(rows count: Int) -> (list: UICollectionView, coordinator: FileDropTarget.Coordinator)? {
            for list in views(UICollectionView.self, in: window) where rows(list) == count && list.window != nil {
                if let target = target(on: list) { return (list, target) }
            }
            return nil
        }
        try await wait(for: "the first folder's drop target", within: Self.hostedView) { visibleTarget(rows: 3) != nil }
        let firstScreen = try XCTUnwrap(visibleTarget(rows: 3)?.coordinator.marker?.screen)
        checkOwnership()

        path.pushed = true
        try await wait(for: "the pushed folder's drop target", within: Self.hostedView) { checkOwnership(); return visibleTarget(rows: 7) != nil }
        for _ in 0..<40 { checkOwnership(); try await Task.sleep(for: .milliseconds(25)) }
        let second = try XCTUnwrap(visibleTarget(rows: 7))
        XCTAssertFalse(try XCTUnwrap(second.coordinator.marker?.screen) === firstScreen, "A pushed folder is a screen of its own, which is what bounds each target's search")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dropped-" + UUID().uuidString + ".bin")
        try Data([1]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let session = DropSession(items: [UIDragItem(itemProvider: try XCTUnwrap(NSItemProvider(contentsOf: file)))])
        XCTAssertTrue(second.coordinator.takes(session, on: second.list))
        second.coordinator.collectionView(second.list, performDropWith: DropCoordinator(session: session))
        XCTAssertEqual(dropped, ["second"])

        path.pushed = false
        for _ in 0..<40 { checkOwnership(); try await Task.sleep(for: .milliseconds(25)) }
        try await wait(for: "the first folder to take drops again after going back", within: Self.hostedView) {
            visibleTarget(rows: 3).map { $0.coordinator.takes(session, on: $0.list) } == true
        }
        let first = try XCTUnwrap(visibleTarget(rows: 3))
        first.coordinator.collectionView(first.list, performDropWith: DropCoordinator(session: session))
        XCTAssertEqual(dropped, ["second", "first"])
    }

    /// A lock, as UIKit reports it, passes through active for a few hundredths of a second on its way to the
    /// background. The window must end up in the background: left in front, it connects again with the
    /// device locked and its queues start what they should hold.
    func testALockThatPassesThroughActiveOnItsWayToTheBackgroundLeavesTheWindowInTheBackground() async throws {
        let service = HostService()
        let model = try await makeModel(service)
        let relay = ScenePhaseRelay()
        XCTAssertTrue(model.isForeground)
        XCTAssertEqual(model.transfers?.isForeground, true)
        let revision = model.sessionRevision

        relay.changed(to: .inactive, model: model)
        let blip = relay.changed(to: .active, model: model)
        relay.changed(to: .inactive, model: model)
        let left = relay.changed(to: .background, model: model)
        await left?.value; await blip?.value
        XCTAssertFalse(model.isForeground, "Becoming active was overtaken by the background and is not acted on.")
        XCTAssertEqual(model.transfers?.isForeground, false)
        XCTAssertEqual(model.downloads?.isForeground, false)
        XCTAssertEqual(model.sessionRevision, revision, "Nothing is asked to connect again.")

        // Unlocked: active for good, and acted on once the leaving has finished.
        relay.changed(to: .inactive, model: model)
        let back = relay.changed(to: .active, model: model)
        await back?.value
        XCTAssertTrue(model.isForeground)
        XCTAssertEqual(model.transfers?.isForeground, true)
        XCTAssertEqual(model.sessionRevision, revision + 1)

        // Active while it lasts is acted on: the Home Screen and straight back.
        let away = relay.changed(to: .background, model: model)
        let returned = relay.changed(to: .active, model: model)
        await away?.value; await returned?.value
        XCTAssertTrue(model.isForeground)
        XCTAssertEqual(model.transfers?.isForeground, true)
    }

    /// Two leavings and two returns in quick succession, the closing of the first leaving still under way
    /// when the second return arrives. The first return must not be acted on when the first closing ends,
    /// while the second is still closing; the second return is, once it has.
    func testAReturnOvertakenByAnotherLeavingWaitsForThatLeavingToFinish() async throws {
        let relay = ScenePhaseRelay()
        var log: [String] = []
        var gates: [String: CheckedContinuation<Void, Never>] = [:]
        func change(_ phase: ScenePhase, _ name: String) -> Task<Void, Never>? {
            relay.changed(to: phase, leave: { log.append("left \(name)") },
                          close: { await withCheckedContinuation { gates[name] = $0 }; log.append("closed \(name)") },
                          arrive: { log.append("arrived \(name)") })
        }
        func open(_ name: String) async throws {
            try await wait(for: "\(name) to be closing") { gates[name] != nil }
            gates.removeValue(forKey: name)?.resume()
        }
        let firstLeaving = change(.background, "1"), firstReturn = change(.active, "1")
        let secondLeaving = change(.background, "2"), secondReturn = change(.active, "2")
        try await wait(for: "1 to be closing") { gates["1"] != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(gates["2"], "The second closing does not begin while the first is under way.")
        XCTAssertEqual(log, ["left 1", "left 2"], "Both leavings were marked at once.")
        try await open("1")
        await firstLeaving?.value; await firstReturn?.value
        XCTAssertEqual(log, ["left 1", "left 2", "closed 1"], "The first return is not acted on: the window has left again and is still closing.")
        try await open("2")
        await secondLeaving?.value; await secondReturn?.value
        XCTAssertEqual(log, ["left 1", "left 2", "closed 1", "closed 2", "arrived 2"], "The return follows both closings.")

        // A return that nothing overtakes waits for the closing begun before it, and no longer.
        log = []
        let leaving = change(.background, "3"), returned = change(.active, "3")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log, ["left 3"], "Not acted on while the window is still closing.")
        try await open("3")
        await leaving?.value; await returned?.value
        XCTAssertEqual(log, ["left 3", "closed 3", "arrived 3"])
        // Becoming inactive after it, as when Control Centre is pulled down before its turn comes, overtakes it too.
        log = []
        let last = change(.background, "4"), back = change(.active, "4")
        _ = change(.inactive, "4")
        try await open("4")
        await last?.value; await back?.value
        XCTAssertEqual(log, ["left 4", "closed 4"])
        let again = change(.active, "5")
        await again?.value
        XCTAssertEqual(log, ["left 4", "closed 4", "arrived 5"])
    }

    /// What iOS is asked for as a transfer starts decides what it shows: a continued processing task puts a
    /// banner over an iPad's folder for as long as it runs, and the short time shows nothing.
    func testATransferOverInAMomentAsksForNoTaskAndHoldsTheShortTimeUntilItEnds() async throws {
        let queue = WatchedQueue(), system = ShortTime()
        let coordinator = system.coordinator()
        queue.start(completed: 0, remaining: BackgroundDownloadCoordinator.shortBytes - 1)
        coordinator.update(queue)
        XCTAssertEqual(system.asked, [], "Nothing is asked for that iOS would show.")
        XCTAssertEqual(system.begun, 1)
        XCTAssertTrue(coordinator.canContinue, "Left for the Home Screen or locked, the transfer has the short time to finish in.")
        // Progress is not a new transfer.
        queue.progress(completed: 1_000_000); coordinator.update(queue)
        XCTAssertEqual(system.begun, 1); XCTAssertEqual(system.ended, [])

        XCTAssertEqual(coordinator.status, "This transfer has a short time to finish in the background.")
        queue.end(succeeded: true); coordinator.update(queue)
        XCTAssertEqual(system.ended, [system.held], "The short time is given back as the transfer ends.")
        XCTAssertFalse(coordinator.canContinue)
        XCTAssertEqual(coordinator.status, "Transfers continue while the app is open.", "What was said of that transfer is not left on screen once it is over.")
        XCTAssertEqual(system.asked, [])
        XCTAssertEqual(queue.interruptions, [])
    }

    func testATransferWithMoreToMoveOrOfUnknownSizeAsksAsItStarts() async throws {
        for remaining in [BackgroundDownloadCoordinator.shortBytes, 4 << 30, nil] as [UInt64?] {
            let queue = WatchedQueue(), system = ShortTime()
            let coordinator = system.coordinator()
            queue.start(completed: 0, remaining: remaining)
            coordinator.update(queue)
            XCTAssertEqual(system.asked, [queue.activeID], "Asked at once, while the app is in front: \(String(describing: remaining))")
            XCTAssertEqual(system.begun, 0)
            queue.end(succeeded: true); coordinator.update(queue)
        }
        // A transfer that is retried with little left to move is a short one.
        let queue = WatchedQueue(), system = ShortTime()
        let coordinator = system.coordinator()
        queue.start(completed: 4 << 30, remaining: 1_000_000)
        coordinator.update(queue)
        XCTAssertEqual(system.asked, []); XCTAssertEqual(system.begun, 1)
        queue.end(succeeded: true); coordinator.update(queue)
    }

    /// Each look is two seconds after the last by the coordinator's clock, which the test moves.
    func testAShortTransferIsLookedAtAndAsksOnlyOnceItIsNotNearItsEndAtTheRateItHasKept() async throws {
        let queue = WatchedQueue(), system = ShortTime()
        let coordinator = system.coordinator()
        queue.start(completed: 0, remaining: 6_000_000)
        coordinator.update(queue)
        let started = await system.waiting(1)
        XCTAssertTrue(started, "A short transfer is looked at again.")

        // 2 MB in two seconds, 4 MB left: four seconds from its end. Left alone.
        queue.progress(completed: 2_000_000)
        var looking = await system.look()
        XCTAssertEqual(system.asked, [], "Looked at, moving, and near its end.")
        XCTAssertTrue(looking)
        XCTAssertEqual(system.waits, 2, "The look was made, and another is waited for.")
        // 2 MB more: two seconds from its end.
        queue.progress(completed: 4_000_000)
        looking = await system.look()
        XCTAssertEqual(system.asked, []); XCTAssertTrue(looking)
        // It slows: 100 KB in two seconds, 1.9 MB left, 38 seconds from its end. Asked for now.
        queue.progress(completed: 4_100_000)
        looking = await system.look()
        XCTAssertEqual(system.asked, [queue.activeID])
        XCTAssertFalse(looking, "Once asked for, it is not looked at again.")
        XCTAssertEqual(system.ended, [], "The short time is kept until iOS has started the task.")
        looking = await system.look()
        XCTAssertEqual(system.asked.count, 1, "Asked once.")
        queue.end(succeeded: true); coordinator.update(queue)
        XCTAssertEqual(system.ended, [system.held])
    }

    func testAShortTransferThatHasStoppedMovingAsksHoweverNearItsEndItIs() async throws {
        let queue = WatchedQueue(), system = ShortTime()
        let coordinator = system.coordinator()
        queue.start(completed: 0, remaining: 6_000_000)
        coordinator.update(queue)
        _ = await system.waiting(1)
        queue.progress(completed: 5_900_000)
        var looking = await system.look()
        XCTAssertEqual(system.asked, []); XCTAssertTrue(looking)
        // Nothing more has arrived by the next look.
        looking = await system.look()
        XCTAssertEqual(system.asked, [queue.activeID]); XCTAssertFalse(looking)
        queue.end(succeeded: true); coordinator.update(queue)
    }

    func testAShortTransferIsNotAskedForWhileTheAppIsAwayWhereIOSWouldRefuse() async throws {
        let queue = WatchedQueue(), system = ShortTime()
        let coordinator = system.coordinator()
        queue.start(completed: 0, remaining: 6_000_000)
        coordinator.update(queue)
        _ = await system.waiting(1)
        queue.isForeground = false
        var looking = await system.look()
        XCTAssertEqual(system.asked, [], "Not moving, but the app is away.")
        XCTAssertTrue(looking, "It goes on being looked at.")
        looking = await system.look()
        XCTAssertEqual(system.asked, []); XCTAssertTrue(looking)
        queue.isForeground = true
        looking = await system.look()
        XCTAssertEqual(system.asked, [queue.activeID], "Asked for at the first look with the app back in front.")
        queue.end(succeeded: true); coordinator.update(queue)
    }

    /// The case the short time costs: no task has been granted when the app is left, here because a look
    /// found the transfer near its end, and it then stops moving. Nothing can be asked for while the app is
    /// away, so when the short time runs out the transfer is interrupted.
    func testAShortTransferLeftAfterALookFoundItNearItsEndHasOnlyTheShortTime() async throws {
        let queue = WatchedQueue(), system = ShortTime()
        let coordinator = system.coordinator()
        queue.start(completed: 0, remaining: 6_000_000)
        coordinator.update(queue)
        _ = await system.waiting(1)
        queue.progress(completed: 5_000_000)
        var looking = await system.look()
        XCTAssertEqual(system.asked, []); XCTAssertTrue(looking)
        queue.isForeground = false
        looking = await system.look()
        looking = await system.look()
        XCTAssertEqual(system.asked, [], "Stopped moving, but nothing can be asked for with the app away.")
        XCTAssertTrue(coordinator.canContinue)
        system.expire()
        XCTAssertEqual(queue.interruptions, ["iOS stopped this background transfer. Retry to continue."])
        XCTAssertFalse(coordinator.canContinue)
    }

    func testWhenTheShortTimeRunsOutTheTransferIsInterruptedBeforeTheTimeIsGivenBack() async throws {
        let queue = WatchedQueue(), system = ShortTime()
        let coordinator = system.coordinator()
        queue.start(completed: 0, remaining: 6_000_000)
        coordinator.update(queue)
        _ = await system.waiting(1)
        queue.isForeground = false
        var interruptedByThen: [String]?
        system.onEnd = { interruptedByThen = queue.interruptions }
        system.expire()
        // All of it has happened by the time iOS's call returns: nothing here has been awaited.
        XCTAssertEqual(interruptedByThen, ["iOS stopped this background transfer. Retry to continue."],
                       "iOS may suspend the app once the time is given back, so the queue is put right first.")
        XCTAssertEqual(system.ended, [system.held])
        XCTAssertFalse(coordinator.canContinue)
        XCTAssertEqual(coordinator.status, "iOS stopped the background transfer. Retry the interrupted transfer when ready.")
        // The time of a transfer that has ended is not this one's to run out.
        system.expire()
        XCTAssertEqual(queue.interruptions.count, 1); XCTAssertEqual(system.ended.count, 1)
        let looking = await system.look()
        XCTAssertFalse(looking, "Nothing is looked at once the transfer has been stopped.")
        XCTAssertEqual(system.asked, [])
        // That iOS stopped it stays said until the next transfer starts.
        queue.isForeground = true
        queue.start(completed: 0, remaining: 1_000); coordinator.update(queue)
        XCTAssertEqual(coordinator.status, "This transfer has a short time to finish in the background.")
        queue.end(succeeded: true); coordinator.update(queue)
        XCTAssertEqual(coordinator.status, "Transfers continue while the app is open.")
    }

    /// A download that finishes with the device locked has all its bytes and waits for the unlock to be
    /// secured and listed as completed. Its background task is told it succeeded, not that it failed.
    func testADownloadReceivedWhileTheDeviceIsLockedIsItsTasksSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locked-download-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let service = DownloadingService(bytes: Data([1, 2, 3]))
        let manager = try DownloadManager(service: service, directory: directory)
        var unlocked = false
        manager.protectedDataAvailable = { unlocked }
        let id = try manager.enqueue(profile: first, entry: .init(name: "received.bin", path: "/srv/received.bin", kind: .file, size: 3))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .pendingFinalization)
        XCTAssertTrue(manager.transferSucceeded(id), "Every byte has arrived: the transfer did what its task was for.")
        unlocked = true
        manager.finalizePendingDownloads()
        XCTAssertEqual(manager.items.first?.state, .completed)
        XCTAssertTrue(manager.transferSucceeded(id))
        // One that failed is still a failure.
        await service.failNext()
        let failed = try manager.enqueue(profile: first, entry: .init(name: "lost.bin", path: "/srv/lost.bin", kind: .file, size: 3))
        try await wait { manager.activeID == nil }
        XCTAssertNotEqual(manager.items.first { $0.id == failed }?.state, .completed)
        XCTAssertFalse(manager.transferSucceeded(failed))
        XCTAssertFalse(manager.transferSucceeded(UUID()), "Nor is one the queue has never heard of.")
    }

    /// The same, with the upload queue itself: its row says interrupted, and is saved so, by the time the
    /// short time is given back.
    func testWhenTheShortTimeRunsOutOnAnUploadItsRowIsInterruptedBeforeTheTimeIsGivenBack() async throws {
        let service = HostService()
        let model = try await makeModel(service)
        let system = ShortTime(), coordinator = model.backgroundTransfers
        let real = (coordinator.beginShortTime, coordinator.endShortTime)
        addTeardownBlock { @MainActor in (coordinator.beginShortTime, coordinator.endShortTime) = real }
        var expired: (@MainActor () -> Void)?, given: [ManagedTransferState]?
        coordinator.beginShortTime = { _, handler in MainActor.assumeIsolated { expired = handler; return system.held } }
        coordinator.endShortTime = { _ in MainActor.assumeIsolated { given = model.transfers?.items.map(\.state) } }
        await service.hold("slow.txt")
        model.enqueueUploads([try file("slow.txt")], to: first, directory: "/srv")
        try await wait { await service.waiting == ["slow.txt"] }
        try await wait { model.transfers?.items.first?.state == .transferring }
        XCTAssertTrue(coordinator.canContinue, "A few bytes to send: the short time is held.")
        XCTAssertNotNil(expired)
        model.isForeground = false
        expired?()
        XCTAssertEqual(given, [.interrupted], "The row was interrupted when the short time was given back.")
        XCTAssertEqual(model.transfers?.items.first?.message, "iOS stopped this background transfer. Retry to continue.")
        XCTAssertFalse(coordinator.canContinue)
        await service.release("slow.txt")
        try await wait { model.transfers?.activeID == nil }
        XCTAssertEqual(model.transfers?.items.map(\.state), [.interrupted])
    }

    func testOneTransferEndingAndTheNextStartingGivesBackTheFirstsShortTimeBeforeTakingTheSeconds() async throws {
        let queue = WatchedQueue(), system = ShortTime()
        let coordinator = system.coordinator()
        queue.start(completed: 0, remaining: 1_000)
        coordinator.update(queue)
        // The queue reports both changes at once.
        queue.end(succeeded: true); queue.start(completed: 0, remaining: 2_000)
        coordinator.update(queue)
        XCTAssertEqual(system.log, ["taken", "given back", "taken"])
        XCTAssertTrue(coordinator.canContinue)
        // Disconnect ends whatever is held, and a row retried under the id it had is a transfer like any other.
        let id = try XCTUnwrap(queue.activeID)
        coordinator.finish(success: false)
        XCTAssertEqual(system.log, ["taken", "given back", "taken", "given back"])
        XCTAssertFalse(coordinator.canContinue)
        queue.end(succeeded: false); coordinator.update(queue)
        XCTAssertEqual(system.log.count, 4, "Nothing is given back twice.")
        queue.start(id, completed: 500, remaining: 1_500)
        coordinator.update(queue)
        XCTAssertEqual(system.log, ["taken", "given back", "taken", "given back", "taken"])
        XCTAssertEqual(system.asked, [])
        queue.end(succeeded: true); coordinator.update(queue)
        XCTAssertEqual(system.log.count, 6)
    }

    func testWhereIOSGivesNoShortTimeAShortTransferAsksForATask() async throws {
        let queue = WatchedQueue(), system = ShortTime()
        system.held = .invalid
        let coordinator = system.coordinator()
        queue.start(completed: 0, remaining: 1_000)
        coordinator.update(queue)
        XCTAssertEqual(system.asked, [queue.activeID])
        XCTAssertEqual(system.ended, [])
        queue.end(succeeded: true); coordinator.update(queue)
    }

    func testEditingOrRemovingAConnectionStopsOnlyTheTransfersThatUseIt() async throws {
        let service = HostService()
        let model = try await makeModel(service)
        await service.hold("held.bin")
        model.enqueueUploads([try file("held.bin")], to: first, directory: "/srv")
        model.enqueueUploads([try file("other.bin")], to: second, directory: "/data")
        try await wait { await service.waiting == ["held.bin"] }

        var edited = first; edited.host = "moved.invalid"
        await model.saveConnection(edited)
        let stopped = try XCTUnwrap(model.transfers?.items.first)
        XCTAssertEqual(stopped.state, .interrupted)
        XCTAssertEqual(stopped.message, AppModel.changedConnectionTransferMessage)
        try await wait { model.transfers?.items.last?.state == .completed }
        // Made for the connection as it was, it can't be sent over the connection as it is.
        model.retryTransfer(stopped)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.transfers?.items.first?.state, .interrupted)
        model.errorMessage = nil

        // A removed connection takes its transfers with it; the other's stay.
        await model.removeConnection(second)
        // The queue lets go of a transfer it has just finished a moment after marking it finished.
        try await wait(for: "the removed connection's transfer to go") { model.transfers?.items.map(\.filename) == ["held.bin"] }
        XCTAssertEqual(model.transfers(using: edited).count, 1)
    }
}

/// Two folders' worth of list, the second pushed over the first, each with a drop target of its own.
private final class DropTargetPath: ObservableObject { @Published var pushed = false }
private struct DropTargetStack: View {
    @ObservedObject var path: DropTargetPath
    let first: FileDrop, second: FileDrop
    var body: some View {
        NavigationStack {
            List(0..<3, id: \.self) { Text("first \($0)") }.background(FileDropTarget(drop: first))
                .navigationDestination(isPresented: $path.pushed) {
                    List(0..<7, id: \.self) { Text("second \($0)") }.background(FileDropTarget(drop: second))
                }
        }
    }
}

/// A list's own drop delegate, as SwiftUI's is: it forbids every drop, and notes what it is asked.
@MainActor private final class OwnDelegate: NSObject, UICollectionViewDropDelegate {
    var asked: [String] = []
    func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool { asked.append("canHandle"); return true }
    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession,
                        withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        asked.append("update"); return UICollectionViewDropProposal(operation: .forbidden)
    }
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) { asked.append("perform") }
}

/// What a collection view hands its drop delegate when a drag is let go over it. Only the session is used.
private final class DropCoordinator: NSObject, UICollectionViewDropCoordinator {
    let session: any UIDropSession
    init(session: any UIDropSession) { self.session = session }
    var items: [any UICollectionViewDropItem] { [] }
    var destinationIndexPath: IndexPath? { nil }
    var proposal: UICollectionViewDropProposal { UICollectionViewDropProposal(operation: .copy) }
    func drop(_ dragItem: UIDragItem, to placeholder: UICollectionViewDropPlaceholder) -> any UICollectionViewDropPlaceholderContext { fatalError("Not used") }
    func drop(_ dragItem: UIDragItem, toItemAt indexPath: IndexPath) -> any UIDragAnimating { fatalError("Not used") }
    func drop(_ dragItem: UIDragItem, intoItemAt indexPath: IndexPath, rect: CGRect) -> any UIDragAnimating { fatalError("Not used") }
    func drop(_ dragItem: UIDragItem, to target: UIDragPreviewTarget) -> any UIDragAnimating { fatalError("Not used") }
}

/// A drag session as UIKit hands one to a drop interaction, holding the given items.
private final class DropSession: NSObject, UIDropSession {
    let items: [UIDragItem]
    init(items: [UIDragItem]) { self.items = items }
    let progress = Progress()
    var localDragSession: (any UIDragSession)? { nil }
    var progressIndicatorStyle = UIDropSessionProgressIndicatorStyle.none
    var allowsMoveOperation: Bool { false }
    var isRestrictedToDraggingApplication: Bool { false }
    func location(in view: UIView) -> CGPoint { .zero }
    func hasItemsConforming(toTypeIdentifiers identifiers: [String]) -> Bool {
        items.contains { item in identifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) } }
    }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool { items.contains { $0.itemProvider.canLoadObject(ofClass: aClass) } }
    func loadObjects(ofClass aClass: any NSItemProviderReading.Type, completion: @escaping ([any NSItemProviderReading]) -> Void) -> Progress {
        completion([]); return Progress()
    }
}
#endif
