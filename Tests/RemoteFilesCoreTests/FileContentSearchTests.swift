import XCTest
import Foundation
import CoreGraphics
import CoreText
@testable import RemoteFilesCore

private actor ContentTreeService: RemoteFileService {
    let folders: [String: [RemoteEntry]]
    let contents: [String: Data]
    let failures: [String: RemoteFileError]
    var failOnce: [String: RemoteFileError]
    let delays: [String: Duration]
    let canonicalFolders: [String: String]
    let ignoresCancellation: Bool
    private(set) var reads: [(path: String, root: String, limit: Int)] = []
    private(set) var listed: [String] = []
    private(set) var mostAtOnce = 0
    private var running = 0
    init(_ folders: [String: [RemoteEntry]], contents: [String: Data] = [:], failures: [String: RemoteFileError] = [:],
         failOnce: [String: RemoteFileError] = [:], delays: [String: Duration] = [:],
         canonicalFolders: [String: String] = [:], ignoresCancellation: Bool = false) {
        self.folders = folders; self.contents = contents; self.failures = failures; self.failOnce = failOnce
        self.delays = delays; self.canonicalFolders = canonicalFolders; self.ignoresCancellation = ignoresCancellation
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        listed.append(path)
        if let delay = delays["list:" + path] { try await Task.sleep(for: delay) }
        if let failure = failures[path], folders[path] == nil { throw failure }
        return .init(path: canonicalFolders[path] ?? path, entries: folders[path] ?? [])
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        XCTFail("Content searches must use canonically confined reads")
        throw RemoteFileError.invalidPath
    }
    func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        reads.append((path, canonicalRoot, limit))
        running += 1; mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1 }
        if let delay = delays[path] {
            if ignoresCancellation { try? await Task.sleep(for: delay) } else { try await Task.sleep(for: delay) }
        }
        guard RemoteResourcePath.contains(path, in: canonicalRoot) else { throw RemoteDocumentLinkError.outsideConnection }
        if let failure = failOnce.removeValue(forKey: path) ?? failures[path] { throw failure }
        guard let data = contents[path] else { throw RemoteFileError.notFound }
        guard data.count <= limit else { throw RemoteFileError.tooLarge(limit) }
        return data
    }
    func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data {
        try await readSearchFile(profile: profile, path: path, canonicalRoot: allowedRoot, limit: limit)
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}

