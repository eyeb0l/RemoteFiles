#if os(iOS)
import SwiftUI
import UIKit
import XCTest
import RemoteFilesCore
@testable import RemoteFilesUI

/// Answers listings at once, or holds one folder until released, and records what it was asked.
private actor CountingFolderService: RemoteFileService {
    private(set) var listed: [String] = []
    private(set) var cancelled: [String] = []
    private var held: String?
    private var release: CheckedContinuation<Void, Never>?
    private var failing: String?
    func fail(_ path: String) { failing = path }
    func hold(_ path: String) { held = path }
    func releaseHeld() { release?.resume(); release = nil; held = nil }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        listed.append(path)
        if path == held { await withCheckedContinuation { release = $0 } }
        if Task.isCancelled { cancelled.append(path); throw CancellationError() }
        if path == failing { throw RemoteFileError.unavailable("Refused") }
        return .init(path: path, entries: [])
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
    private var heldRead: CheckedContinuation<Void, Never>?
    private var holdsReads = false
    private(set) var readsWaiting = 0
    func holdReads() { holdsReads = true }
    func releaseReads() { holdsReads = false; heldRead?.resume(); heldRead = nil }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        if holdsReads { readsWaiting += 1; await withCheckedContinuation { heldRead = $0 } }
        return Data("# Report".utf8)
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unavailable("Not used")
    }
    func disconnect() async {}
}

@MainActor private final class SourceFixtureState: ObservableObject {
    @Published var unrelated = 0
    @Published var text: String
    init(text: String) { self.text = text }
}

private struct SourceFixture: View {
    @ObservedObject var state: SourceFixtureState
    var body: some View {
        // Reading `unrelated` re-evaluates this body, as Find does for the reader around the text. A new
        // closure each time is what makes SwiftUI update the representable, as in the real reader.
        let revision = state.unrelated
        BoundedSourceTextView(text: state.text, highlighted: nil, readingPosition: nil, onReveal: { _ in _ = revision })
    }
}

