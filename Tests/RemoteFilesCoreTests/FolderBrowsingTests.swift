#if os(iOS)
import XCTest
import Foundation
import Crypto
import NIOSSH
import RemoteFilesCore
@testable import RemoteFilesUI

final class FolderBrowsingTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)

    private func file(_ name: String, size: UInt64? = nil, modifiedAt: Date? = nil) -> RemoteEntry {
        RemoteEntry(name: name, path: "/p/" + name, kind: .file, size: size, modifiedAt: modifiedAt)
    }
    private func folder(_ name: String) -> RemoteEntry { RemoteEntry(name: name, path: "/p/" + name, kind: .directory) }
    private func link(_ name: String, to target: RemoteEntry?) -> RemoteEntry {
        RemoteEntry(name: name, path: "/p/" + name, kind: .symlink, link: target.map { .target($0) } ?? .broken)
    }
    private func names(_ rows: [FolderRow]) -> [String] { rows.map(\.entry.name) }

    func testRowsDescribeWhatAResolvedLinkOpens() {
        let folderLink = FolderRow(link("Current", to: RemoteEntry(name: "Reports", path: "/r/Reports", kind: .directory)))
        XCTAssertEqual(folderLink.symbol, "folder.fill")
        XCTAssertEqual(folderLink.subtitle, "Link to folder")
        let fileLink = FolderRow(link("Latest", to: RemoteEntry(name: "a.md", path: "/r/a.md", kind: .file, size: 2048, modifiedAt: late)))
        XCTAssertEqual(fileLink.symbol, "doc.richtext")
        XCTAssertTrue(fileLink.subtitle.hasPrefix("Link to file · 2 KB · "), fileLink.subtitle)
        XCTAssertEqual(FolderRow(link("Old", to: nil)).subtitle, "Broken link")
        let unresolved = FolderRow(RemoteEntry(name: "Later", path: "/p/Later", kind: .symlink))
        XCTAssertEqual(unresolved.symbol, "link")
        XCTAssertEqual(unresolved.subtitle, "Symbolic link")
        XCTAssertEqual(FolderRow(file("plain.txt")).subtitle, "File")
    }

    func testLinkedFoldersSortWithFoldersInEveryOrder() {
        let listing = FolderListing(DirectorySnapshot(path: "/p", entries: [
            file("b.txt", size: 10, modifiedAt: early), link("Archive", to: folder("Real archive")),
            folder("Zeta"), file("a.md", size: 30, modifiedAt: late), link("Gone", to: nil)
        ]))
        for order in FolderSortOrder.allCases {
            XCTAssertEqual(Array(names(listing.visible(query: "", showHidden: false, order: order)).prefix(2)), ["Archive", "Zeta"],
                           "Folders and links to folders come first when sorting by \(order)")
        }
    }

    func testSortOrdersUseTargetValuesAndPutMissingValuesLast() {
        let entries = [
            file("small.txt", size: 1, modifiedAt: early), file("big.md", size: 900, modifiedAt: nil),
            file("unknown.swift"), link("newest", to: file("target.md", size: 500, modifiedAt: late)),
            folder("B folder"), folder("A folder")
        ]
        let listing = FolderListing(DirectorySnapshot(path: "/p", entries: entries))
        XCTAssertEqual(names(listing.visible(query: "", showHidden: false, order: .name)),
                       ["A folder", "B folder", "big.md", "newest", "small.txt", "unknown.swift"])
        XCTAssertEqual(names(listing.visible(query: "", showHidden: false, order: .modified)),
                       ["A folder", "B folder", "newest", "small.txt", "big.md", "unknown.swift"])
        XCTAssertEqual(names(listing.visible(query: "", showHidden: false, order: .size)),
                       ["A folder", "B folder", "big.md", "newest", "small.txt", "unknown.swift"])
        // Kind groups by extension; a link sorts by its own name.
        XCTAssertEqual(names(listing.visible(query: "", showHidden: false, order: .kind)),
                       ["A folder", "B folder", "newest", "big.md", "unknown.swift", "small.txt"])
    }

    func testFilteringAndHiddenFilesApplyBeforeSorting() {
        let listing = FolderListing(DirectorySnapshot(path: "/p", entries: [
            file(".env", size: 99), file("notes.md", size: 5), file("Notes old.md", size: 50), file("todo.txt", size: 1)
        ]))
        XCTAssertEqual(names(listing.visible(query: "notes", showHidden: false, order: .size)), ["Notes old.md", "notes.md"])
        XCTAssertEqual(names(listing.visible(query: "", showHidden: true, order: .size)).first, ".env")
        XCTAssertFalse(names(listing.visible(query: "", showHidden: false, order: .size)).contains(".env"))
    }

    func testThisFolderUsesCaseWholeWordAndFileTypeOptionsIncludingWithoutAQuery() {
        let listing = FolderListing(DirectorySnapshot(path: "/p", entries: [
            file("Note.txt", size: 1), file("notes.txt", size: 5), file("my note.txt", size: 10),
            file("my note.md", size: 20), file(".note.txt", size: 30), folder("notebooks")
        ]))
        XCTAssertEqual(names(listing.visible(query: "note", showHidden: false, order: .name)).count, 5)
        XCTAssertFalse(names(listing.visible(query: "note", showHidden: false, order: .name,
            options: .init(caseSensitive: true))).contains("Note.txt"))
        XCTAssertEqual(Set(names(listing.visible(query: "note", showHidden: false, order: .name,
            options: .init(wholeWord: true)))), Set(["Note.txt", "my note.txt", "my note.md"]))
        XCTAssertEqual(names(listing.visible(query: "note", showHidden: false, order: .size,
            options: .init(caseSensitive: true, wholeWord: true, fileExtension: "txt"))), ["my note.txt"])
        XCTAssertEqual(names(listing.visible(query: "", showHidden: false, order: .size,
            options: .init(fileExtension: ".TXT"))), ["my note.txt", "notes.txt", "Note.txt"],
            "The file-type filter applies even before a search term is entered")
        XCTAssertEqual(names(listing.visible(query: "note", showHidden: true, order: .size,
            options: .init(caseSensitive: true, wholeWord: true, fileExtension: "txt"))), [".note.txt", "my note.txt"])
    }

    func testSearchResultsSayWhereEachNameWasFound() {
        XCTAssertEqual(FolderSearchRow(file("n.md"), root: "/p").subtitle, "In this folder · File")
        XCTAssertEqual(FolderSearchRow(RemoteEntry(name: "n.md", path: "/p/a/b/n.md", kind: .file, size: 2048), root: "/p").subtitle,
                       "In a/b · 2 KB")
        XCTAssertEqual(FolderSearchRow(RemoteEntry(name: "Docs", path: "/x/Docs", kind: .directory), root: "/").subtitle, "In x · Folder")
        XCTAssertEqual(FolderSearchRow(RemoteEntry(name: "n.md", path: "/n.md", kind: .file), root: "/").subtitle, "In this folder · File")
    }

    func testSearchSummariesReportUnreadableFoldersAndWhyTheSearchStopped() {
        var state = FolderSearchState()
        state.progress.foldersSearched = 1
        XCTAssertEqual(state.summary, "Searched 1 folder.")
        state.progress.foldersSearched = 1_200; state.progress.unreadableFolders = 2; state.progress.skippedDeepFolders = 3
        XCTAssertEqual(state.summary, "Searched 1,200 folders. 2 couldn’t be read. Folders more than 16 levels down weren’t searched.")
        state.progress.stop = .folderLimit
        XCTAssertEqual(state.summary, "Searched 1,200 folders. 2 couldn’t be read. Stopped after 1,000 folders. Search from a subfolder to go further.")
        state.progress.stop = .timeLimit
        XCTAssertTrue(state.summary.hasSuffix("Stopped after 30 seconds. Search from a subfolder to go further."))
        state.rows = [FolderSearchRow(file("n.md"), root: "/p")]; state.progress.stop = .matchLimit
        XCTAssertTrue(state.summary.hasSuffix("Showing the first 1 matches. Type more to narrow the search."))
    }

    func testAFinishedSearchIsKeptOnlyForTheSameQueryFolderAndSession() {
        let key = FolderSearchState.Key(query: "review", root: "/p", includeHidden: false, sessionRevision: 1, refresh: 0)
        var state = FolderSearchState(key: key)
        XCTAssertFalse(state.isFinished(for: key), "A search still running is started again")
        state.progress.isFinished = true
        XCTAssertTrue(state.isFinished(for: key))
        for other in [FolderSearchState.Key(query: "notes", root: "/p", includeHidden: false, sessionRevision: 1, refresh: 0),
                      FolderSearchState.Key(query: "review", root: "/p", includeHidden: true, sessionRevision: 1, refresh: 0),
                      FolderSearchState.Key(query: "review", root: "/p", includeHidden: false, sessionRevision: 2, refresh: 0),
                      FolderSearchState.Key(query: "review", root: "/p", includeHidden: false, sessionRevision: 1, refresh: 0, scope: .contents),
                      FolderSearchState.Key(query: "review", root: "/p", includeHidden: false, sessionRevision: 1, refresh: 1)] {
            XCTAssertFalse(state.isFinished(for: other))
        }
        state.error = "The SSH connection ended."
        XCTAssertFalse(state.isFinished(for: key), "A failed search is tried again")
    }

    func testChangingMatchingOrExtractionOptionsInvalidatesCompletedSearchAndRejectsOldUpdates() {
        let original = FolderSearchState.Key(query: "note", root: "/p", includeHidden: false,
            sessionRevision: 1, refresh: 0, scope: .contents)
        var finished = FolderSearchState(key: original)
        finished.progress.isFinished = true
        var variants: [FolderSearchState.Key] = []
        var key = original; key.options.caseSensitive = true; variants.append(key)
        key = original; key.options.wholeWord = true; variants.append(key)
        key = original; key.options.fileExtension = "pdf"; variants.append(key)
        key = original; key.extraction.includePDF = true; variants.append(key)
        key = original; key.extraction.includeOCR = true; variants.append(key)
        for changed in variants {
            XCTAssertFalse(finished.isFinished(for: changed))
            var current = FolderSearchState(key: changed)
            var late = RemoteFolderSearch.Update()
            late.isFinished = true
            late.contentMatches = [.init(entry: file("old.txt"), line: 1, snippet: "old note")]
            current.apply(late, for: original)
            XCTAssertTrue(current.rows.isEmpty, "Results from previous options must not leak into the new search")
            XCTAssertFalse(current.progress.isFinished)
        }
    }

    func testPDFResultsShowPagesTextResultsKeepLinesAndExtractionLimitsRemainVisible() {
        let key = FolderSearchState.Key(query: "needle", root: "/p", includeHidden: false,
            sessionRevision: 1, refresh: 0, scope: .contents, extraction: .init(includePDF: true))
        var state = FolderSearchState(key: key)
        var update = RemoteFolderSearch.Update()
        update.contentMatches = [
            .init(entry: file("report.pdf"), line: 2, snippet: "PDF needle", page: 3),
            .init(entry: file("note.txt"), line: 7, snippet: "source needle")
        ]
        update.filesSearched = 2; update.truncatedFiles = 1; update.isFinished = true
        state.apply(update, for: key)
        XCTAssertEqual(state.rows.map(\.snippet), ["Page 3 · PDF needle", "Line 7 · source needle"])
        XCTAssertTrue(state.summary.contains("Checked 2 files."))
        XCTAssertTrue(state.summary.contains("extraction limits; matches may be missing."))
        XCTAssertTrue(state.isFinished(for: key))
    }

    func testContentSearchProgressAndStaleUpdatesDoNotReplaceAnotherScope() async throws {
        let profile = ConnectionProfile(name: "Demo", host: "demo", username: "reader", identityID: UUID())
        let key = FolderSearchState.Key(query: "distance disappear", root: "/Projects/Reports", includeHidden: false,
                                       sessionRevision: 1, refresh: 0, scope: .contents)
        var state = FolderSearchState(key: key)
        for try await update in RemoteFolderSearch.contents(matching: key.query, below: key.root, profile: profile,
            service: DemoRemoteFileService(delayNanoseconds: 0), includeHidden: false) {
            state.apply(update, for: key)
        }
        XCTAssertTrue(state.isFinished(for: key)); XCTAssertEqual(state.rows.count, 3)
        XCTAssertTrue(state.rows.allSatisfy { $0.snippet?.contains("Line 13") == true })
        XCTAssertTrue(state.summary.contains("Checked 5 files."))
        var other = key; other.scope = .subfolders
        state = FolderSearchState(key: other)
        var late = RemoteFolderSearch.Update(); late.isFinished = true; late.matches = [file("old.md")]
        state.apply(late, for: key)
        XCTAssertTrue(state.rows.isEmpty); XCTAssertFalse(state.progress.isFinished)
    }

    @MainActor func testCancellingASearchNeverCancelsTheSameFolderOpenedMeanwhile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = TreeService(["/r": [RemoteEntry(name: "a", path: "/r/a", kind: .directory)],
                                "/r/a": [RemoteEntry(name: "needle", path: "/r/a/needle", kind: .file)]], delay: .milliseconds(300))
        let model = try AppModel(directory: directory, fileService: CoalescingFileService(base: tree))
        let profile = ConnectionProfile(name: "Studio", host: "studio", username: "reader", identityID: UUID())
        let search = Task {
            for try await _ in RemoteFolderSearch.names(matching: "needle", below: "/r", profile: profile,
                                                        service: model.searchService, includeHidden: false) {}
        }
        while await tree.listed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let opened = Task { try await model.service.listDirectory(profile: profile, path: "/r") }
        try await Task.sleep(for: .milliseconds(50))
        search.cancel()
        let snapshot = try await opened.value
        XCTAssertEqual(snapshot.entries.map(\.name), ["a"], "The folder the user opened still loads")
        let listings = await tree.listed
        XCTAssertEqual(listings.filter { $0 == "/r" }.count, 2, "The search made its own request instead of sharing one")
    }

    @MainActor func testSortChoicesAreRememberedPerFolderBoundedAndNeverInDemo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "FolderBrowsingTests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); preferences.removePersistentDomain(forName: suite) }
        let model = try AppModel(directory: directory, fileService: DemoRemoteFileService(delayNanoseconds: 0), preferences: preferences)
        let profile = ConnectionProfile(name: "Studio", host: "studio", username: "reader", identityID: UUID())
        let other = UUID()
        model.metadata.connections = [profile]

        XCTAssertEqual(model.folderSortOrder(profile.id, path: "/Projects"), .name)
        model.setFolderSortOrder(.size, id: profile.id, path: "/Projects")
        model.setFolderSortOrder(.kind, id: other, path: "/Projects")
        XCTAssertEqual(model.folderSortOrder(profile.id, path: "/Projects"), .size)
        XCTAssertEqual(model.folderSortOrder(profile.id, path: "/Projects/Reports"), .name, "Choices are per folder")
        XCTAssertEqual(model.folderSortOrder(other, path: "/Projects"), .kind, "and per connection")
        let relaunched = try AppModel(directory: directory, fileService: DemoRemoteFileService(delayNanoseconds: 0), preferences: preferences)
        XCTAssertEqual(relaunched.folderSortOrder(profile.id, path: "/Projects"), .size)

        model.setFolderSortOrder(.name, id: profile.id, path: "/Projects")
        XCTAssertEqual((preferences.array(forKey: "folderSortOrders-v1") as? [[String]])?.count, 1, "Name is stored as no entry")

        for index in 0..<(AppModel.folderSortLimit + 5) {
            model.setFolderSortOrder(.modified, id: profile.id, path: "/f\(index)")
        }
        XCTAssertEqual((preferences.array(forKey: "folderSortOrders-v1") as? [[String]])?.count, AppModel.folderSortLimit)
        XCTAssertEqual(model.folderSortOrder(other, path: "/Projects"), .name, "The least recently changed choice is dropped first")
        XCTAssertEqual(model.folderSortOrder(profile.id, path: "/f\(AppModel.folderSortLimit + 4)"), .modified)

        await model.removeConnection(profile)
        XCTAssertNil(preferences.array(forKey: "folderSortOrders-v1"), "Deleting a connection forgets its folders")

        await model.setDemo(true)
        model.setFolderSortOrder(.size, id: profile.id, path: "/Projects")
        XCTAssertEqual(model.folderSortOrder(profile.id, path: "/Projects"), .name)
        XCTAssertNil(preferences.array(forKey: "folderSortOrders-v1"), "Demo never writes sort choices")
    }

    @MainActor func testEditingAndRemovingConnectionsDeleteTheirIndexesWithoutAffectingAnotherConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: DemoRemoteFileService(delayNanoseconds: 0))
        let profile = ConnectionProfile(name: "Studio", host: "studio", username: "reader", identityID: UUID())
        let other = ConnectionProfile(name: "Archive", host: "archive", username: "reader", identityID: UUID())
        model.metadata.connections = [profile, other]
        let snapshot = SearchIndexSnapshot(documents: [.init(entry: file("note.txt"), segments: [.init(text: "private note")])],
            includeHidden: false, extraction: .init(), isPartial: false)
        let store = await model.searchIndexStore()
        try await store.save(snapshot, profile: profile, root: "/p")
        try await store.save(snapshot, profile: other, root: "/p")
        var edited = profile; edited.host = "new-studio"
        await model.saveConnection(edited)
        let oldIndex = try await store.load(profile: profile, root: "/p")
        let retained = try await store.load(profile: other, root: "/p")
        XCTAssertNil(oldIndex, "Changing a connection also deletes its previously indexed text")
        XCTAssertEqual(retained?.documents.first?.segments.first?.text, "private note")
        try await store.save(snapshot, profile: edited, root: "/p")
        await model.removeConnection(edited)
        let removed = try await store.load(profile: edited, root: "/p")
        let stillRetained = try await store.load(profile: other, root: "/p")
        XCTAssertNil(removed)
        XCTAssertNotNil(stillRetained)
        XCTAssertEqual(model.metadata.connections.map(\.id), [other.id])
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testTrustResetStillForgetsDestinationAndJumpKeysWhenIndexCleanupFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: DemoRemoteFileService(delayNanoseconds: 0))
        let profile = ConnectionProfile(name: "Studio", host: "studio.invalid", username: "reader", identityID: UUID(),
            jumpHost: JumpHost(host: "jump.invalid", port: 2222, username: "jump", identityID: UUID()))
        let target = HostEndpoint(host: profile.host, port: profile.port)
        let jump = HostEndpoint(host: "jump.invalid", port: 2222)
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let details = try HostKeyDetails(publicKey: key)
        try await model.trust.trustUnknown(endpoint: target, key: details)
        try await model.trust.trustUnknown(endpoint: jump, key: details)
        // A regular file at the cache directory makes cleanup fail deterministically on iOS.
        try Data("invalid index directory".utf8).write(to: model.searchIndexDirectory)

        await model.resetTrust(for: profile)
        do {
            try await model.trust.validate(endpoint: target, publicKey: key)
            XCTFail("An index cleanup error must not prevent forgetting the destination host key")
        } catch HostTrustError.unknown { }
        try await model.trust.validate(endpoint: jump, publicKey: key)
        XCTAssertNotNil(model.errorMessage, "The independent index cleanup error remains visible")

        await model.resetJumpHostTrust(for: profile)
        let restored = try HostTrustStore(fileURL: directory.appendingPathComponent("known-hosts-v1.json"))
        for endpoint in [target, jump] {
            do {
                try await restored.validate(endpoint: endpoint, publicKey: key)
                XCTFail("Both explicit trust resets must persist even when index cleanup fails")
            } catch HostTrustError.unknown { }
        }
    }
}
#endif
