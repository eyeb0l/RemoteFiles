import XCTest
import Foundation
@testable import RemoteFilesCore

/// Folders from a dictionary; records listings and how many overlap, and can slow any folder or
/// fail it always or only the first time.
actor TreeService: RemoteFileService {
    private let folders: [String: [RemoteEntry]]
    private let failures: [String: RemoteFileError]
    private var failOnce: [String: RemoteFileError]
    private let delay: Duration
    private let delays: [String: Duration]
    private let gates: [String: ListingGate]
    private(set) var listed: [String] = []
    private(set) var mostAtOnce = 0
    private var running = 0
    init(_ folders: [String: [RemoteEntry]], failures: [String: RemoteFileError] = [:], failOnce: [String: RemoteFileError] = [:],
         delay: Duration = .zero, delays: [String: Duration] = [:], gates: [String: ListingGate] = [:]) {
        self.folders = folders; self.failures = failures; self.failOnce = failOnce; self.delay = delay; self.delays = delays
        self.gates = gates
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        listed.append(path)
        running += 1; mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1 }
        let pause = delays[path] ?? delay
        if pause > .zero { try await Task.sleep(for: pause) }
        if let gate = gates[path] { await gate.wait() }
        if let failure = failOnce.removeValue(forKey: path) ?? failures[path] { throw failure }
        guard let entries = folders[path] else { throw RemoteFileError.notFound }
        return DirectorySnapshot(path: path, entries: entries)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}

/// Holds a folder's listing until the test lets it through.
actor ListingGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