final class FileContentSearchTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Search", host: "example.invalid", username: "reader", identityID: UUID())
    private func file(_ path: String, size: UInt64? = nil) -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .file, size: size)
    }
    private func folder(_ path: String) -> RemoteEntry { .init(name: RemotePath.name(of: path), path: path, kind: .directory) }
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func search(_ service: ContentTreeService, query: String = "needle", hidden: Bool = false,
                        limits: RemoteFolderSearch.Limits = .init(), content: RemoteFolderSearch.ContentLimits = .init()) async throws
        -> (matches: [RemoteFolderSearch.ContentMatch], final: RemoteFolderSearch.Update) {
        var matches: [RemoteFolderSearch.ContentMatch] = [], final: RemoteFolderSearch.Update?
        for try await update in RemoteFolderSearch.contents(matching: query, below: "/r", profile: profile, service: service,
                                                            includeHidden: hidden, limits: limits, contentLimits: content) {
            XCTAssertNil(final, "Nothing follows the final update")
            XCTAssertTrue(update.matches.isEmpty, "A content search never includes a name-only match")
            matches += update.contentMatches
            if update.isFinished { final = update }
        }
        return (matches, try XCTUnwrap(final))
    }

    /// A backslash is an ordinary byte in a name on the server, as in a file copied from Windows.
    func testFilesHoldingABackslashInTheirPathAreRead() async throws {
        let paths = ["/r/C:\\notes.txt", "/r/dir\\name/a\\..\\notes.md"]
        let service = ContentTreeService(["/r": [file(paths[0]), folder("/r/dir\\name")], "/r/dir\\name": [file(paths[1])]],
                                         contents: Dictionary(uniqueKeysWithValues: paths.map { ($0, bytes("a needle here")) }))
        let result = try await search(service)
        XCTAssertEqual(result.matches.map(\.entry.path), paths)
        XCTAssertEqual(result.final.filesSearched, 2); XCTAssertEqual(result.final.unreadableFiles, 0)
    }

    /// A saved index can't hold a path with a control character, such as a line break, and one such file once made
    /// the whole folder's index impossible to save. It is left out unread and counted, so the index is partial.
    /// A live search saves nothing, so it still reads such files.
    func testIndexLeavesOutFilesWhosePathsHoldControlCharacters() async throws {
        let plain = "/r/plain.txt", lineBreak = "/r/line\nbreak.txt", nested = "/r/dir\u{1}/inside.txt", deleted = "/r/del\u{7F}.md"
        let paths = [plain, lineBreak, nested, deleted]
        let service = ContentTreeService(["/r": [file(plain), file(lineBreak), file(deleted), folder("/r/dir\u{1}")],
                                          "/r/dir\u{1}": [file(nested)]],
                                         contents: Dictionary(uniqueKeysWithValues: paths.map { ($0, bytes("a needle here")) }))
        var final = RemoteFolderSearch.Update()
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: false) { final = $0 }
        XCTAssertEqual(snapshot.documents.map(\.entry.path), [plain])
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(final.skippedFiles, 3)
        let read = await service.reads.map(\.path)
        XCTAssertEqual(read, [plain], "A file the index can't keep isn't read")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SearchIndexStore(directory: directory)
        try await store.save(snapshot, profile: profile, root: "/r")
        let loaded = try await store.load(profile: profile, root: "/r")
        XCTAssertEqual(loaded?.documents.map(\.entry.path), [plain])
        let live = try await search(service)
        XCTAssertEqual(Set(live.matches.map(\.entry.path)), Set(paths))
    }

    func testContentSearchConsumesFoldersDiscoveredAfterTheLastListingFinishes() async throws {
        var tree: [String: [RemoteEntry]] = [:], data: [String: Data] = [:], expected: [String] = []
        var path = "/r"
        for depth in 0..<8 {
            let match = path + "/source.txt", child = path + "/next"
            expected.append(match); data[match] = bytes("needle")
            tree[path] = [file(match)] + (depth < 7 ? [folder(child)] : [])
            path = child
        }
        for window in [1, 4] {
            let service = ContentTreeService(tree, contents: data)
            let result = try await search(service, limits: .init(concurrentListings: window, concurrentListingLimit: window))
            XCTAssertEqual(result.matches.map(\.entry.path), expected)
            XCTAssertEqual(result.final.foldersSearched, tree.count)
            XCTAssertEqual(result.final.filesSearched, expected.count)
            XCTAssertNil(result.final.stop)
            let reads = await service.reads
            XCTAssertEqual(reads.map(\.path), expected)
        }
    }

    func testFindsFirstLiteralSourceMatchWithUnicodeLineAndBoundedSnippet() async throws {
        let tree = ["/r": [file("/r/name-only-needle.md"), file("/r/unicode.txt"), file("/r/page.html"), file("/r/long.json")]]
        let service = ContentTreeService(tree, contents: [
            "/r/name-only-needle.md": bytes("nothing here"),
            "/r/unicode.txt": bytes("\u{FEFF}first\r\n東京 NEEDLE ✨\r\nneedle again"),
            "/r/page.html": bytes("<script>needle()</script>"),
            "/r/long.json": bytes(String(repeating: "🙂", count: 1000) + "needle" + String(repeating: "界", count: 1000))
        ])
        let result = try await search(service)
        XCTAssertEqual(result.matches.map(\.entry.name), ["long.json", "page.html", "unicode.txt"])
        let unicode = try XCTUnwrap(result.matches.last)
        XCTAssertEqual(unicode.line, 2); XCTAssertEqual(unicode.snippet, "東京 NEEDLE ✨", "Context stays on the matching source line")
        XCTAssertTrue(result.matches[1].snippet.contains("<script>needle()</script>"), "Search source; never render HTML")
        XCTAssertLessThanOrEqual(result.matches[0].snippet.count, 202)
        XCTAssertTrue(result.matches[0].snippet.hasPrefix("…")); XCTAssertTrue(result.matches[0].snippet.hasSuffix("…"))
        XCTAssertEqual(result.final.filesSearched, 4)
        let reads = await service.reads
        XCTAssertTrue(reads.allSatisfy { $0.root == "/r" && $0.limit <= 256 * 1024 })
        let parallel = await service.mostAtOnce; XCTAssertEqual(parallel, 1)
    }

    func testSkipsLinksHiddenBinaryOversizedAndUnsupportedFiles() async throws {
        let service = ContentTreeService(["/r": [file("/r/.hidden.txt"), folder("/r/.cache"), file("/r/image.png"),
            file("/r/large.md", size: 300_000), file("/r/binary.txt"), file("/r/invalid.txt"), file("/r/empty.txt"),
            .init(name: "alias.txt", path: "/r/alias.txt", kind: .symlink, link: .target(file("/outside/needle.txt")))],
            "/r/.cache": [file("/r/.cache/a.txt")]], contents: ["/r/.hidden.txt": bytes("needle"),
                "/r/.cache/a.txt": bytes("needle"), "/r/binary.txt": Data([0, 110]), "/r/invalid.txt": Data([255]), "/r/empty.txt": Data()])
        let result = try await search(service)
        XCTAssertTrue(result.matches.isEmpty); XCTAssertEqual(result.final.skippedFiles, 5)
        let reads = await service.reads; XCTAssertEqual(reads.map(\.path), ["/r/binary.txt", "/r/empty.txt", "/r/invalid.txt"])
        let hidden = try await search(service, hidden: true)
        XCTAssertEqual(hidden.matches.map(\.entry.path), ["/r/.hidden.txt", "/r/.cache/a.txt"])
    }

    func testByteBudgetCountsFailedReadsAndShrinksTheLastReadEvenWhenMetadataIsStale() async throws {
        let service = ContentTreeService(["/r": [file("/r/a.txt", size: 1), file("/r/b.txt"), file("/r/c.txt")]],
            contents: ["/r/a.txt": bytes(String(repeating: "x", count: 100)), "/r/b.txt": bytes(String(repeating: "x", count: 100))])
        let result = try await search(service, content: .init(maxFileBytes: 10, maxTotalBytes: 18))
        XCTAssertEqual(result.final.stop, .byteLimit)
        XCTAssertEqual(result.final.chargedBytes, 18)
        XCTAssertEqual(result.final.skippedFiles, 1)
        let reads = await service.reads
        XCTAssertEqual(reads.map(\.limit), [10, 6], "Both unsuccessful reads cost their full reservation plus EOF byte")
        XCTAssertEqual(result.final.filesSearched, 2)
        let tiny = try await search(ContentTreeService(["/r": [file("/r/a.txt")]], contents: ["/r/a.txt": bytes("needle")]),
                                    content: .init(maxTotalBytes: 1))
        XCTAssertEqual(tiny.final.stop, .byteLimit)
    }

    func testSuccessfulReadsRefundUnusedBudgetWithoutTrustingListedSizes() async throws {
        let service = ContentTreeService(["/r": [file("/r/a.txt", size: 0), file("/r/b.txt", size: 0)]],
                                         contents: ["/r/a.txt": bytes("needle"), "/r/b.txt": bytes("needle")])
        let result = try await search(service, content: .init(maxFileBytes: 20, maxTotalBytes: 14))
        XCTAssertEqual(result.matches.count, 2); XCTAssertNil(result.final.stop)
        XCTAssertEqual(result.final.bytesRead, 12); XCTAssertEqual(result.final.chargedBytes, 12)
        let reads = await service.reads; XCTAssertEqual(reads.map(\.limit), [13, 7])
    }

    func testFileAndMatchLimitsKeepResultsNearestFolderFirst() async throws {
        let tree = ["/r": [folder("/r/z"), folder("/r/a")],
                    "/r/a": [folder("/r/a/deep")], "/r/z": [file("/r/z/near.txt")],
                    "/r/a/deep": [file("/r/a/deep/far.txt")]]
        let data = ["/r/z/near.txt": bytes("needle"), "/r/a/deep/far.txt": bytes("needle")]
        let result = try await search(ContentTreeService(tree, contents: data, delays: ["list:/r/z": .milliseconds(80)]),
                                      limits: .init(maxMatches: 1))
        XCTAssertEqual(result.matches.map(\.entry.path), ["/r/z/near.txt"]); XCTAssertEqual(result.final.stop, .matchLimit)
        let files = try await search(ContentTreeService(tree, contents: data), content: .init(maxFiles: 1))
        XCTAssertEqual(files.final.stop, .fileLimit); XCTAssertEqual(files.final.filesSearched, 1)
        let depth = try await search(ContentTreeService(tree, contents: data), limits: .init(maxDepth: 0))
        XCTAssertTrue(depth.matches.isEmpty); XCTAssertEqual(depth.final.skippedDeepFolders, 2)
    }

    func testFileErrorsAreCountedConnectionRecoveryIsBoundedAndFatalErrorsPropagate() async throws {
        let entries = (1...5).map { file("/r/\($0).txt") }
        let service = ContentTreeService(["/r": entries], contents: ["/r/4.txt": bytes("needle"), "/r/5.txt": bytes("needle")],
            failures: ["/r/1.txt": .permissionDenied, "/r/2.txt": .notFound, "/r/3.txt": .timedOut],
            failOnce: ["/r/4.txt": .connectionEnded])
        let result = try await search(service)
        XCTAssertEqual(result.final.unreadableFiles, 3); XCTAssertEqual(result.matches.count, 2)
        let reads = await service.reads; XCTAssertEqual(reads.filter { $0.path == "/r/4.txt" }.count, 2)
        for failure in [RemoteFileError.connectionEnded, .unavailable("Trust failure")] {
            do {
                _ = try await search(ContentTreeService(["/r": [file("/r/a.txt")]], failures: ["/r/a.txt": failure]))
                XCTFail("A fatal error must not look like an empty completed search")
            } catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    func testDeadlineDoesNotStartAnotherReadOrRecoveryAndKeepsFirstMatch() async throws {
        let entries = [file("/r/a.txt"), file("/r/b.txt")]
        let service = ContentTreeService(["/r": entries], contents: ["/r/a.txt": bytes("needle")], delays: ["/r/a.txt": .milliseconds(80)])
        let result = try await search(service, limits: .init(timeLimit: .milliseconds(30)))
        XCTAssertEqual(result.matches.count, 1); XCTAssertEqual(result.final.stop, .timeLimit)
        let reads = await service.reads; XCTAssertEqual(reads.count, 1)
        let broken = ContentTreeService(["/r": entries], failOnce: ["/r/a.txt": .connectionEnded], delays: ["/r/a.txt": .milliseconds(80)])
        let recovery = try await search(broken, limits: .init(timeLimit: .milliseconds(30)))
        XCTAssertEqual(recovery.final.stop, .timeLimit)
        let attempts = await broken.reads; XCTAssertEqual(attempts.count, 1)
    }

    func testCancellationDiscardsLateReadAndStartsNoMoreWork() async throws {
        let service = ContentTreeService(["/r": (0..<30).map { file("/r/\($0).txt") }],
            contents: ["/r/0.txt": bytes("needle")], delays: ["/r/0.txt": .seconds(5)], ignoresCancellation: true)
        let task = Task {
            var matches = 0
            for try await update in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: self.profile,
                                                                service: service, includeHidden: false) {
                matches += update.contentMatches.count
            }
            return matches
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await service.reads.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await service.reads.count; XCTAssertEqual(started, 1)
        task.cancel()
        let matches = try await task.value; XCTAssertEqual(matches, 0, "A cancelled read must not publish its late bytes")
        try await Task.sleep(for: .milliseconds(80))
        let reads = await service.reads; XCTAssertEqual(reads.count, 1)
    }

    func testEachReadStreamsProgressBeforeTheFolderFinishes() async throws {
        let service = ContentTreeService(["/r": [file("/r/a.txt"), file("/r/b.txt")]],
            contents: ["/r/a.txt": bytes("needle"), "/r/b.txt": bytes("needle")])
        var counts: [Int] = []
        for try await update in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: profile,
                                                            service: service, includeHidden: false) where !update.contentMatches.isEmpty {
            XCTAssertEqual(update.contentMatches.count, 1)
            counts.append(update.filesSearched)
        }
        XCTAssertEqual(counts, [1, 2])
    }

    func testCancellingContentSearchDoesNotCancelTheSameFilePreview() async throws {
        let base = ContentTreeService(["/r": [file("/r/a.txt")]], contents: ["/r/a.txt": bytes("needle")],
                                      delays: ["/r/a.txt": .milliseconds(300)])
        let service = CoalescingFileService(base: base)
        let search = Task {
            for try await _ in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: self.profile,
                                                            service: service, includeHidden: false) {}
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await base.reads.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let preview = Task { try await service.readDocumentFile(profile: self.profile, path: "/r/a.txt", allowedRoot: "/r", limit: 100) }
        while await base.reads.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        search.cancel()
        let data = try await preview.value
        XCTAssertEqual(data, bytes("needle"))
        let reads = await base.reads; XCTAssertEqual(reads.count, 2)
    }

    func testMovedFolderCannotExposeOutsideContentsAndEmptyQueryDoesNoWork() async throws {
        let service = ContentTreeService(["/r": [folder("/r/moved")], "/r/moved": [file("/outside/secret.txt")]],
            contents: ["/outside/secret.txt": bytes("needle")], canonicalFolders: ["/r/moved": "/outside"])
        let result = try await search(service)
        XCTAssertTrue(result.matches.isEmpty); XCTAssertEqual(result.final.unreadableFolders, 1)
        let reads = await service.reads; XCTAssertTrue(reads.isEmpty)
        let empty = ContentTreeService(["/r": [file("/r/a.txt")]])
        let noQuery = try await search(empty, query: "")
        XCTAssertTrue(noQuery.final.isFinished)
        let listings = await empty.listed; XCTAssertTrue(listings.isEmpty)
    }

    func testIndexBuildCollectsAllSupportedDocumentsWithoutAQueryAndReusesThemForDifferentQueries() async throws {
        let service = ContentTreeService(["/r": [file("/r/a.txt"), file("/r/empty.txt"), folder("/r/nested")],
                                          "/r/nested": [file("/r/nested/b.md")]],
            contents: ["/r/a.txt": bytes("alpha"), "/r/empty.txt": Data(), "/r/nested/b.md": bytes("bravo")])
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service,
                                                               includeHidden: false, limits: .init(maxMatches: 1))
        XCTAssertEqual(snapshot.documents.map(\.entry.path), ["/r/a.txt", "/r/empty.txt", "/r/nested/b.md"])
        XCTAssertFalse(snapshot.isPartial, "A query-independent build is not capped by matching documents")
        let alpha = try RemoteFolderSearch.indexedContents(matching: "alpha", snapshot: snapshot, includeHidden: false)
        let bravo = try RemoteFolderSearch.indexedContents(matching: "bravo", snapshot: snapshot, includeHidden: false)
        XCTAssertEqual(alpha.contentMatches.map(\.entry.path), ["/r/a.txt"])
        XCTAssertEqual(bravo.contentMatches.map(\.entry.path), ["/r/nested/b.md"])
        XCTAssertTrue(alpha.isFinished && bravo.isFinished)
        let reads = await service.reads
        let listings = await service.listed
        XCTAssertEqual(reads.count, 3, "Changing an indexed query must not fetch the remote files again")
        XCTAssertEqual(listings, ["/r", "/r/nested"])
        XCTAssertTrue(reads.allSatisfy { $0.root == "/r" })
    }

    func testKeysInOrdinaryFilesAreNeverMatchedOrSavedInAnIndex() async throws {
        let key = SyntheticKey.pem()
        let fragment = try XCTUnwrap(SyntheticKey.fragments(of: key).first)
        let mixed = "first\n\n" + key + "\nneedle after the key\n"
        let files = ["/r/id_rsa": key, "/r/.server.key": key, "/r/server.pem.txt": key, "/r/notes.txt": mixed]
        let service = ContentTreeService(["/r": files.keys.sorted().map { file($0) }],
                                         contents: files.mapValues { bytes($0) })
        // What the server would return for the key's own text: nothing, whichever part is asked for.
        for query in [fragment, String(fragment.prefix(8)), "BEGIN RSA"] {
            var found: [RemoteFolderSearch.ContentMatch] = []
            for try await update in RemoteFolderSearch.contents(matching: query, below: "/r", profile: profile, service: service, includeHidden: true,
                                                                extraction: .init(includePDF: true)) {
                found += update.contentMatches
            }
            XCTAssertTrue(found.allSatisfy { $0.entry.path == "/r/notes.txt" }, "A file that's only a key has no text to match")
            for match in found {
                XCTAssertFalse(match.snippet.contains(fragment))
                XCTAssertEqual(match.line, 3, "Only the marker of the key in the document, on its own line")
            }
            if query != "BEGIN RSA" { XCTAssertEqual(found.count, 0) }
        }
        // A match after the key reports the line it has in the file.
        var after: [RemoteFolderSearch.ContentMatch] = []
        for try await update in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: profile, service: service, includeHidden: true,
                                                            extraction: .init(includePDF: true)) {
            after += update.contentMatches
        }
        let expectedLine = (mixed.components(separatedBy: "needle").first ?? "").reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        XCTAssertEqual(after.map(\.line), [expectedLine])

        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: true)
        XCTAssertEqual(snapshot.documents.count, 4)
        XCTAssertFalse(snapshot.isPartial, "A key file was read, and found to hold nothing to search")
        let saved = snapshot.documents.flatMap(\.segments).map(\.text).joined()
        for fragment in SyntheticKey.fragments(of: key) { XCTAssertFalse(saved.contains(fragment)) }
        XCTAssertEqual(snapshot.documents.first { $0.entry.path == "/r/id_rsa" }?.segments, [])
        let indexed = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: snapshot, includeHidden: true, root: "/r")
        XCTAssertEqual(indexed.contentMatches.map(\.line), [expectedLine])
        let probed = try RemoteFolderSearch.indexedContents(matching: fragment, snapshot: snapshot, includeHidden: true, root: "/r")
        XCTAssertEqual(probed.contentMatches.count, 0)
    }

    func testPEMHoldingAPrivateKeyIsNeverReadSearchedOrIndexed() async throws {
        // Built up so secret scanners don't flag this file. The body is what a search would find.
        let keyed = bytes("-----BEGIN PRIVATE" + " KEY-----\nneedleKeyBytes\n-----END PRIVATE" + " KEY-----\n")
        let names = ["server.pem", ".hidden.pem", "a.crt", "a.cer", "a.der", "a.p7b", "a.p7c", "a.csr", "a.p12", "a.pfx"]
        let paths = names.map { "/r/" + $0 }
        let service = ContentTreeService(["/r": paths.map { file($0) } + [file("/r/notes.txt")]],
            contents: Dictionary(uniqueKeysWithValues: paths.map { ($0, keyed) }).merging(["/r/notes.txt": bytes("needle")]) { _, new in new })
        // The live search, with hidden files too, and every kind of extraction on.
        var matches: [RemoteFolderSearch.ContentMatch] = []
        for try await update in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: profile, service: service, includeHidden: true,
                                                            extraction: .init(includePDF: true, includeOCR: true)) {
            matches += update.contentMatches
        }
        XCTAssertEqual(matches.map(\.entry.path), ["/r/notes.txt"])
        // A saved index keeps text on disk, so this is where a key would last longest.
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: true,
                                                               extraction: .init(includePDF: true, includeOCR: true))
        XCTAssertEqual(snapshot.documents.map(\.entry.path), ["/r/notes.txt"])
        XCTAssertFalse(snapshot.documents.flatMap(\.segments).contains { $0.text.contains("needleKeyBytes") })
        let reads = await service.reads
        XCTAssertEqual(Set(reads.map(\.path)), ["/r/notes.txt"], "Their bytes are never even transferred for a search")
    }

    func testOlderIndexHoldingAHiddenPEMNoLongerFindsItsText() throws {
        // Hidden `.pem` files counted as text before certificate previews, so such an index can exist.
        let segments = [SearchTextSegment(text: "needle")]
        let snapshot = SearchIndexSnapshot(documents: [.init(entry: file("/r/.server.pem"), segments: segments),
                                                       .init(entry: file("/r/.notes"), segments: segments)],
                                           includeHidden: true, extraction: .init(), isPartial: false)
        let update = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: snapshot, includeHidden: true)
        XCTAssertEqual(update.contentMatches.map(\.entry.path), ["/r/.notes"])
    }

    func testRebuildingIndexReplacesDeletedAndChangedDocuments() async throws {
        let original = ContentTreeService(["/r": [file("/r/deleted.txt"), file("/r/changed.txt")]],
            contents: ["/r/deleted.txt": bytes("old phrase"), "/r/changed.txt": bytes("old phrase")])
        let old = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: original, includeHidden: false)
        let current = ContentTreeService(["/r": [file("/r/changed.txt"), file("/r/new.txt")]],
            contents: ["/r/changed.txt": bytes("new phrase"), "/r/new.txt": bytes("new phrase")])
        let rebuilt = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: current, includeHidden: false)
        XCTAssertEqual(try RemoteFolderSearch.indexedContents(matching: "old phrase", snapshot: old, includeHidden: false).contentMatches.count, 2)
        XCTAssertTrue(try RemoteFolderSearch.indexedContents(matching: "old phrase", snapshot: rebuilt, includeHidden: false).contentMatches.isEmpty)
        XCTAssertEqual(try RemoteFolderSearch.indexedContents(matching: "new phrase", snapshot: rebuilt, includeHidden: false)
            .contentMatches.map(\.entry.path), ["/r/changed.txt", "/r/new.txt"])
    }

    private func dated(_ path: String, size: UInt64?, at seconds: TimeInterval?) -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .file, size: size,
              modifiedAt: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    func testIndexUpdateKeepsUnchangedFilesAndRereadsChangedNewAndUndatedFiles() async throws {
        let original = ContentTreeService(["/r": [dated("/r/same.txt", size: 3, at: 100), dated("/r/edited.txt", size: 3, at: 100),
                                                  dated("/r/resized.txt", size: 3, at: 100), dated("/r/undated.txt", size: 3, at: nil),
                                                  dated("/r/removed.txt", size: 3, at: 100), folder("/r/sub")],
                                           "/r/sub": [dated("/r/sub/deep.txt", size: 3, at: 100)]],
            contents: ["/r/same.txt": bytes("old"), "/r/edited.txt": bytes("old"), "/r/resized.txt": bytes("old"),
                       "/r/undated.txt": bytes("old"), "/r/removed.txt": bytes("old"), "/r/sub/deep.txt": bytes("old")])
        let old = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: original, includeHidden: false)
        XCTAssertEqual(old.documents.map(\.isTruncated), Array(repeating: false, count: 6))
        // Unchanged files hold different bytes here, so any read of them would show up in the index.
        let current = ContentTreeService(["/r": [dated("/r/same.txt", size: 3, at: 100), dated("/r/edited.txt", size: 3, at: 200),
                                                 dated("/r/resized.txt", size: 4, at: 100), dated("/r/undated.txt", size: 3, at: nil),
                                                 dated("/r/added.txt", size: 3, at: 100), folder("/r/sub")],
                                          "/r/sub": [dated("/r/sub/deep.txt", size: 3, at: 100)]],
            contents: ["/r/same.txt": bytes("new"), "/r/edited.txt": bytes("new"), "/r/resized.txt": bytes("newer"),
                       "/r/undated.txt": bytes("new"), "/r/added.txt": bytes("new"), "/r/sub/deep.txt": bytes("new")])
        var final = RemoteFolderSearch.Update()
        let updated = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: current,
                                                              includeHidden: false, reusing: old) { final = $0 }
        let reads = await current.reads
        XCTAssertEqual(reads.map(\.path), ["/r/added.txt", "/r/edited.txt", "/r/resized.txt", "/r/undated.txt"])
        XCTAssertEqual(updated.documents.map(\.entry.path),
                       ["/r/added.txt", "/r/edited.txt", "/r/resized.txt", "/r/same.txt", "/r/undated.txt", "/r/sub/deep.txt"])
        XCTAssertEqual(updated.documents.map { $0.segments.map(\.text).joined() }, ["new", "new", "newer", "old", "new", "old"])
        XCTAssertEqual(updated.documents.first { $0.entry.path == "/r/edited.txt" }?.entry.modifiedAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(final.isFinished)
        XCTAssertEqual(final.reusedFiles, 2); XCTAssertEqual(final.filesSearched, 6)
        XCTAssertFalse(updated.isPartial)
        XCTAssertTrue(try RemoteFolderSearch.indexedContents(matching: "old", snapshot: updated, includeHidden: false)
            .contentMatches.allSatisfy { ["/r/same.txt", "/r/sub/deep.txt"].contains($0.entry.path) })
        // Without a previous snapshot every file is read again.
        let full = ContentTreeService(["/r": [dated("/r/same.txt", size: 3, at: 100)]], contents: ["/r/same.txt": bytes("new")])
        let rebuilt = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: full, includeHidden: false)
        XCTAssertEqual(rebuilt.documents.first?.segments.first?.text, "new")
    }

    func testIndexUpdateRereadsFilesWhenOptionsChangedOrTextMayBeIncomplete() async throws {
        let tree = ["/r": [dated("/r/a.txt", size: 5, at: 100), dated("/r/b.txt", size: 5, at: 100)]]
        let data = ["/r/a.txt": bytes("alpha"), "/r/b.txt": bytes("bravo")]
        func update(_ previous: SearchIndexSnapshot, hidden: Bool = false,
                    extraction: SearchExtractionOptions = .init(includePDF: true)) async throws -> [String] {
            let service = ContentTreeService(tree, contents: data)
            _ = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: hidden,
                                                        extraction: extraction, reusing: previous)
            return await service.reads.map(\.path)
        }
        let old = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile,
            service: ContentTreeService(tree, contents: data), includeHidden: false)
        let none = try await update(old)
        XCTAssertEqual(none, [])
        let hidden = try await update(old, hidden: true)
        XCTAssertEqual(hidden, ["/r/a.txt", "/r/b.txt"], "Other hidden-file choices reread everything")
        let ocr = try await update(old, extraction: .init(includePDF: true, includeOCR: true))
        XCTAssertEqual(ocr, ["/r/a.txt", "/r/b.txt"], "Other extraction choices reread everything")

        // A truncated document may have been cut by the build's overall text budget, so read it again.
        let cut = SearchIndexSnapshot(documents: [.init(entry: tree["/r"]![0], segments: [.init(text: "alp")], isTruncated: true),
                                                  .init(entry: tree["/r"]![1], segments: [.init(text: "bravo")], isTruncated: false)],
                                      includeHidden: false, extraction: .init(includePDF: true), isPartial: true)
        let truncated = try await update(cut)
        XCTAssertEqual(truncated, ["/r/a.txt"])
        // Indexes saved before truncation was recorded are trusted only when they were complete.
        let legacy = old.documents.map { SearchIndexDocument(entry: $0.entry, segments: $0.segments) }
        let complete = try await update(.init(documents: legacy, includeHidden: false, extraction: .init(includePDF: true), isPartial: false))
        XCTAssertEqual(complete, [])
        let partial = try await update(.init(documents: legacy, includeHidden: false, extraction: .init(includePDF: true), isPartial: true))
        XCTAssertEqual(partial, ["/r/a.txt", "/r/b.txt"])
    }

    func testIndexUpdateKeepsReusedTextWithinTheFileAndTextLimits() async throws {
        let tree = ["/r": [dated("/r/a.txt", size: 5, at: 100), dated("/r/b.txt", size: 5, at: 100), dated("/r/c.txt", size: 5, at: 100)]]
        let data = ["/r/a.txt": bytes("alpha"), "/r/b.txt": bytes("bravo"), "/r/c.txt": bytes("delta")]
        let old = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile,
            service: ContentTreeService(tree, contents: data), includeHidden: false)
        let service = ContentTreeService(tree, contents: data)
        let limited = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service,
            includeHidden: false, contentLimits: .init(maxFiles: 2), reusing: old)
        XCTAssertEqual(limited.documents.map(\.entry.path), ["/r/a.txt", "/r/b.txt"])
        XCTAssertTrue(limited.isPartial, "Reused files still count towards the file limit")
        let reads = await service.reads
        XCTAssertTrue(reads.isEmpty)
    }

    func testCancelledIndexBuildDoesNotReturnAPartialSnapshotOrStartAnotherRead() async throws {
        let service = ContentTreeService(["/r": [file("/r/a.txt"), file("/r/b.txt"), file("/r/c.txt")]],
            contents: ["/r/a.txt": bytes("alpha"), "/r/b.txt": bytes("bravo"), "/r/c.txt": bytes("charlie")],
            delays: ["/r/b.txt": .seconds(5)], ignoresCancellation: true)
        let task = Task {
            try await RemoteFolderSearch.buildIndex(below: "/r", profile: self.profile, service: service, includeHidden: false)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await service.reads.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await service.reads.count
        XCTAssertEqual(started, 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must leave the previous saved index intact, not return a replaceable partial build")
        } catch { XCTAssertTrue(error is CancellationError) }
        let reads = await service.reads
        XCTAssertEqual(reads.map(\.path), ["/r/a.txt", "/r/b.txt"])
    }

    func testLiveAndIndexedSearchApplyCaseWholeWordAndExtensionFilters() async throws {
        let tree = ["/r": [file("/r/a.txt"), file("/r/b.txt"), file("/r/c.txt"), file("/r/d.md")]]
        let data = ["/r/a.txt": bytes("Needle"), "/r/b.txt": bytes("needlework"),
                    "/r/c.txt": bytes("a needle here"), "/r/d.md": bytes("needle")]
        let options = SearchQueryOptions(caseSensitive: true, wholeWord: true, fileExtension: "txt")
        let live = ContentTreeService(tree, contents: data)
        var matches: [RemoteFolderSearch.ContentMatch] = []
        for try await update in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: profile,
                                                            service: live, includeHidden: false, options: options) {
            matches += update.contentMatches
        }
        XCTAssertEqual(matches.map(\.entry.path), ["/r/c.txt"])
        let reads = await live.reads
        XCTAssertEqual(reads.map(\.path), ["/r/a.txt", "/r/b.txt", "/r/c.txt"], "Extension filtering happens before a remote read")
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile,
            service: ContentTreeService(tree, contents: data), includeHidden: false)
        let indexed = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: snapshot, includeHidden: false, options: options)
        XCTAssertEqual(indexed.contentMatches.map(\.entry.path), matches.map(\.entry.path))
        XCTAssertEqual(try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: snapshot, includeHidden: false)
            .contentMatches.count, 4, "The default retains case-insensitive substring matching")
    }

    func testIndexBuildMarksFileByteDepthAndExtractionLimitsAsPartial() async throws {
        let tree = ["/r": [file("/r/a.txt"), file("/r/b.txt")]]
        let data = ["/r/a.txt": bytes("alpha"), "/r/b.txt": bytes("bravo")]
        let fileLimited = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile,
            service: ContentTreeService(tree, contents: data), includeHidden: false, contentLimits: .init(maxFiles: 1))
        XCTAssertTrue(fileLimited.isPartial)
        XCTAssertEqual(fileLimited.documents.map(\.entry.path), ["/r/a.txt"])
        let byteService = ContentTreeService(tree, contents: data)
        let byteLimited = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: byteService,
            includeHidden: false, contentLimits: .init(maxFileBytes: 10, maxTotalBytes: 8))
        XCTAssertTrue(byteLimited.isPartial)
        XCTAssertEqual(byteLimited.documents.map(\.entry.path), ["/r/a.txt"])
        let reads = await byteService.reads
        XCTAssertEqual(reads.map(\.limit), [7, 2])
        let depthLimited = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile,
            service: ContentTreeService(["/r": [folder("/r/deep")], "/r/deep": [file("/r/deep/a.txt")]]),
            includeHidden: false, limits: .init(maxDepth: 0))
        XCTAssertTrue(depthLimited.isPartial); XCTAssertTrue(depthLimited.documents.isEmpty)
        let textLimited = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile,
            service: ContentTreeService(tree, contents: data), includeHidden: false, extraction: .init(maxTextBytes: 3))
        XCTAssertTrue(textLimited.isPartial)
        XCTAssertEqual(textLimited.documents.flatMap(\.segments).map(\.text), ["alp", "bra"])
    }

    func testIndexedSearchHonorsHiddenPathsAndMatchLimitsWithoutDiscardingSavedDocuments() async throws {
        let service = ContentTreeService(["/r": [file("/r/a.txt"), file("/r/b.txt"), folder("/r/.hidden")],
                                          "/r/.hidden": [file("/r/.hidden/c.txt")]],
            contents: ["/r/a.txt": bytes("needle"), "/r/b.txt": bytes("needle"), "/r/.hidden/c.txt": bytes("needle")])
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: true)
        let visible = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: snapshot, includeHidden: false)
        XCTAssertEqual(visible.contentMatches.map(\.entry.path), ["/r/a.txt", "/r/b.txt"])
        let limited = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: snapshot, includeHidden: true, maxMatches: 1)
        XCTAssertEqual(limited.stop, .matchLimit); XCTAssertEqual(limited.contentMatches.count, 1)
        XCTAssertEqual(try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: snapshot, includeHidden: true).contentMatches.count, 3)
        XCTAssertEqual(snapshot.documents.count, 3)
        let empty = try RemoteFolderSearch.indexedContents(matching: "", snapshot: snapshot, includeHidden: true)
        XCTAssertTrue(empty.isFinished); XCTAssertTrue(empty.contentMatches.isEmpty)
    }

    func testPDFSearchAndIndexPreserveMatchingPageAndUseConfinedReads() async throws {
        let pdf = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdf))
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for text in ["An ordinary first page", "Needle appears on the second page"] {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 30, y: 200)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)]
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            context.endPDFPage()
        }
        context.closePDF()
        let service = ContentTreeService(["/r": [file("/r/report.pdf")]], contents: ["/r/report.pdf": pdf as Data])
        var matches: [RemoteFolderSearch.ContentMatch] = []
        for try await update in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: profile,
            service: service, includeHidden: false, extraction: .init(includePDF: true)) {
            matches += update.contentMatches
        }
        XCTAssertEqual(matches.count, 1); XCTAssertEqual(matches.first?.page, 2)
        XCTAssertTrue(matches.first?.snippet.contains("second page") == true)
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: false)
        let indexed = try RemoteFolderSearch.indexedContents(matching: "needle", snapshot: snapshot, includeHidden: false)
        XCTAssertEqual(indexed.contentMatches.first?.page, 2)
        XCTAssertEqual(indexed.contentMatches.first?.snippet, matches.first?.snippet)
        let reads = await service.reads
        XCTAssertEqual(reads.count, 2); XCTAssertTrue(reads.allSatisfy { $0.root == "/r" })
    }
}