@MainActor final class ResponsivenessTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "fixture", identityID: UUID(), startingDirectory: "/p")

    private func model(_ service: CountingFolderService) throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try AppModel(directory: directory, fileService: service), directory)
    }
    private func listing(_ folders: [String], path: String = "/p") -> FolderListing {
        FolderListing(DirectorySnapshot(path: path, entries: folders.map { .init(name: $0, path: path + "/" + $0, kind: .directory) }))
    }
    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Condition not met in time"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testByteIdentityTellsCanonicallyEquivalentTextApart() {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift's == folds these, which is why bytes are compared")
        XCTAssertFalse(sameBytes(composed, decomposed))
        XCTAssertNotEqual(ExactText(text: composed), ExactText(text: decomposed))
        let large = String(repeating: "report ", count: 100_000)
        XCTAssertTrue(sameBytes(large, large))
        var edited = large
        edited.removeLast(); edited.append("!")
        XCTAssertFalse(sameBytes(large, edited))
        XCTAssertTrue(sameBytes(large, String(decoding: Array(large.utf8), as: UTF8.self)), "Separate storage still compares by content")
    }

    func testPlainFoldersShowOnlyTheirNameButStillSayWhatTheyAre() {
        let folder = FolderRow(.init(name: "Reports", path: "/p/Reports", kind: .directory))
        XCTAssertNil(folder.visibleSubtitle)
        XCTAssertEqual(folder.subtitle, "Folder")
        let file = FolderRow(.init(name: "a.md", path: "/p/a.md", kind: .file, size: 2_048))
        XCTAssertEqual(file.visibleSubtitle, file.subtitle)
        XCTAssertEqual(FileSymbol.name(forFilename: "main.swift"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(FileSymbol.name(forFilename: "backup.tar"), "archivebox")
        XCTAssertEqual(FileSymbol.name(forFilename: "notes.txt"), "doc.text")
    }

    func testSourceViewBuildsItsTextOncePerRealChange() async throws {
        let state = SourceFixtureState(text: String(repeating: "A line of source\n", count: 4_000))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SourceFixture(state: state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func sourceView() -> SourceTextView? {
            func find(_ view: UIView) -> SourceTextView? {
                (view as? SourceTextView) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(window)
        }
        func builds() -> Int { (sourceView()?.delegate as? BoundedSourceTextView.Coordinator)?.contentBuilds ?? 0 }
        try await waitUntil { builds() > 0 }
        let settled = builds()
        for value in 1...5 {
            state.unrelated = value
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(builds(), settled, "Updates that change nothing in the text must not rebuild it")
        state.text += "One more line\n"
        try await waitUntil { sourceView()?.attributedText.string.hasSuffix("One more line\n") == true }
        XCTAssertEqual(builds(), settled + 1)
    }

    /// The scroll offset is saved as the document scrolls. Nothing on screen shows it, so saving it
    /// must not build the document's content again: that is every paragraph, on every frame.
    func testScrollingARenderedDocumentDoesNotBuildItsContentAgain() async throws {
        let text = (1...300).map { "## Section \($0)\n\nParagraph \($0) of a long report, with a [link](other.md) and enough words to wrap.\n" }.joined(separator: "\n")
        let position = DocumentReadingPosition()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: DocumentContentView(
            text: text, markdown: true, source: false, readingPosition: position, openDocumentLink: { _ in }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func scrollView() -> UIScrollView? {
            func find(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height * 3 { return scroll }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(window)
        }
        try await waitUntil { scrollView() != nil }
        let scroll = try XCTUnwrap(scrollView())
        // Let preparation, first layout and deferred rendering settle before counting.
        var settled = -1
        try await waitUntil {
            let builds = position.renderedContentBuilds
            defer { settled = builds }
            try? await Task.sleep(for: .milliseconds(300))
            return builds == settled && builds == position.renderedContentBuilds
        }
        let before = position.renderedContentBuilds
        for step in 1...40 {
            scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(step) * 60), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await waitUntil { position.rendered.y > 1_000 }
        XCTAssertGreaterThan(position.rendered.y, 1_000, "The offset is still tracked for saving")
        print("Rendered content builds over forty scroll steps: \(position.renderedContentBuilds - before)")
        XCTAssertLessThanOrEqual(position.renderedContentBuilds - before, 4,
                                 "Forty scroll steps built the content \(position.renderedContentBuilds - before) times")
    }

    func testPrefetchListsLeadingSubfoldersOnceAndFillsTheCache() async throws {
        let service = CountingFolderService()
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folders = (1...9).map { "Folder \($0)" } + [".hidden"]
        let shown = listing(folders)
        model.noteForegroundConnection(profile.id)
        model.prefetchFolders(in: shown, profile: profile)
        try await waitUntil { model.cachedListing(self.profile.id, path: "/p/Folder 6") != nil }
        let listed = await service.listed
        XCTAssertEqual(listed.count, 6, "Prefetch is bounded")
        XCTAssertFalse(listed.contains("/p/.hidden"), "Hidden folders aren't prefetched")
        XCTAssertTrue(model.isListingFresh(profile.id, path: "/p/Folder 1"))
        // Nothing listed moments ago is asked for again.
        model.prefetchFolders(in: shown, profile: profile)
        try await waitUntil { await service.listed.count >= 9 }
        let again = await service.listed
        XCTAssertEqual(again.count, 9, "Only folders not already remembered are listed")
        model.prefetchFolders(in: shown, profile: profile)
        try await Task.sleep(for: .milliseconds(50))
        let unchanged = await service.listed
        XCTAssertEqual(unchanged.count, 9, "Remembered folders are checked when opened, not ahead of time")
        XCTAssertEqual(Set(again).count, again.count)
    }

    func testAnotherFolderReplacesWaitingPrefetchesWithoutCancellingTheOneInFlight() async throws {
        let service = CountingFolderService()
        await service.hold("/p/A")
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.noteForegroundConnection(profile.id)
        model.prefetchFolders(in: listing(["A", "B", "C"]), profile: profile)
        try await waitUntil { await service.listed == ["/p/A"] }
        model.prefetchFolders(in: listing(["X"], path: "/q"), profile: profile)
        await service.releaseHeld()
        try await waitUntil { model.cachedListing(self.profile.id, path: "/q/X") != nil }
        let listed = await service.listed, cancelled = await service.cancelled
        XCTAssertEqual(listed, ["/p/A", "/q/X"], "Folders still waiting were replaced")
        XCTAssertTrue(cancelled.isEmpty, "Cancelling a listing in flight would retire the shared SFTP channel")
        XCTAssertNotNil(model.cachedListing(profile.id, path: "/p/A"))
    }

    func testPrefetchStopsWhenTheSessionEnds() async throws {
        let service = CountingFolderService()
        await service.hold("/p/A")
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.noteForegroundConnection(profile.id)
        model.prefetchFolders(in: listing(["A", "B"]), profile: profile)
        try await waitUntil { await service.listed == ["/p/A"] }
        let disconnect = Task { await model.disconnectAndGoHome() }
        await service.releaseHeld()
        await disconnect.value
        XCTAssertNil(model.cachedListing(profile.id, path: "/p/A"), "A listing finishing after Disconnect must not be remembered")
        let listed = await service.listed
        XCTAssertEqual(listed, ["/p/A"], "No further folder is listed once disconnected")
    }

    func testOpeningAnotherServerStopsPrefetchForTheFirstImmediately() async throws {
        let service = CountingFolderService()
        await service.hold("/p/A")
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.noteForegroundConnection(profile.id)
        model.prefetchFolders(in: listing(["A", "B", "C"]), profile: profile)
        try await waitUntil { await service.listed == ["/p/A"] }
        model.noteForegroundConnection(UUID())
        await service.releaseHeld()
        try await waitUntil { model.cachedListing(self.profile.id, path: "/p/A") == nil }
        try await Task.sleep(for: .milliseconds(50))
        let listed = await service.listed
        XCTAssertEqual(listed, ["/p/A"], "Listing the first server again would close the session of the one on screen")
        XCTAssertNil(model.cachedListing(profile.id, path: "/p/A"))
    }

    func testAFailedPrefetchStopsAndLeavesTheRestUnlisted() async throws {
        let service = CountingFolderService()
        await service.fail("/p/A")
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.noteForegroundConnection(profile.id)
        model.prefetchFolders(in: listing(["A", "B", "C"]), profile: profile)
        try await waitUntil { await service.listed == ["/p/A"] }
        try await Task.sleep(for: .milliseconds(50))
        let listed = await service.listed
        XCTAssertEqual(listed, ["/p/A"], "A server that refuses isn't asked five more times")
    }

    func testAFailedHostKeyForgetsWhatWasSeenThroughThatConnection() async throws {
        let service = CountingFolderService()
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = UUID()
        model.cache(listing([]), id: profile.id, requestedPath: "/p")
        model.cache(listing([]), id: other, requestedPath: "/p")
        model.cache(Data("report".utf8), id: profile.id, path: "/p/report.md")
        model.cache(Data("report".utf8), id: other, path: "/p/report.md")
        let generation = model.listingGeneration(profile.id)
        model.handle(HostTrustError.invalidStore, profile: profile)
        XCTAssertNil(model.cachedListing(profile.id, path: "/p"))
        XCTAssertNil(model.cachedDocument(profile.id, path: "/p/report.md"))
        XCTAssertNotEqual(model.listingGeneration(profile.id), generation, "Anything still on its way is discarded when it lands")
        XCTAssertNotNil(model.cachedListing(other, path: "/p"))
        XCTAssertNotNil(model.cachedDocument(other, path: "/p/report.md"))
        model.handle(RemoteFileError.unavailable("Offline"), profile: .init(name: "Other", host: "other.invalid", username: "u", identityID: UUID()))
        let unchanged = model.listingGeneration(profile.id)
        model.handle(RemoteDocumentLinkError.outsideConnection, profile: profile)
        XCTAssertEqual(model.listingGeneration(profile.id), unchanged, "A path outside its boundary says nothing about the connection")
        XCTAssertNotNil(model.cachedListing(other, path: "/p"), "An ordinary failure leaves remembered folders alone")
    }

    func testAPrefetchFinishingLateDoesNotReplaceWhatOpeningTheFolderFound() async throws {
        let service = CountingFolderService()
        await service.hold("/p/A")
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.noteForegroundConnection(profile.id)
        model.prefetchFolders(in: listing(["A", "B"]), profile: profile)
        try await waitUntil { await service.listed == ["/p/A"] }
        // The folder is opened while its prefetch is still on the way, and the newer listing arrives first.
        model.cache(listing(["Newer"], path: "/p/A"), id: profile.id, requestedPath: "/p/A")
        await service.releaseHeld()
        try await waitUntil { model.cachedListing(self.profile.id, path: "/p/B") != nil }
        XCTAssertEqual(model.cachedListing(profile.id, path: "/p/A")?.defaultRows.map(\.entry.name), ["Newer"])
    }

    func testAListingFinishingAfterAFailedHostKeyIsNotRemembered() async throws {
        let service = CountingFolderService()
        await service.hold("/p/A")
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.noteForegroundConnection(profile.id)
        model.prefetchFolders(in: listing(["A", "B"]), profile: profile)
        try await waitUntil { await service.listed == ["/p/A"] }
        model.handle(HostTrustError.invalidStore, profile: profile)
        await service.releaseHeld()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.cachedListing(profile.id, path: "/p/A"))
        let listed = await service.listed
        XCTAssertEqual(listed, ["/p/A"], "Nothing more is listed through a connection that failed verification")
    }

    func testAReadFinishingAfterAFailedHostKeyIsNotPublished() async throws {
        let service = CountingFolderService()
        await service.holdReads()
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.metadata.connections = [profile]
        let entry = RemoteEntry(name: "report.md", path: "/p/report.md", kind: .file)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ReaderView(model: model, profile: profile, entry: entry) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await waitUntil { await service.readsWaiting == 1 }
        model.handle(HostTrustError.invalidStore, profile: profile)
        await service.releaseReads()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.cachedDocument(profile.id, path: entry.path), "What was read through a connection that failed verification isn't kept")
        XCTAssertTrue(model.metadata.recents.isEmpty)
        XCTAssertNotEqual(model.connectionStates[profile.id], "Connected")
    }

    func testReturningFromADiscardedRevisionKeepsTheDocumentsPlace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReadingPositionStore(fileURL: directory.appendingPathComponent("positions.json"))
        let position = DocumentReadingPosition(), id = UUID(), path = "/p/report.md"
        let kept = "# Kept", discarded = "# Discarded"
        await position.prepare(text: kept, store: store, connectionID: id, path: path)
        position.rendered = CGPoint(x: 0, y: 640)
        await position.prepare(text: discarded, store: store, connectionID: id, path: path)
        XCTAssertEqual(position.rendered, .zero, "A different revision starts at the top")
        await position.prepare(text: kept, store: store, connectionID: id, path: path, discardingCurrent: true)
        XCTAssertEqual(position.rendered.y, 640, "The document on screen keeps its place")
        let saved = await store.restore(connectionID: id, path: path, revision: SavedReadingPosition.revision(for: kept))
        XCTAssertEqual(saved?.rendered.y, 640)
    }

    func testOpeningAnotherServerClearsTheFirstServersState() throws {
        let service = CountingFolderService()
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.noteForegroundConnection(profile.id)
        model.connectionStates[profile.id] = "Connected"
        model.noteForegroundConnection(profile.id)
        XCTAssertEqual(model.connectionStates[profile.id], "Connected")
        model.noteForegroundConnection(UUID())
        XCTAssertNil(model.connectionStates[profile.id], "Its session closed, so Home must not still show it connected")
    }

    func testBackgroundKeepsFolderNamesButNotDocumentsAndDisconnectForgetsBoth() async throws {
        let service = CountingFolderService()
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.cache(listing([]), id: profile.id, requestedPath: "/p")
        model.cache(Data("report".utf8), id: profile.id, path: "/p/report.md")
        model.isForeground = false
        await model.background()
        XCTAssertNotNil(model.cachedListing(profile.id, path: "/p"), "Returning shows the folder at once while it reconnects")
        XCTAssertFalse(model.isListingFresh(profile.id, path: "/p"), "What's kept is checked with the server when next shown")
        XCTAssertNil(model.cachedDocument(profile.id, path: "/p/report.md"))
        model.isForeground = true
        await model.disconnectAndGoHome()
        XCTAssertNil(model.cachedListing(profile.id, path: "/p"), "Disconnect forgets what was browsed")
    }

    /// Two names that differ only in Unicode normalisation are two folders on the server.
    func testListingsOfNamesThatDifferOnlyInNormalisationAreRememberedApart() throws {
        let service = CountingFolderService()
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        let composed = "/p/caf\u{E9}", decomposed = "/p/cafe\u{301}"
        model.cache(listing(["one"], path: composed), id: profile.id, requestedPath: composed)
        XCTAssertNil(model.cachedListing(profile.id, path: decomposed), "The other folder's rows must not be shown for it")
        model.cache(listing(["two"], path: decomposed), id: profile.id, requestedPath: decomposed)
        XCTAssertEqual(model.cachedListing(profile.id, path: composed)?.rows.map(\.entry.name), ["one"])
        XCTAssertEqual(model.cachedListing(profile.id, path: decomposed)?.rows.map(\.entry.name), ["two"])
    }

    func testListingCacheBoundsFoldersAndNames() throws {
        let service = CountingFolderService()
        let (model, directory) = try model(service)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<(AppModel.listingLimit + 5) {
            model.cache(listing([]), id: profile.id, requestedPath: "/p/\(index)")
        }
        XCTAssertNil(model.cachedListing(profile.id, path: "/p/0"), "The oldest folder goes first")
        XCTAssertNotNil(model.cachedListing(profile.id, path: "/p/\(AppModel.listingLimit + 4)"))
        let huge = FolderListing(DirectorySnapshot(path: "/huge", entries: (0..<30_000).map { .init(name: "f\($0)", path: "/huge/f\($0)", kind: .file) }))
        model.cache(huge, id: profile.id, requestedPath: "/huge")
        model.cache(huge, id: profile.id, requestedPath: "/huge2")
        XCTAssertNil(model.cachedListing(profile.id, path: "/huge"), "Large listings give way before the total grows without limit")
        XCTAssertNotNil(model.cachedListing(profile.id, path: "/huge2"))

        // A server chooses how long a name is, so a few rows can be as large as many thousands.
        func long(_ path: String) -> FolderListing {
            FolderListing(DirectorySnapshot(path: path, entries: (0..<5).map {
                let name = String(repeating: "n", count: 1_024 * 1_024) + String($0)
                return .init(name: name, path: path + "/" + name, kind: .file)
            }))
        }
        model.cache(listing(["a"]), id: profile.id, requestedPath: "/small")
        model.cache(long("/long"), id: profile.id, requestedPath: "/long")
        XCTAssertNotNil(model.cachedListing(profile.id, path: "/small"), "About 10 MiB of names fits")
        model.cache(long("/long2"), id: profile.id, requestedPath: "/long2")
        XCTAssertNil(model.cachedListing(profile.id, path: "/small"))
        XCTAssertNil(model.cachedListing(profile.id, path: "/long"), "Twice that is over the byte limit, so the older listings go")
        XCTAssertNotNil(model.cachedListing(profile.id, path: "/long2"), "The newest always stays")
    }
}
#endif
