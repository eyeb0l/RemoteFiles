import XCTest
import Foundation
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
}