/// A transport that can overlap its reads, as `SFTPRemoteFileService` does.
private actor ReadAheadService: RemoteFileService, FolderWalking {
    let folders: [String: [RemoteEntry]]
    let contents: [String: Data]
    let readDelay: Duration
    let listingDelays: [String: Duration]
    let listingErrors: [String: RemoteFileError]
    private(set) var reads: [(path: String, limit: Int)] = []
    private(set) var listed: [String] = []
    /// Reads that had returned when each listing started, by folder.
    private(set) var readsDoneWhenListed: [String: Int] = [:]
    private(set) var mostAtOnce = 0
    private(set) var bytesRead = 0
    private var running = 0, readsDone = 0
    init(folders: [String: [RemoteEntry]], contents: [String: Data], readDelay: Duration = .milliseconds(5), listingDelays: [String: Duration] = [:],
         listingErrors: [String: RemoteFileError] = [:]) {
        self.folders = folders; self.contents = contents; self.readDelay = readDelay; self.listingDelays = listingDelays
        self.listingErrors = listingErrors
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: folders[path] ?? []) }
    func listDirectoryForWalk(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        listed.append(path); readsDoneWhenListed[path] = readsDone
        if let delay = listingDelays[path] { try await Task.sleep(for: delay) }
        if let error = listingErrors[path] { throw error }
        return .init(path: path, entries: folders[path] ?? [])
    }
    func resolvingLinks(in entries: [RemoteEntry], profile: ConnectionProfile) async throws -> [RemoteEntry] { entries }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.invalidPath }
    func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        // As `SFTPRemoteFileService` does first, through `session(for:)`: a cancelled read sends nothing.
        try Task.checkCancellation()
        reads.append((path, limit))
        running += 1; mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1; readsDone += 1 }
        try await Task.sleep(for: readDelay)
        guard let data = contents[path] else { throw RemoteFileError.notFound }
        guard data.count <= limit else { throw RemoteFileError.tooLarge(limit) }
        bytesRead += data.count
        return data
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.notFound }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry { throw RemoteFileError.notFound }
    func disconnect() async {}
}