final class FolderSearchTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Search", host: "example.invalid", username: "reader", identityID: UUID())

    private func file(_ path: String) -> RemoteEntry { RemoteEntry(name: RemotePath.name(of: path), path: path, kind: .file) }
    private func folder(_ path: String) -> RemoteEntry { RemoteEntry(name: RemotePath.name(of: path), path: path, kind: .directory) }

    private func search(_ service: TreeService, _ query: String, includeHidden: Bool = false,
                        limits: RemoteFolderSearch.Limits = .init()) async throws -> (paths: [String], final: RemoteFolderSearch.Update) {
        var paths: [String] = [], final: RemoteFolderSearch.Update?
        for try await update in RemoteFolderSearch.names(matching: query, below: "/r", profile: profile, service: service,
                                                         includeHidden: includeHidden, limits: limits) {
            XCTAssertNil(final, "Nothing follows the final update")
            paths += update.matches.map(\.path)
            if update.isFinished { final = update }
        }
        return (paths, try XCTUnwrap(final))
    }

    func testFindsNamesAtEveryDepthWithoutFollowingLinksOrHiddenFolders() async throws {
        let service = TreeService([
            "/r": [file("/r/Needle.md"), folder("/r/a"), folder("/r/.cache"), file("/r/notes.txt"),
                   RemoteEntry(name: "needle link", path: "/r/needle link", kind: .symlink, link: .target(folder("/r/a")))],
            "/r/a": [folder("/r/a/b"), file("/r/a/other.txt"), file("/r/a/a-needle.txt")],
            "/r/a/b": [file("/r/a/b/deep NEEDLE.swift")],
            "/r/.cache": [file("/r/.cache/needle-hidden.txt")]
        ])
        let result = try await search(service, "needle")
        XCTAssertEqual(result.paths, ["/r/needle link", "/r/Needle.md", "/r/a/a-needle.txt", "/r/a/b/deep NEEDLE.swift"],
                       "Case-insensitive, nearest folders first, sorted by name within a folder")
        XCTAssertEqual(result.final.foldersSearched, 3)
        XCTAssertNil(result.final.stop)
        let listed = await service.listed
        XCTAssertEqual(listed, ["/r", "/r/a", "/r/a/b"], "A link to a folder is matched but never listed, and hidden folders are skipped")

        let withHidden = try await search(TreeService([
            "/r": [folder("/r/.cache")], "/r/.cache": [file("/r/.cache/needle-hidden.txt"), file("/r/.cache/.needle")]
        ]), "needle", includeHidden: true)
        XCTAssertEqual(withHidden.paths, ["/r/.cache/.needle", "/r/.cache/needle-hidden.txt"])
    }

    /// A backslash is an ordinary byte in a name on the server, as in a file copied from Windows.
    func testNamesHoldingABackslashAreFoundAndTheirFoldersSearched() async throws {
        let service = TreeService([
            "/r": [file("/r/C:\\needle.txt"), folder("/r/dir\\name")],
            "/r/dir\\name": [file("/r/dir\\name/a\\..\\needle")]
        ])
        let result = try await search(service, "needle")
        XCTAssertEqual(result.paths, ["/r/C:\\needle.txt", "/r/dir\\name/a\\..\\needle"])
        XCTAssertEqual(result.final.foldersSearched, 2)
    }

    func testNewlyDiscoveredFoldersAreConsumedAfterTheLastListingFinishes() async throws {
        var tree: [String: [RemoteEntry]] = [:], expected: [String] = []
        var path = "/r"
        for depth in 0..<12 {
            let match = path + "/needle.txt", child = path + "/next"
            expected.append(match)
            tree[path] = [file(match)] + (depth < 11 ? [folder(child)] : [])
            path = child
        }
        for window in [1, 4] {
            let service = TreeService(tree)
            let result = try await search(service, "needle", limits: .init(concurrentListings: window, concurrentListingLimit: window))
            XCTAssertEqual(result.paths, expected, "A completed listing can discover more work even when no peer listing remains")
            XCTAssertEqual(result.final.foldersSearched, tree.count)
            XCTAssertNil(result.final.stop)
            let listed = await service.listed
            XCTAssertEqual(Set(listed), Set(tree.keys))
            XCTAssertEqual(listed.count, tree.count, "Every discovered folder is listed exactly once")
        }
    }

    func testUnreadableSubfoldersAreCountedWhileConnectionAndStartingFolderFailuresEndTheSearch() async throws {
        let tree = ["/r": [folder("/r/locked"), folder("/r/gone"), folder("/r/slow"), folder("/r/ok"), file("/r/needle.txt")],
                    "/r/ok": [file("/r/ok/needle-2.txt")]]
        let result = try await search(TreeService(tree, failures: ["/r/locked": .permissionDenied, "/r/slow": .timedOut]), "needle")
        XCTAssertEqual(result.paths, ["/r/needle.txt", "/r/ok/needle-2.txt"])
        XCTAssertEqual(result.final.foldersSearched, 2)
        XCTAssertEqual(result.final.unreadableFolders, 3, "Permission, a folder removed meanwhile, and a timeout")

        let flaky = TreeService(tree, failOnce: ["/r/ok": .connectionEnded])
        let retried = try await search(flaky, "needle")
        XCTAssertEqual(retried.paths, ["/r/needle.txt", "/r/ok/needle-2.txt"],
                       "A listing failed by a peer's timeout retiring the shared channel is listed again")
        XCTAssertEqual(retried.final.unreadableFolders, 3, "Only the folders that are missing; the retried one was found")
        let flakyListings = await flaky.listed
        XCTAssertEqual(flakyListings.filter { $0 == "/r/ok" }.count, 2)
        do {
            _ = try await search(TreeService(tree, failures: ["/r/ok": .connectionEnded]), "needle")
            XCTFail("A connection that stays ended must not look like an unreadable folder")
        } catch RemoteFileError.connectionEnded { }
        do {
            _ = try await search(TreeService(tree, failures: ["/r": .permissionDenied]), "needle")
            XCTFail("The starting folder must be readable")
        } catch RemoteFileError.permissionDenied { }
    }

    func testNearerFoldersAreReportedAndCountedFirstWhateverTheirListingSpeed() async throws {
        let tree = [
            "/r": [folder("/r/slow"), folder("/r/fast")],
            "/r/slow": [file("/r/slow/needle-near")],
            "/r/fast": [folder("/r/fast/deep")],
            "/r/fast/deep": (0..<5).map { file("/r/fast/deep/needle-\($0)") }
        ]
        let service = TreeService(tree, delays: ["/r/slow": .milliseconds(300)])
        let result = try await search(service, "needle", limits: .init(maxMatches: 3))
        let listed = await service.listed
        XCTAssertTrue(listed.contains("/r/fast/deep"), "The deep folder was listed while the slow one was still pending")
        XCTAssertEqual(result.paths, ["/r/slow/needle-near", "/r/fast/deep/needle-0", "/r/fast/deep/needle-1"],
                       "The nearer folder's match comes first and is not crowded out by the deeper folder")
        XCTAssertEqual(result.final.stop, .matchLimit)
    }

    func testConnectionRecoveryDoesNotStartAListingAfterTheSearchDeadline() async throws {
        let service = TreeService([
            "/r": [file("/r/needle-kept"), folder("/r/interrupted")],
            "/r/interrupted": [file("/r/interrupted/needle-late")]
        ], failOnce: ["/r/interrupted": .connectionEnded], delays: ["/r/interrupted": .seconds(2)])
        let result = try await search(service, "needle", limits: .init(timeLimit: .seconds(1)))
        let listed = await service.listed
        XCTAssertEqual(listed, ["/r", "/r/interrupted"], "Recovery is a new listing and must respect the same deadline")
        XCTAssertEqual(result.paths, ["/r/needle-kept"], "Keep matches reported before recovery ran out of time")
        XCTAssertEqual(result.final.stop, .timeLimit)
        XCTAssertEqual(result.final.foldersSearched, 1)
        XCTAssertEqual(result.final.unreadableFolders, 0, "An interrupted listing is not an unreadable folder")
    }

    func testLimitsStopTheWalkAndKeepWhatWasFound() async throws {
        let chain = TreeService([
            "/r": [file("/r/needle-0"), folder("/r/1")], "/r/1": [file("/r/1/needle-1"), folder("/r/1/2")],
            "/r/1/2": [file("/r/1/2/needle-2"), folder("/r/1/2/3")], "/r/1/2/3": [file("/r/1/2/3/needle-3")]
        ])
        let shallow = try await search(chain, "needle", limits: .init(maxDepth: 2))
        XCTAssertEqual(shallow.paths, ["/r/needle-0", "/r/1/needle-1", "/r/1/2/needle-2"])
        XCTAssertEqual(shallow.final.skippedDeepFolders, 1)
        XCTAssertNil(shallow.final.stop, "Skipping deeper folders is reported separately")

        var wide = ["/r": (0..<10).map { folder("/r/f\($0)") } + (0..<10).map { file("/r/needle-\($0)") }]
        for index in 0..<10 { wide["/r/f\(index)"] = [file("/r/f\(index)/needle")] }
        let folders = TreeService(wide)
        let fewFolders = try await search(folders, "f", limits: .init(maxFolders: 4, concurrentListings: 1, concurrentListingLimit: 1))
        XCTAssertEqual(fewFolders.final.stop, .folderLimit)
        XCTAssertEqual(fewFolders.final.foldersSearched, 4)
        let listedFolders = await folders.listed
        XCTAssertEqual(listedFolders.count, 4)

        let matches = TreeService(wide)
        let fewMatches = try await search(matches, "needle", limits: .init(maxMatches: 5))
        XCTAssertEqual(fewMatches.paths.count, 5)
        XCTAssertEqual(fewMatches.final.stop, .matchLimit)
        let listedForMatches = await matches.listed
        XCTAssertEqual(listedForMatches, ["/r"], "Reaching the limit in the starting folder lists nothing more")
        let exactly = try await search(TreeService(["/r": (0..<5).map { file("/r/needle-\($0)") }]), "needle",
                                       limits: .init(maxMatches: 5))
        XCTAssertNil(exactly.final.stop, "Exactly the limit in a finished walk is complete")

        let slow = TreeService(wide, delay: .milliseconds(60))
        let timed = try await search(slow, "needle", limits: .init(timeLimit: .milliseconds(150), concurrentListings: 1, concurrentListingLimit: 1))
        XCTAssertEqual(timed.final.stop, .timeLimit)
        XCTAssertLessThan(timed.final.foldersSearched, 11)
        XCTAssertEqual(timed.paths.count, 10 + timed.final.foldersSearched - 1, "Matches from every listed folder are kept")
    }

    func testListingsStayWithinTheWindowAndCancellingStopsTheWalk() async throws {
        var tree = ["/r": (0..<30).map { folder("/r/f\($0)") }]
        for index in 0..<30 { tree["/r/f\(index)"] = [] }
        let service = TreeService(tree, delay: .milliseconds(30))
        let consumer = Task {
            for try await _ in RemoteFolderSearch.names(matching: "x", below: "/r", profile: profile, service: service,
                                                        includeHidden: false, limits: .init(concurrentListings: 3, concurrentListingLimit: 3)) {}
        }
        while await service.listed.count < 8 { try await Task.sleep(for: .milliseconds(10)) }
        consumer.cancel()
        try await Task.sleep(for: .milliseconds(150))
        let afterCancel = await service.listed.count
        try await Task.sleep(for: .milliseconds(200))
        let later = await service.listed.count
        XCTAssertEqual(later, afterCancel, "No folder is listed after the search is cancelled")
        XCTAssertLessThan(later, 31)
        let mostAtOnce = await service.mostAtOnce
        XCTAssertEqual(mostAtOnce, 3, "Subfolders are listed three at a time")
    }

    func testAFolderWithTooManyNamesIsCountedAndTheSearchGoesOn() async throws {
        let tree = ["/r": [folder("/r/huge"), folder("/r/ok"), file("/r/needle.txt")], "/r/ok": [file("/r/ok/needle-2.txt")]]
        let result = try await search(TreeService(tree, failures: ["/r/huge": .listingTooLarge]), "needle")
        XCTAssertEqual(result.paths, ["/r/needle.txt", "/r/ok/needle-2.txt"])
        XCTAssertEqual(result.final.unreadableFolders, 1)
        do {
            _ = try await search(TreeService(tree, failures: ["/r": .listingTooLarge]), "needle")
            XCTFail("The starting folder's failure ends the search")
        } catch RemoteFileError.listingTooLarge { }
    }

    /// Listings finish in any order and are taken in queue order, so one slow folder could leave
    /// every other listing waiting in memory. The first folder here never answers until released.
    func testListingsWaitingToBeReportedHoldBackFurtherListings() async throws {
        let name = String(repeating: "n", count: 2_000)
        var tree = ["/r": [folder("/r/a")] + (1...20).map { folder("/r/b\($0)") }, "/r/a": [file("/r/a/needle")]]
        for index in 1...20 { tree["/r/b\(index)"] = [file("/r/b\(index)/" + name)] }
        let gate = ListingGate()
        let service = TreeService(tree, gates: ["/r/a": gate])
        let limits = RemoteFolderSearch.Limits(concurrentListings: 4, concurrentListingLimit: 4, heldListingBytes: 1_000)
        let searching = Task { try await self.search(service, "needle", limits: limits) }
        // The starting folder, then the first four of its subfolders together.
        while await service.listed.count < 5 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        let whileHeld = await service.listed
        XCTAssertEqual(whileHeld.count, 5, "Nothing more is listed while finished listings wait: \(whileHeld)")
        await gate.open()
        let result = try await searching.value
        XCTAssertEqual(result.paths, ["/r/a/needle"])
        XCTAssertEqual(result.final.foldersSearched, 22, "Every folder is still listed once the first is reported")
        XCTAssertNil(result.final.stop)
    }

    /// Only `maxFolders` are ever listed, so the paths of further folders are not kept either.
    func testFolderLimitStillStopsTheSearchWhenLaterFoldersAreNotQueued() async throws {
        var tree = ["/r": (0..<50).map { folder("/r/d\($0)") }]
        for index in 0..<50 { tree["/r/d\(index)"] = [file("/r/d\(index)/needle")] }
        let service = TreeService(tree)
        let result = try await search(service, "needle", limits: .init(maxFolders: 10))
        XCTAssertEqual(result.final.stop, .folderLimit)
        XCTAssertEqual(result.final.foldersSearched, 10)
        XCTAssertEqual(result.paths.count, 9)
        let listed = await service.listed
        XCTAssertEqual(listed.count, 10)
    }

    func testListingPacingBacksOffForALargeListingHoweverQuick() {
        var pacing = RemoteFolderSearch.ListingPacing(limits: .init(concurrentListings: 8, concurrentListingLimit: 64))
        for _ in 0..<100 { pacing.finished(after: .milliseconds(120), nameBytes: RemoteFolderSearch.ListingPacing.large) }
        XCTAssertEqual(pacing.window, 64, "Up to the size counted as large, only time decides")
        pacing.finished(after: .milliseconds(120), nameBytes: RemoteFolderSearch.ListingPacing.large + 1)
        XCTAssertEqual(pacing.window, 32)
        for _ in 0..<10 { pacing.finished(after: .milliseconds(120), nameBytes: 64 * 1_024 * 1_024) }
        XCTAssertEqual(pacing.window, 8, "Never below where it began")
    }

    func testListingPacingGrowsWhileAnswersAreQuickAndBacksOffWhenTheySlow() {
        var pacing = RemoteFolderSearch.ListingPacing(limits: .init(concurrentListings: 8, concurrentListingLimit: 64))
        XCTAssertEqual(pacing.window, 8)
        for _ in 0..<100 { pacing.finished(after: .milliseconds(120)) }
        XCTAssertEqual(pacing.window, 64, "Stops at its limit")
        pacing.finished(after: .seconds(3))
        XCTAssertEqual(pacing.window, 64, "Neither quick nor slow")
        pacing.finished(after: .seconds(6))
        XCTAssertEqual(pacing.window, 32)
        for _ in 0..<10 { pacing.finished(after: .seconds(6)) }
        XCTAssertEqual(pacing.window, 8, "Never below where it began")
        var fixed = RemoteFolderSearch.ListingPacing(limits: .init(concurrentListings: 4, concurrentListingLimit: 4))
        fixed.finished(after: .milliseconds(1))
        XCTAssertEqual(fixed.window, 4)
    }

    func testMatchingLinksResolveOnlyBeforeTheSearchDeadline() async throws {
        let profile = ConnectionProfile(name: "F", host: "f.invalid", username: "f", identityID: UUID(), startingDirectory: "/p")
        func search(limit: Duration, listingTakes: Duration) async throws -> (entries: [RemoteEntry], resolutions: Int) {
            let service = WalkingService(listingTakes: listingTakes)
            var found: [RemoteEntry] = []
            for try await update in RemoteFolderSearch.names(matching: "needle", below: "/p", profile: profile, service: service,
                                                             includeHidden: false, limits: .init(timeLimit: limit)) {
                found += update.matches
            }
            return (found, await service.resolutions)
        }
        let inTime = try await search(limit: .seconds(60), listingTakes: .zero)
        XCTAssertEqual(inTime.resolutions, 1)
        XCTAssertNotNil(inTime.entries.first?.linkTarget)
        let late = try await search(limit: .milliseconds(20), listingTakes: .milliseconds(100))
        XCTAssertEqual(late.resolutions, 0, "No new work starts after the deadline")
        XCTAssertEqual(late.entries.map(\.name), ["needle-link"], "The match is kept")
        XCTAssertNil(late.entries.first?.link, "It resolves when tapped")
    }
}

private actor WalkingService: RemoteFileService, FolderWalking {
    private let listingTakes: Duration
    private(set) var resolutions = 0
    init(listingTakes: Duration) { self.listingTakes = listingTakes }
    func listDirectoryForWalk(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        try await Task.sleep(for: listingTakes)
        return .init(path: path, entries: [.init(name: "needle-link", path: path + "/needle-link", kind: .symlink)])
    }
    func resolvingLinks(in entries: [RemoteEntry], profile: ConnectionProfile) async throws -> [RemoteEntry] {
        resolutions += 1
        return entries.map { .init(name: $0.name, path: $0.path, kind: $0.kind, link: .target(.init(name: "t", path: "/t", kind: .file))) }
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        throw RemoteFileError.unavailable("Not used")
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { .init(name: "t", path: path, kind: .file) }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unavailable("Not used")
    }
    func disconnect() async {}
}
