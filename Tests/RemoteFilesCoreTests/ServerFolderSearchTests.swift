import XCTest
import Foundation
@testable import RemoteFilesCore

final class ServerFolderSearchTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Search", host: "example.invalid", username: "reader", identityID: UUID())

    func testOptionalServerSearchAndFallbackDoNotDuplicateResults() async throws {
        for available in [true, false] {
            let service = SearchCapabilityService(available: available)
            var matches: [String] = [], finished = 0
            for try await update in RemoteFolderSearch.names(matching: "needle", below: "/r", profile: profile,
                                                             service: service, includeHidden: false) {
                matches += update.matches.map(\.path)
                if update.isFinished { finished += 1 }
            }
            XCTAssertEqual(matches, ["/r/needle.txt"])
            XCTAssertEqual(finished, 1)
            let counts = await service.counts
            XCTAssertEqual(counts.attempts, 1)
            XCTAssertEqual(counts.listings, available ? 0 : 1)
        }
    }

    func testCancellationAndTransportErrorsNeverStartFallback() async throws {
        for failure in [RemoteFileError.connectionEnded, .timedOut] {
            let service = SearchCapabilityService(available: false, failure: failure)
            do {
                for try await _ in RemoteFolderSearch.names(matching: "needle", below: "/r", profile: profile,
                                                            service: service, includeHidden: false) {}
                XCTFail("Transport errors must surface")
            } catch { XCTAssertTrue(error is RemoteFileError) }
            let counts = await service.counts
            XCTAssertEqual(counts.listings, 0)
        }
        let service = SearchCapabilityService(available: false, delay: .seconds(10))
        let task = Task {
            for try await _ in RemoteFolderSearch.names(matching: "needle", below: "/r", profile: profile,
                                                        service: service, includeHidden: false) {}
        }
        while await service.counts.attempts == 0 { await Task.yield() }
        task.cancel()
        _ = await task.result
        let counts = await service.counts
        XCTAssertEqual(counts.listings, 0)
    }

    private func response(candidates: [[String: Any]], root: String = "/r", overrides: [String: Any] = [:]) throws -> Data {
        var result: [String: Any] = ["version": 1, "root": root, "candidates": candidates,
            "folders": 1, "unreadableFolders": 0, "deepFolders": 0, "files": 0,
            "skippedFiles": 0, "unreadableFiles": 0, "bytes": 0, "charged": 0]
        result.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: result)
    }

    private func candidate(_ path: String, text: String? = nil) -> [String: Any] {
        var item: [String: Any] = ["path": path, "kind": "file", "size": 10, "modified": 0]
        if let text { item["data"] = Data(text.utf8).base64EncodedString() }
        return item
    }

    func testResponseUsesFoundationMatchingNaturalOrderAndExactMatchLimit() throws {
        let data = try response(candidates: [candidate("/r/needle-10"), candidate("/r/needle-2"),
            candidate("/r/café"), candidate("/r/deep/needle"), candidate("/r/Needle-1")])
        let result = try ServerFolderSearch.decode(data, query: "needle", root: "/r", includeHidden: false,
                                                   limits: .init(maxMatches: 3), content: nil)
        XCTAssertEqual(result.matches.map(\.name), ["Needle-1", "needle-2", "needle-10"])
        XCTAssertEqual(result.stop, .matchLimit)
        let exact = try ServerFolderSearch.decode(data, query: "needle", root: "/r", includeHidden: false,
                                                  limits: .init(maxMatches: 4), content: nil)
        XCTAssertEqual(exact.matches.count, 4)
        XCTAssertNil(exact.stop)
        let unicode = try ServerFolderSearch.decode(data, query: "CAFÉ", root: "/r", includeHidden: false,
                                                    limits: .init(), content: nil)
        XCTAssertEqual(unicode.matches.map(\.name), ["café"])
    }

    func testResponseRejectsEscapesDuplicatesInvalidCountersAndUnexpectedContent() throws {
        for paths in [["/else/needle"], ["/r/../needle"], ["/r//needle"], ["/r/.hidden/needle"], ["/r/needle", "/r/needle"]] {
            XCTAssertThrowsError(try ServerFolderSearch.decode(response(candidates: paths.map { candidate($0) }),
                query: "needle", root: "/r", includeHidden: false, limits: .init(), content: nil))
        }
        XCTAssertThrowsError(try ServerFolderSearch.decode(response(candidates: [], overrides: ["folders": -1]),
            query: "x", root: "/r", includeHidden: false, limits: .init(), content: nil))
        XCTAssertThrowsError(try ServerFolderSearch.decode(response(candidates: [candidate("/r/needle", text: "secret")]),
            query: "x", root: "/r", includeHidden: false, limits: .init(), content: nil))
        XCTAssertThrowsError(try ServerFolderSearch.decode(response(candidates: [], overrides: ["error": "resourceLimit"]),
            query: "x", root: "/r", includeHidden: false, limits: .init(), content: nil)) { error in
            guard case ServerFolderSearch.Failure.resourceLimit = error else { return XCTFail("Limits must not mark a server unsupported") }
        }
        XCTAssertThrowsError(try ServerFolderSearch.command(query: "x", root: "/r", includeHidden: false,
            limits: .init(), content: .init(maxFiles: 501)), "Custom limits must not be silently tightened")
    }

    func testContentCandidatesKeepLiteralUnicodeSnippetsAndBinaryPolicy() throws {
        let data = try response(candidates: [candidate("/r/a.md", text: "first\r\nCafé [x].*\n"),
            candidate("/r/b.txt", text: "nothing"), candidate("/r/c.txt", text: "[x].*\0binary")],
            overrides: ["files": 3, "bytes": 60, "charged": 60])
        let result = try ServerFolderSearch.decode(data, query: "[X].*", root: "/r", includeHidden: false,
                                                   limits: .init(), content: .init())
        XCTAssertEqual(result.contentMatches.count, 1)
        XCTAssertEqual(result.contentMatches.first?.line, 2)
        XCTAssertEqual(result.contentMatches.first?.snippet, "Café [x].*")
    }

    func testRootHandleRequiresOneNewDescriptorWithTheExactSFTPTarget() throws {
        let before = ["0": "/dev/null", "3": "/elsewhere"]
        let after = before.merging(["4": "/docs"]) { _, new in new }
        XCTAssertEqual(try SFTPRemoteFileService.searchRootHandle(process: "/proc/123", root: "/docs", before: before, after: after),
                       "/proc/123/fd/4")
        for invalid in [before, before.merging(["4": "/other/docs"]) { _, new in new },
                        before.merging(["4": "/docs", "5": "/docs"]) { _, new in new },
                        before.merging(["../4": "/docs"]) { _, new in new }] {
            XCTAssertThrowsError(try SFTPRemoteFileService.searchRootHandle(process: "/proc/123", root: "/docs", before: before, after: invalid))
        }
        for process in ["/proc/self", "/proc/0", "/proc/123/../456", "/virtual/proc/123"] {
            XCTAssertThrowsError(try SFTPRemoteFileService.searchRootHandle(process: process, root: "/docs", before: before, after: after))
        }
    }

    #if os(macOS)
    private func runHelper(root: String, query: String, hidden: Bool = false,
                           limits: RemoteFolderSearch.Limits = .init(), content: RemoteFolderSearch.ContentLimits? = nil,
                           handleRoot: String? = nil, provideHandle: Bool = true) throws -> RemoteFolderSearch.Update {
        let helper = try ServerFolderSearch.command(query: query, root: root, includeHidden: hidden, limits: limits, content: content,
                                                     rootHandle: provideHandle ? "/dev/fd/9" : nil)
        let command = "exec 9<" + ServerFolderSearch.quote(handleRoot ?? root) + "; " + helper
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return try ServerFolderSearch.decode(data, query: query, root: root, includeHidden: hidden, limits: limits, content: content)
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("search-\(UUID().uuidString)-'$(touch INJECTION);\n")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        for (name, text) in [("needle-10.txt", "No matching source"), ("needle-2.txt", "Start\nNEEDLE literal [x].*"),
                             ("sub/café.txt", "Café needle"), (".hidden/needle.txt", "needle"), ("binary.txt", "needle\0") ] {
            try Data(text.utf8).write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("needle-link").path, withDestinationPath: "/")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testHelperSearchesNamesAndContentsWithoutFollowingLinksAndQuotesHostilePaths() throws {
        let root = try fixture()
        let names = try runHelper(root: root.path, query: "needle")
        XCTAssertEqual(names.matches.map(\.name), ["needle-2.txt", "needle-10.txt", "needle-link"])
        XCTAssertEqual(names.foldersSearched, 2)
        let contents = try runHelper(root: root.path, query: "needle", content: .init())
        XCTAssertEqual(contents.contentMatches.map(\.entry.name), ["needle-2.txt", "café.txt"])
        XCTAssertEqual(contents.skippedFiles, 2, "Binary and symbolic link")
        let hidden = try runHelper(root: root.path, query: "needle", hidden: true)
        XCTAssertEqual(hidden.foldersSearched, 3)
        XCTAssertEqual(hidden.matches.count, 4)
        let literal = try runHelper(root: root.path, query: "[x].*", content: .init())
        XCTAssertEqual(literal.contentMatches.map(\.entry.name), ["needle-2.txt"])
        let injection = try runHelper(root: root.path, query: "';$(touch INJECTION)\n", content: .init())
        XCTAssertTrue(injection.contentMatches.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("INJECTION").path))
    }

    func testHelperEnforcesDepthFolderFileByteAndTimeLimits() throws {
        let root = try fixture()
        let shallow = try runHelper(root: root.path, query: "needle", limits: .init(maxDepth: 0))
        XCTAssertEqual(shallow.foldersSearched, 1); XCTAssertEqual(shallow.skippedDeepFolders, 1)
        let folders = try runHelper(root: root.path, query: "needle", limits: .init(maxFolders: 1))
        XCTAssertEqual(folders.stop, .folderLimit)
        let files = try runHelper(root: root.path, query: "needle", content: .init(maxFiles: 1))
        XCTAssertEqual(files.stop, .fileLimit); XCTAssertEqual(files.filesSearched, 1)
        let bytes = try runHelper(root: root.path, query: "needle", content: .init(maxTotalBytes: 3))
        XCTAssertEqual(bytes.stop, .byteLimit); XCTAssertLessThanOrEqual(bytes.chargedBytes, 3)
        let timed = try runHelper(root: root.path, query: "needle", limits: .init(timeLimit: .nanoseconds(1)))
        XCTAssertEqual(timed.stop, .timeLimit)

    }

    func testHelperRequiresHeldDirectoryAndIgnoresDifferentExecNamespace() throws {
        let sftpRoot = try fixture(), execRoot = try fixture()
        try Data("SFTP needle".utf8).write(to: sftpRoot.appendingPathComponent("identity.txt"))
        try Data("EXEC secret needle".utf8).write(to: execRoot.appendingPathComponent("identity.txt"))
        XCTAssertThrowsError(try runHelper(root: execRoot.path, query: "needle", content: .init(), provideHandle: false)) {
            guard case ServerFolderSearch.Failure.unsupported = $0 else { return XCTFail("Missing identity must fall back") }
        }
        // Both namespaces can contain the same absolute path and matching metadata. The helper
        // must scan the held SFTP directory and must never reopen the exec-visible path.
        let result = try runHelper(root: execRoot.path, query: "needle", content: .init(), handleRoot: sftpRoot.path)
        let match = try XCTUnwrap(result.contentMatches.first { $0.entry.name == "identity.txt" })
        XCTAssertEqual(match.entry.path, execRoot.appendingPathComponent("identity.txt").path)
        XCTAssertEqual(match.snippet, "SFTP needle")
        XCTAssertFalse(result.contentMatches.contains { $0.snippet.contains("EXEC secret") })
    }

    func testHelperDeadlineCleanupAlwaysReturnsACompleteResponse() throws {
        let root = try fixture()
        for _ in 0..<3 {
            for budget: Duration in [.nanoseconds(1), .microseconds(1), .microseconds(100), .milliseconds(1)] {
                let result = try runHelper(root: root.path, query: "needle", limits: .init(timeLimit: budget))
                XCTAssertTrue(result.isFinished)
                XCTAssertTrue(result.stop == nil || result.stop == .timeLimit)
            }
        }
    }
    #endif
}

private actor SearchCapabilityService: RemoteFileService, ServerFolderSearching {
    let available: Bool
    let failure: RemoteFileError?
    let delay: Duration
    var counts = (attempts: 0, listings: 0)
    init(available: Bool, failure: RemoteFileError? = nil, delay: Duration = .zero) {
        self.available = available; self.failure = failure; self.delay = delay
    }
    func searchFolders(query: String, root: String, profile: ConnectionProfile, includeHidden: Bool,
                       limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?) async throws -> RemoteFolderSearch.Update? {
        counts.attempts += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        guard available else { return nil }
        var result = RemoteFolderSearch.Update()
        result.matches = [RemoteEntry(name: "needle.txt", path: "/r/needle.txt", kind: .file)]
        result.isFinished = true
        return result
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        counts.listings += 1
        return .init(path: path, entries: [RemoteEntry(name: "needle.txt", path: "/r/needle.txt", kind: .file)])
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}