final class SearchReadAheadTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Read ahead", host: "example.invalid", username: "reader", identityID: UUID())

    /// Folders of text files, the listed size being the real one. Every file holds the query.
    private func tree(folders: Int, files: Int, bytes: Int = 20) -> (folders: [String: [RemoteEntry]], contents: [String: Data]) {
        var listing: [String: [RemoteEntry]] = ["/r": []], contents: [String: Data] = [:]
        for folder in 0..<folders {
            let path = "/r/folder-\(folder)"
            listing["/r", default: []].append(RemoteEntry(name: "folder-\(folder)", path: path, kind: .directory))
            listing[path] = (0..<files).map { index in
                let file = path + "/file-\(index).txt"
                contents[file] = Data(("needle " + String(repeating: "x", count: max(0, bytes - 7))).utf8)
                return RemoteEntry(name: "file-\(index).txt", path: file, kind: .file, size: UInt64(contents[file]!.count))
            }
        }
        return (listing, contents)
    }

    private func search(_ service: any RemoteFileService, limits: RemoteFolderSearch.Limits = .init(),
                        content: RemoteFolderSearch.ContentLimits = .init()) async throws -> (matches: [String], final: RemoteFolderSearch.Update) {
        var matches: [String] = [], final = RemoteFolderSearch.Update()
        for try await update in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: profile, service: service, includeHidden: false,
                                                            limits: limits, contentLimits: content) {
            matches += update.contentMatches.map(\.entry.path); final = update
        }
        return (matches, final)
    }

    func testReadsOverlapButResultsStayInTheOrderOfAReadOneAtATime() async throws {
        let (folders, contents) = tree(folders: 6, files: 8)
        let overlapping = ReadAheadService(folders: folders, contents: contents)
        let (matches, final) = try await search(overlapping)
        let sequential = try await search(PlainTreeService(folders: folders, contents: contents))
        XCTAssertEqual(matches, sequential.matches, "Reading ahead must not change what a search reports or its order")
        XCTAssertEqual(final.filesSearched, sequential.final.filesSearched)
        XCTAssertEqual(final.bytesRead, sequential.final.bytesRead)
        XCTAssertEqual(final.chargedBytes, sequential.final.chargedBytes)
        let most = await overlapping.mostAtOnce, reads = await overlapping.reads
        XCTAssertGreaterThan(most, 1, "The reason for all of this")
        XCTAssertLessThanOrEqual(most, SearchReadAhead.window + 1)
        XCTAssertEqual(reads.count, 48, "Each file once")
    }

    func testReadAheadStaysWithinTheFileLimit() async throws {
        let (folders, contents) = tree(folders: 4, files: 25)
        let service = ReadAheadService(folders: folders, contents: contents)
        let (matches, final) = try await search(service, content: .init(maxFiles: 5))
        XCTAssertEqual(matches.count, 5)
        XCTAssertEqual(final.stop, .fileLimit)
        let reads = await service.reads
        XCTAssertLessThanOrEqual(reads.count, 5, "No file past the limit is even asked for")
    }

    func testReadAheadStaysWithinTheByteBudget() async throws {
        let (folders, contents) = tree(folders: 4, files: 25, bytes: 1_000)
        let service = ReadAheadService(folders: folders, contents: contents)
        let budget = 200_000 // Reservations include the allowance for a file growing, so few can start at once.
        let (_, final) = try await search(service, content: .init(maxTotalBytes: budget))
        let bytes = await service.bytesRead
        XCTAssertLessThanOrEqual(bytes, budget)
        XCTAssertLessThanOrEqual(final.chargedBytes, budget)
        let lean = ReadAheadService(folders: folders, contents: contents)
        let (matches, leanFinal) = try await search(lean, content: .init(maxTotalBytes: 3_000))
        let leanBytes = await lean.bytesRead
        XCTAssertLessThanOrEqual(leanBytes, 3_000, "A budget too small to reserve for still holds")
        XCTAssertEqual(leanFinal.stop, .byteLimit)
        XCTAssertFalse(matches.isEmpty, "And it still reads what fits, one at a time")
    }

    func testLargeFilesAreReadFewerAtATime() async throws {
        let (folders, contents) = tree(folders: 1, files: 8, bytes: 800 * 1024)
        let service = ReadAheadService(folders: folders, contents: contents, readDelay: .milliseconds(30))
        let (matches, _) = try await search(service, content: .init(maxFileBytes: 1024 * 1024))
        XCTAssertEqual(matches.count, 8)
        let most = await service.mostAtOnce
        XCTAssertGreaterThan(most, 1)
        XCTAssertLessThanOrEqual(most, 4, "What is in flight is bounded by its size as well as its number")
    }

    func testAnIndexBuildReadsInTheOrderItKeepsThem() async throws {
        let (folders, contents) = tree(folders: 6, files: 8)
        let overlapping = ReadAheadService(folders: folders, contents: contents)
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: overlapping, includeHidden: false)
        let plain = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: PlainTreeService(folders: folders, contents: contents), includeHidden: false)
        XCTAssertEqual(snapshot.documents.map(\.entry.path), plain.documents.map(\.entry.path))
        XCTAssertEqual(snapshot.documents.count, 48)
        XCTAssertEqual(snapshot.isPartial, plain.isPartial)
        let reads = await overlapping.reads
        XCTAssertEqual(reads.count, 48, "Each file once: reads started in the order they're wanted are never repeated by hand")
    }

    /// A later folder listed first must not read ahead of an earlier one, or the earlier one's ordinary
    /// read would go over the limits.
    func testReadsAheadOfALaterFolderCountTowardsTheLimits() async throws {
        func files(_ sizes: [String: Int]) -> (folders: [String: [RemoteEntry]], contents: [String: Data]) {
            var folders: [String: [RemoteEntry]] = ["/r": [RemoteEntry(name: "a", path: "/r/a", kind: .directory),
                                                           RemoteEntry(name: "b", path: "/r/b", kind: .directory)]]
            var contents: [String: Data] = [:]
            for (path, size) in sizes {
                contents[path] = Data(("needle " + String(repeating: "x", count: size - 7)).utf8)
                folders[RemotePath.parent(of: path), default: []].append(RemoteEntry(name: RemotePath.name(of: path), path: path, kind: .file, size: UInt64(size)))
            }
            return (folders, contents)
        }
        let (folders, contents) = files(["/r/a/large.txt": 200_000, "/r/b/small.txt": 100_000])
        let slowFirst: [String: Duration] = ["/r/a": .milliseconds(150)]
        let oneFile = ReadAheadService(folders: folders, contents: contents, listingDelays: slowFirst)
        let (matches, final) = try await search(oneFile, content: .init(maxFiles: 1))
        let reads = await oneFile.reads
        XCTAssertEqual(reads.map(\.path), ["/r/a/large.txt"], "Only the first file, and nothing ahead of it")
        XCTAssertEqual(matches, ["/r/a/large.txt"])
        XCTAssertEqual(final.stop, .fileLimit)

        let budget = 250_000
        let lean = ReadAheadService(folders: folders, contents: contents, listingDelays: slowFirst)
        let (_, leanFinal) = try await search(lean, content: .init(maxTotalBytes: budget))
        let transferred = await lean.bytesRead
        XCTAssertLessThanOrEqual(transferred, budget, "Everything sent counts, read ahead or not")
        XCTAssertGreaterThanOrEqual(leanFinal.chargedBytes, transferred)
        XCTAssertLessThanOrEqual(leanFinal.chargedBytes, budget)
    }

    /// An index lists before it reads. Files read before the deadline ran out during listing are kept.
    func testAnIndexKeepsWhatWasReadBeforeTheDeadlineRanOutWhileListing() async throws {
        let root = RemoteEntry(name: "root.txt", path: "/r/root.txt", kind: .file, size: 11)
        let late = RemoteEntry(name: "late.txt", path: "/r/slow/late.txt", kind: .file, size: 11)
        let folders: [String: [RemoteEntry]] = ["/r": [root, RemoteEntry(name: "slow", path: "/r/slow", kind: .directory)], "/r/slow": [late]]
        let service = ReadAheadService(folders: folders, contents: ["/r/root.txt": Data("root needle".utf8), "/r/slow/late.txt": Data("late needle".utf8)],
                                       listingDelays: ["/r/slow": .seconds(2)])
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: false,
                                                               limits: .init(timeLimit: .milliseconds(400)))
        XCTAssertEqual(snapshot.documents.map(\.entry.path), ["/r/root.txt"], "Read before the deadline, so kept; the late folder's file never starts")
        XCTAssertTrue(snapshot.isPartial)
        let reads = await service.reads
        XCTAssertEqual(reads.map(\.path), ["/r/root.txt"])
    }

    /// An index lists before it reads, so it must not keep a broad tree in memory for files it will never
    /// read: it keeps what the file limit allows and stops listing where the reads will stop.
    func testAnIndexKeepsOnlyWhatItCanReadAndStopsListingThere() async throws {
        let (folders, contents) = tree(folders: 30, files: 20)
        let service = ReadAheadService(folders: folders, contents: contents)
        let snapshot = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: service, includeHidden: false,
                                                               contentLimits: .init(maxFiles: 10))
        let plain = try await RemoteFolderSearch.buildIndex(below: "/r", profile: profile, service: PlainTreeService(folders: folders, contents: contents),
                                                            includeHidden: false, contentLimits: .init(maxFiles: 10))
        XCTAssertEqual(snapshot.documents.map(\.entry.path), plain.documents.map(\.entry.path), "The same ten, as one at a time")
        XCTAssertEqual(snapshot.documents.count, 10)
        XCTAssertTrue(snapshot.isPartial)
        let reads = await service.reads, listed = await service.listed
        XCTAssertEqual(reads.count, 10)
        XCTAssertLessThan(listed.count, 30, "Listing stops once the reads can't go further")
    }

    func testAFileThatGrewPastItsListingGetsAnOrdinaryRead() async throws {
        var (folders, contents) = tree(folders: 1, files: 3)
        contents["/r/folder-0/file-1.txt"] = Data(("needle " + String(repeating: "y", count: SearchReadAhead.growthAllowance * 2)).utf8)
        let service = ReadAheadService(folders: folders, contents: contents)
        folders.removeAll()
        let (matches, final) = try await search(service)
        XCTAssertEqual(Set(matches), ["/r/folder-0/file-0.txt", "/r/folder-0/file-1.txt", "/r/folder-0/file-2.txt"])
        XCTAssertEqual(final.unreadableFiles, 0)
        let reads = await service.reads
        XCTAssertEqual(reads.filter { $0.path.hasSuffix("file-1.txt") }.count, 2, "Tried ahead, then again with the walk's own limit")
    }

    func testCancellingStopsReadingAhead() async throws {
        let (folders, contents) = tree(folders: 10, files: 50)
        let service = ReadAheadService(folders: folders, contents: contents, readDelay: .milliseconds(50))
        let task = Task {
            for try await _ in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: self.profile, service: service, includeHidden: false) {}
        }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = await task.result
        let atCancel = await service.reads.count
        // The walk winds down in a task of its own, and reads it had already started may still check in,
        // later on a loaded machine. Wait until nothing has arrived for a while, then count.
        var settled = atCancel
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(200))
            let now = await service.reads.count
            if now == settled { break }
            settled = now
        }
        XCTAssertLessThanOrEqual(settled - atCancel, SearchReadAhead.window, "At most the reads already under way, nothing new")
        XCTAssertLessThan(settled, 100, "The walk stopped long before the end of 500 files")
    }
}

/// Live content searches list folders ahead while they read, so a later folder's reads overlap an earlier one's.
final class SearchListingAheadTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Listing ahead", host: "example.invalid", username: "reader", identityID: UUID())

    /// Three levels of folders, `files` text files in each, some holding the query.
    private func deepTree(files: Int = 2) -> (folders: [String: [RemoteEntry]], contents: [String: Data]) {
        var folders: [String: [RemoteEntry]] = [:], contents: [String: Data] = [:]
        func fill(_ path: String, depth: Int) {
            folders[path] = []
            for index in 0..<files {
                let file = path + "/file-\(index).txt"
                contents[file] = Data(((path.count + index) % 3 == 0 ? "a needle here" : "nothing to see").utf8)
                folders[path]!.append(RemoteEntry(name: "file-\(index).txt", path: file, kind: .file, size: UInt64(contents[file]!.count)))
            }
            guard depth < 3 else { return }
            for index in 0..<3 {
                let child = path + "/folder-\(index)"
                folders[path]!.append(RemoteEntry(name: "folder-\(index)", path: child, kind: .directory))
                fill(child, depth: depth + 1)
            }
        }
        fill("/r", depth: 0)
        return (folders, contents)
    }

    private func search(_ service: any RemoteFileService, limits: RemoteFolderSearch.Limits = .init(),
                        content: RemoteFolderSearch.ContentLimits = .init()) async -> (matches: [String], final: RemoteFolderSearch.Update, error: Error?) {
        var matches: [String] = [], final = RemoteFolderSearch.Update()
        do {
            for try await update in RemoteFolderSearch.contents(matching: "needle", below: "/r", profile: profile, service: service, includeHidden: false,
                                                                limits: limits, contentLimits: content) {
                matches += update.contentMatches.map(\.entry.path); final = update
            }
        } catch { return (matches, final, error) }
        return (matches, final, nil)
    }

    /// Whatever the order listings come back in, a search reports what one reading a folder at a time reports.
    func testListingAheadKeepsTheResultsAndAccountingOfAWalkOneFolderAtATime() async throws {
        let (folders, contents) = deepTree()
        var generator = SystemRandomNumberGenerator()
        let cases: [(String, RemoteFolderSearch.Limits, RemoteFolderSearch.ContentLimits, [String: RemoteFileError])] = [
            ("everything", .init(), .init(), [:]),
            ("matches", .init(maxMatches: 5), .init(), [:]),
            ("files", .init(), .init(maxFiles: 9), [:]),
            ("folders", .init(maxFolders: 6), .init(), [:]),
            ("depth", .init(maxDepth: 1), .init(), [:]),
            ("unreadable folder", .init(), .init(), ["/r/folder-0/folder-1": .permissionDenied]),
            ("failing folder", .init(), .init(), ["/r/folder-1/folder-0": .invalidPath]),
        ]
        let shipped = RemoteFolderSearch.liveLookahead
        defer { RemoteFolderSearch.liveLookahead = shipped }
        for (name, limits, content, errors) in cases {
            // One folder listed at a time, and no reading ahead: the walk as it would be without any of this.
            RemoteFolderSearch.liveLookahead = 1
            let plain = await search(PlainTreeService(folders: folders, contents: contents, listingErrors: errors), limits: limits, content: content)
            RemoteFolderSearch.liveLookahead = shipped
            for _ in 0..<3 {
                // Later folders often come back first.
                let delays = Dictionary(uniqueKeysWithValues: folders.keys.map { ($0, Duration.milliseconds(Int.random(in: 0...15, using: &generator))) })
                let ahead = await search(ReadAheadService(folders: folders, contents: contents, readDelay: .milliseconds(3), listingDelays: delays,
                                                          listingErrors: errors), limits: limits, content: content)
                XCTAssertEqual(ahead.matches, plain.matches, name)
                XCTAssertEqual(ahead.final.stop, plain.final.stop, name)
                XCTAssertEqual(ahead.final.filesSearched, plain.final.filesSearched, name)
                XCTAssertEqual(ahead.final.bytesRead, plain.final.bytesRead, name)
                XCTAssertEqual(ahead.final.foldersSearched, plain.final.foldersSearched, name)
                XCTAssertEqual(ahead.final.unreadableFolders, plain.final.unreadableFolders, name)
                XCTAssertEqual(ahead.final.skippedDeepFolders, plain.final.skippedDeepFolders, name)
                XCTAssertEqual(ahead.error.map { String(describing: $0) }, plain.error.map { String(describing: $0) }, name)
                if plain.final.stop == nil, plain.error == nil {
                    XCTAssertEqual(ahead.final.chargedBytes, plain.final.chargedBytes, "\(name): every read was used, so nothing more was charged")
                }
            }
        }
    }

    /// The first folder's second file can't finish until a file of the next folder has started reading, which only
    /// happens if the walk takes that folder's listing before reading on.
    func testAFolderListedBetweenReadsStartsReadingBeforeTheEarlierFolderIsDone() async throws {
        let service = GatedListingService(firstFolder: ["a.txt", "b.txt"], listedOnceStarted: "a.txt", held: "b.txt")
        let (matches, final, error) = await search(service)
        XCTAssertNil(error)
        XCTAssertEqual(matches, ["/r/f0/a.txt", "/r/f0/b.txt", "/r/f1/c.txt"], "In walk order, however the reads overlapped")
        XCTAssertEqual(final.filesSearched, 3)
        let released = await service.heldReadReleasedByNextFolder, reads = await service.reads
        XCTAssertTrue(released, "The next folder's read started while this one was under way")
        XCTAssertEqual(reads.sorted(), ["/r/f0/a.txt", "/r/f0/b.txt", "/r/f1/c.txt"], "Each file once")
    }

    /// The same while the walk waits for the only read it has: the next folder is listed only once that read has
    /// started, and the read can't finish until a file of the next folder has started.
    func testAFolderListedWhileTheWalkWaitsForAReadStartsReadingAtOnce() async throws {
        let service = GatedListingService(firstFolder: ["b.txt"], listedOnceStarted: "b.txt", held: "b.txt")
        let (matches, _, error) = await search(service)
        XCTAssertNil(error)
        XCTAssertEqual(matches, ["/r/f0/b.txt", "/r/f1/c.txt"])
        let released = await service.heldReadReleasedByNextFolder
        XCTAssertTrue(released, "The walk took the listing while it waited")
    }

    /// Reads that can't keep up don't let the listings run away with the tree: a live search lists only so far ahead.
    func testListingAheadStaysWithinItsWindow() async throws {
        var folders: [String: [RemoteEntry]] = ["/r": []], contents: [String: Data] = [:]
        for index in 0..<40 {
            let folder = "/r/folder-\(String(format: "%02d", index))", file = folder + "/file.txt"
            folders["/r"]!.append(RemoteEntry(name: RemotePath.name(of: folder), path: folder, kind: .directory))
            contents[file] = Data("needle".utf8)
            folders[folder] = [RemoteEntry(name: "file.txt", path: file, kind: .file, size: 6)]
        }
        let shipped = RemoteFolderSearch.liveLookahead
        RemoteFolderSearch.liveLookahead = 4
        defer { RemoteFolderSearch.liveLookahead = shipped }
        let service = ReadAheadService(folders: folders, contents: contents, readDelay: .milliseconds(20))
        let (matches, _, error) = await search(service)
        XCTAssertNil(error)
        XCTAssertEqual(matches.count, 40)
        let done = await service.readsDoneWhenListed
        for index in 0..<40 {
            // The folder is the walk's (index + 1)th. It starts once the walk has reported all but four before it, and
            // every reported folder but the one being read has had its file read.
            let folder = "/r/folder-\(String(format: "%02d", index))"
            XCTAssertGreaterThanOrEqual(done[folder] ?? -1, index + 1 - 4 - 2, folder)
        }
    }
}

/// `/r` holds `f0` and `f1`, which holds `c.txt`. `f1` is listed only once the read of `listedOnceStarted` in `f0` has
/// started; `a.txt`'s read returns only once `f1` is listed; `held`'s read waits for `c.txt`'s to start, or gives up
/// after a minute, longer than the search's own 30-second deadline, so a loaded runner can't fail a correct walk.
private actor GatedListingService: RemoteFileService, FolderWalking {
    private(set) var reads: [String] = []
    private(set) var heldReadReleasedByNextFolder = false
    private var started: Set<String> = [], f1Listed = false
    private let folders: [String: [RemoteEntry]]
    private let listedOnceStarted: String, held: String
    init(firstFolder: [String], listedOnceStarted: String, held: String) {
        folders = ["/r": [RemoteEntry(name: "f0", path: "/r/f0", kind: .directory), RemoteEntry(name: "f1", path: "/r/f1", kind: .directory)],
                   "/r/f0": firstFolder.map { RemoteEntry(name: $0, path: "/r/f0/" + $0, kind: .file, size: 6) },
                   "/r/f1": [RemoteEntry(name: "c.txt", path: "/r/f1/c.txt", kind: .file, size: 6)]]
        self.listedOnceStarted = "/r/f0/" + listedOnceStarted; self.held = "/r/f0/" + held
    }
    private func until(_ condition: () -> Bool, seconds: Double) async -> Bool {
        let end = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < end, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: folders[path] ?? []) }
    func listDirectoryForWalk(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        if path == "/r/f1" { _ = await until({ started.contains(listedOnceStarted) }, seconds: 60); f1Listed = true }
        return .init(path: path, entries: folders[path] ?? [])
    }
    func resolvingLinks(in entries: [RemoteEntry], profile: ConnectionProfile) async throws -> [RemoteEntry] { entries }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.invalidPath }
    func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        reads.append(path); started.insert(path)
        if path == "/r/f0/a.txt" { _ = await until({ f1Listed }, seconds: 60) }
        if path == held { heldReadReleasedByNextFolder = await until({ started.contains("/r/f1/c.txt") }, seconds: 60) }
        return Data("needle".utf8)
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.notFound }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry { throw RemoteFileError.notFound }
    func disconnect() async {}
}

/// The same files for a transport without overlapping listings, which reads one at a time.
private actor PlainTreeService: RemoteFileService {
    let folders: [String: [RemoteEntry]], contents: [String: Data], listingErrors: [String: RemoteFileError]
    init(folders: [String: [RemoteEntry]], contents: [String: Data], listingErrors: [String: RemoteFileError] = [:]) {
        self.folders = folders; self.contents = contents; self.listingErrors = listingErrors
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        if let error = listingErrors[path] { throw error }
        return .init(path: path, entries: folders[path] ?? [])
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.invalidPath }
    func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        guard let data = contents[path] else { throw RemoteFileError.notFound }
        guard data.count <= limit else { throw RemoteFileError.tooLarge(limit) }
        return data
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.notFound }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry { throw RemoteFileError.notFound }
    func disconnect() async {}
}
