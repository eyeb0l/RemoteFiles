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
        var result: [String: Any] = ["version": 2, "root": root, "candidates": candidates,
            "folders": 1, "unreadableFolders": 0, "deepFolders": 0, "files": 0,
            "skippedFiles": 0, "unreadableFiles": 0, "bytes": 0, "charged": 0, "final": true]
        result.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: result) + Data("\n".utf8)
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
        XCTAssertThrowsError(try ServerFolderSearch.helper(query: "x", root: "/r", includeHidden: false,
            limits: .init(), content: .init(maxFiles: 501)), "Custom limits must not be silently tightened")
    }

    /// On a server shared with other accounts, all of them can read a process's arguments. The
    /// query and the folder are therefore read by the helper, not passed to it.
    func testTheRequestIsReadFromStandardInputAndIsNotAnArgument() throws {
        let helper = try ServerFolderSearch.helper(query: "quarterly-secret", root: "/srv/private-project", includeHidden: false,
                                                   limits: .init(), content: .init())
        let line = try XCTUnwrap(String(data: helper.input, encoding: .utf8))
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "One line, so the helper need not wait for the end of its input")
        let encoded = String(line.dropLast())
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: encoded))) as? [String: Any])
        XCTAssertEqual(fields["query"] as? String, "quarterly-secret")
        XCTAssertEqual(fields["root"] as? String, "/srv/private-project")
        for hidden in ["quarterly-secret", "private-project", encoded] {
            XCTAssertFalse(helper.command.contains(hidden), "The command line must not carry \(hidden.prefix(24))")
        }
        XCTAssertTrue(helper.command.hasPrefix("python3 -I -S -B -c '"))
        XCTAssertTrue(helper.command.hasSuffix("'"), "Nothing follows the script")
    }

    /// A backslash is an ordinary byte in a name on the server, so a reply naming one is kept.
    func testResponseKeepsNamesHoldingABackslash() throws {
        let paths = ["/r/C:\\needle.txt", "/r/dir\\x/needle", "/r/a\\..\\needle.txt"]
        let result = try ServerFolderSearch.decode(response(candidates: paths.map { candidate($0) }),
            query: "needle", root: "/r", includeHidden: false, limits: .init(), content: nil)
        XCTAssertEqual(Set(result.matches.map(\.path)), Set(paths))
        let contents = try ServerFolderSearch.decode(response(candidates: paths.map { candidate($0, text: "a needle") },
            overrides: ["files": 3, "bytes": 24, "charged": 24]), query: "needle", root: "/r", includeHidden: false, limits: .init(), content: .init())
        XCTAssertEqual(Set(contents.contentMatches.map(\.entry.path)), Set(paths))
    }

    private func outputDecoder(query: String = "needle", limits: RemoteFolderSearch.Limits = .init(),
                               content: RemoteFolderSearch.ContentLimits? = nil) -> ServerFolderSearch.OutputDecoder {
        ServerFolderSearch.OutputDecoder(query: query, root: "/r", includeHidden: false, limits: limits, content: content)
    }

    func testLinesReportMatchesAsTheyArriveHoweverTheyAreSplit() throws {
        let first = try response(candidates: [candidate("/r/needle-1")], overrides: ["final": false])
        let second = try response(candidates: [candidate("/r/deep/needle-2")], overrides: ["folders": 2, "final": false])
        let last = try response(candidates: [candidate("/r/deep/needle-3")], overrides: ["folders": 3])
        let output = first + second + last
        for size in [1, 3, 17, output.count] {
            var decoder = outputDecoder()
            var names: [String] = [], reports = 0
            var offset = 0
            while offset < output.count {
                let end = min(offset + size, output.count)
                for update in try decoder.consume(output[offset..<end]) {
                    names += update.matches.map(\.name); reports += 1
                    XCTAssertFalse(update.isFinished)
                }
                offset = end
            }
            let final = try decoder.finish()
            XCTAssertEqual(reports, 2)
            XCTAssertEqual(names, ["needle-1", "needle-2"])
            XCTAssertEqual(final.matches.map(\.name), ["needle-3"])
            XCTAssertEqual(final.foldersSearched, 3)
            XCTAssertTrue(final.isFinished)
        }
    }

    func testOutputWithoutAFinalLineOrWithAnythingAfterItIsRejected() throws {
        var unfinished = outputDecoder()
        _ = try unfinished.consume(try response(candidates: [candidate("/r/needle")], overrides: ["final": false]))
        XCTAssertThrowsError(try unfinished.finish(), "A helper that dies part way isn't a finished search")
        var cut = outputDecoder()
        _ = try cut.consume(try response(candidates: []).dropLast(5))
        XCTAssertThrowsError(try cut.finish())
        var after = outputDecoder()
        XCTAssertThrowsError(try after.consume(try response(candidates: []) + response(candidates: [candidate("/r/needle")])))
        var version = outputDecoder()
        XCTAssertThrowsError(try version.consume(try response(candidates: [], overrides: ["version": 1])))
    }

    func testLimitsAndDuplicatesHoldAcrossLines() throws {
        let line = { (path: String) in try self.response(candidates: [self.candidate(path)], overrides: ["final": false]) }
        var duplicate = outputDecoder()
        _ = try duplicate.consume(try line("/r/needle"))
        XCTAssertThrowsError(try duplicate.consume(try line("/r/needle")))
        // One folder's two spellings of a name are two files on the server.
        var spellings = outputDecoder(query: "caf")
        _ = try spellings.consume(try line("/r/caf\u{E9}"))
        XCTAssertNoThrow(try spellings.consume(try line("/r/cafe\u{301}")))
        var many = outputDecoder(query: "zz")
        let thousands = try response(candidates: (0..<(ServerFolderSearch.candidateLimit / 2 + 1)).map { candidate("/r/needle-\($0)") }, overrides: ["final": false])
        _ = try many.consume(thousands)
        let more = try response(candidates: (0..<(ServerFolderSearch.candidateLimit / 2 + 1)).map { candidate("/r/other-\($0)") }, overrides: ["final": false])
        XCTAssertThrowsError(try many.consume(more), "The candidate limit covers the whole output")
        var bytes = outputDecoder(query: "x", content: .init())
        let text = "x"
        _ = try bytes.consume(try response(candidates: [candidate("/r/a.txt", text: text)], overrides: ["files": 1, "bytes": 1, "charged": 1, "final": false]))
        XCTAssertThrowsError(try bytes.consume(try response(candidates: [candidate("/r/b.txt", text: text)], overrides: ["files": 2, "bytes": 1, "charged": 1, "final": false])),
                             "Bytes delivered can't exceed what the helper says it read, over all lines")
    }

    func testMatchLimitStopsListeningOnceExceededAndKeepsWhatTheLastLineFound() throws {
        var decoder = outputDecoder(limits: .init(maxMatches: 2))
        let output = try response(candidates: [candidate("/r/needle-1"), candidate("/r/needle-2")], overrides: ["final": false])
            + response(candidates: [candidate("/r/needle-3")], overrides: ["folders": 2, "final": false])
            + response(candidates: [candidate("/r/needle-4")], overrides: ["folders": 3])
        var names: [String] = []
        for update in try decoder.consume(output) { names += update.matches.map(\.name) }
        XCTAssertEqual(names, ["needle-1", "needle-2"])
        XCTAssertTrue(decoder.isAtMatchLimit)
        let final = try decoder.finish()
        XCTAssertEqual(final.stop, .matchLimit)
        XCTAssertTrue(final.isFinished)
        XCTAssertTrue(final.matches.isEmpty)

        // The final line itself crossing the limit keeps the matches that fit.
        var ending = outputDecoder(limits: .init(maxMatches: 2))
        let found = try ending.consume(try response(candidates: [candidate("/r/needle-1"), candidate("/r/needle-2"), candidate("/r/needle-3")]))
        XCTAssertTrue(found.isEmpty)
        let last = try ending.finish()
        XCTAssertEqual(last.matches.map(\.name), ["needle-1", "needle-2"])
        XCTAssertEqual(last.stop, .matchLimit)

        // Reaching the limit exactly isn't stopping early.
        var exact = outputDecoder(limits: .init(maxMatches: 1))
        _ = try exact.consume(try response(candidates: [candidate("/r/needle-1")]))
        XCTAssertFalse(exact.isAtMatchLimit)
        XCTAssertNil(try exact.finish().stop)
    }

    func testAWalkAfterAServerGivesUpPartWayRepeatsNothingAndCountsWhatItFound() async throws {
        for (name, limit, expected) in [("no limit", 500, ["/r/needle-1.txt", "/r/needle-2.txt", "/r/needle-3.txt"]),
                                        ("limit counts what was delivered", 2, ["/r/needle-1.txt", "/r/needle-2.txt"])] {
            let service = SearchCapabilityService(available: false, partialPaths: ["/r/needle-1.txt"],
                                                  listed: ["/r/needle-1.txt", "/r/needle-2.txt", "/r/needle-3.txt"])
            var matches: [String] = [], finished = 0
            for try await update in RemoteFolderSearch.names(matching: "needle", below: "/r", profile: profile, service: service,
                                                             includeHidden: false, limits: .init(maxMatches: limit)) {
                matches += update.matches.map(\.path)
                if update.isFinished { finished += 1 }
            }
            XCTAssertEqual(matches, expected, name)
            XCTAssertEqual(finished, 1, name)
        }
    }

    func testAPartialReportIsKeptWhenTheServerThenFails() async throws {
        let service = SearchCapabilityService(available: false, failure: .connectionEnded, partialPaths: ["/r/needle-1.txt"])
        var matches: [String] = []
        do {
            for try await update in RemoteFolderSearch.names(matching: "needle", below: "/r", profile: profile,
                                                             service: service, includeHidden: false) {
                matches += update.matches.map(\.path)
            }
            XCTFail("Transport errors must surface")
        } catch { XCTAssertTrue(error is RemoteFileError) }
        XCTAssertEqual(matches, ["/r/needle-1.txt"])
        let counts = await service.counts
        XCTAssertEqual(counts.listings, 0)
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

    /// A server need not run the helper as written, so the app can't rely on what it filters.
    func testHostileResponseCannotDeliverAKeyAsAMatch() throws {
        let key = SyntheticKey.pem()
        let fragment = try XCTUnwrap(SyntheticKey.fragments(of: key).first)
        let data = try response(candidates: [candidate("/r/id_rsa", text: key), candidate("/r/.server.key", text: key)],
                                overrides: ["files": 2, "bytes": key.utf8.count * 2, "charged": key.utf8.count * 2])
        let result = try ServerFolderSearch.decode(data, query: fragment, root: "/r", includeHidden: true, limits: .init(), content: .init())
        XCTAssertEqual(result.contentMatches.count, 0)
    }

    func testKernelRootIdentityRequiresUnambiguousInodeMountAndNamespace() throws {
        let identity = try ServerFolderSearch.RootIdentity(fdinfo: "pos:\t0\nflags:\t0100000\nmnt_id:\t42\nino:\t123456\n", namespace: "mnt:[4026531840]")
        XCTAssertEqual(identity.inode, 123456); XCTAssertEqual(identity.mountID, 42)
        for info in ["mnt_id: 42", "ino: 1", "ino: -1\nmnt_id: 42", "ino: 0\nmnt_id: 42",
                     "ino: 1\nino: 2\nmnt_id: 42", "ino: 1\nmnt_id: 42\nmnt_id: 43"] {
            XCTAssertThrowsError(try ServerFolderSearch.RootIdentity(fdinfo: info, namespace: "mnt:[123]"))
        }
        for namespace in ["/proc/self/ns/mnt", "pid:[123]", "mnt:[abc]", "mnt:[123]\n"] {
            XCTAssertThrowsError(try ServerFolderSearch.RootIdentity(fdinfo: "ino: 1\nmnt_id: 42", namespace: namespace))
        }
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
        let data = try helperOutput(root: root, query: query, content: content, hidden: hidden, limits: limits, handleRoot: handleRoot, provideHandle: provideHandle)
        return try ServerFolderSearch.decode(data, query: query, root: root, includeHidden: hidden, limits: limits, content: content)
    }

    private func helperOutput(root: String, query: String, content: RemoteFolderSearch.ContentLimits? = nil, hidden: Bool = false,
                              limits: RemoteFolderSearch.Limits = .init(), handleRoot: String? = nil, provideHandle: Bool = true) throws -> Data {
        let helper = try ServerFolderSearch.helper(query: query, root: root, includeHidden: hidden, limits: limits, content: content,
                                                   rootHandle: provideHandle ? "/dev/fd/9" : nil)
        let command = "exec 9<" + ServerFolderSearch.quote(handleRoot ?? root) + "; " + helper.command
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        // As over SSH: the request is written and the input left open, so the helper must not wait for its end.
        try input.fileHandleForWriting.write(contentsOf: helper.input)
        defer { try? input.fileHandleForWriting.close() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        return data
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

    func testHelperFindsNamesHoldingABackslashBelowARootHoldingOne() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("search-\(UUID().uuidString)-C:\\share")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub\\dir"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["C:\\needle.txt", "sub\\dir/a\\..\\needle.md"] {
            try Data("a needle".utf8).write(to: root.appendingPathComponent(name))
        }
        let names = try runHelper(root: root.path, query: "needle")
        XCTAssertEqual(Set(names.matches.map(\.path)), [root.path + "/C:\\needle.txt", root.path + "/sub\\dir/a\\..\\needle.md"])
        let contents = try runHelper(root: root.path, query: "needle", content: .init())
        XCTAssertEqual(Set(contents.contentMatches.map(\.entry.name)), ["C:\\needle.txt", "a\\..\\needle.md"])
    }

    func testHelperWritesAsItGoesAndEveryLineStandsAlone() throws {
        let root = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        for index in 0..<40 { try Data("needle \(index)".utf8).write(to: root.appendingPathComponent("sub/deeper/needle-\(index).txt")) }
        let output = try helperOutput(root: root.path, query: "needle", content: .init())
        let lines = output.split(separator: UInt8(ascii: "\n"))
        XCTAssertGreaterThan(lines.count, 1, "The first results don't wait for the rest")
        let decoded = try lines.map { try JSONDecoder().decode(ServerFolderSearch.Response.self, from: Data($0)) }
        XCTAssertEqual(decoded.filter(\.final).count, 1)
        XCTAssertTrue(try XCTUnwrap(decoded.last).final)
        XCTAssertEqual(Set(decoded.flatMap(\.candidates).map(\.path)).count, decoded.flatMap(\.candidates).count, "No candidate twice")
    }

    /// Lines arrive a folder at a time, so the app's order within a folder survives streaming, and the
    /// helper walks folders in nearly the app's order: an accent or case doesn't move one past another.
    func testHelperKeepsTheAppsOrderAcrossLinesAndAtTheMatchLimit() throws {
        let root = try fixture()
        for (path, text) in [("order/b.txt", "needle"), ("order/\u{E4}.txt", "needle"), ("order/B-2.txt", "needle")] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("order"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        let first = try runHelper(root: root.path + "/order", query: "needle", limits: .init(maxMatches: 1), content: .init())
        XCTAssertEqual(first.contentMatches.map(\.entry.name), ["\u{E4}.txt"], "Foundation puts ä first, so it's the one kept")
        let all = try runHelper(root: root.path + "/order", query: "needle", content: .init())
        let names = all.contentMatches.map(\.entry.name)
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        for folder in ["\u{C4}rger", "Zebra", "apfel"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folders/\(folder)"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("folders/\(folder)/needle.txt"))
        }
        let walked = try runHelper(root: root.path + "/folders", query: "needle")
        XCTAssertEqual(walked.matches.map { RemotePath.name(of: RemotePath.parent(of: $0.path)) }, ["apfel", "\u{C4}rger", "Zebra"])
    }

    func testHelperTreatsAFilesTypeAsTheDirectoryReportsIt() throws {
        let root = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("needle-folder"), withIntermediateDirectories: true)
        try Data("needle".utf8).write(to: root.appendingPathComponent("needle-folder/inner-needle.txt"))
        let names = try runHelper(root: root.path, query: "needle")
        XCTAssertEqual(names.matches.first { $0.name == "needle-folder" }?.kind, .directory)
        XCTAssertEqual(names.matches.first { $0.name == "needle-link" }?.kind, .symlink)
        XCTAssertEqual(names.matches.first { $0.name == "needle-2.txt" }?.kind, .file)
        XCTAssertTrue(names.matches.contains { $0.name == "inner-needle.txt" })
        XCTAssertNotNil(names.matches.first { $0.name == "needle-2.txt" }?.size)
    }

    func testHelperFindsTheSameBinaryFilesAsCheckingEveryByte() throws {
        let root = try fixture()
        for byte in UInt8(0)...UInt8(255) {
            try (Data("needle ".utf8) + Data([byte])).write(to: root.appendingPathComponent("byte-\(byte).txt"))
        }
        let result = try helperOutput(root: root.path, query: "needle", content: .init(), hidden: false)
        let paths = Set(result.split(separator: UInt8(ascii: "\n")).flatMap { line -> [String] in
            ((try? JSONDecoder().decode(ServerFolderSearch.Response.self, from: Data(line)))?.candidates ?? []).map(\.path)
        })
        for byte in UInt8(0)...UInt8(127) {
            // Bytes above ASCII here aren't valid UTF-8, so those files don't count as text.
            let isControl = (byte < 32 && ![9, 10, 13].contains(byte)) || byte == 127
            XCTAssertEqual(paths.contains(root.appendingPathComponent("byte-\(byte).txt").path), !isControl, "Byte \(byte)")
        }
    }

    func testHelperNeverReturnsTheContentsOfCertificateFilesEvenHidden() throws {
        let root = try fixture()
        let before = try runHelper(root: root.path, query: "needle", hidden: true, content: .init())
        // Built up so secret scanners don't flag this file. A dotfile counts as text by name alone.
        let keyed = "-----BEGIN PRIVATE" + " KEY-----\nneedle\n-----END PRIVATE" + " KEY-----\n"
        for name in ["server.pem", ".server.pem", ".a.crt", ".a.cer", ".a.der", ".a.p7b", ".a.p7c", ".a.csr", ".a.p12", ".a.pfx"] {
            try Data(keyed.utf8).write(to: root.appendingPathComponent(name))
        }
        let contents = try runHelper(root: root.path, query: "needle", hidden: true, content: .init())
        let suffixes = [".pem", ".crt", ".cer", ".der", ".p7b", ".p7c", ".csr", ".p12", ".pfx"]
        for match in contents.contentMatches {
            XCTAssertFalse(match.snippet.contains("PRIVATE"), match.entry.name)
            XCTAssertFalse(suffixes.contains(where: match.entry.name.hasSuffix), match.entry.name)
        }
        XCTAssertFalse(contents.contentMatches.isEmpty, "The ordinary files still match")
        XCTAssertEqual(contents.filesSearched, before.filesSearched, "The helper doesn't even send their bytes back to the app")
    }

    /// The helper sends back a whole file when its text matches, and the app is what decides.
    /// A real server's files, and the full round trip through the helper script.
    func testKeysInOrdinaryFilesFoundOnTheServerNeverBecomeMatches() throws {
        let root = try fixture()
        let key = SyntheticKey.pem()
        let fragment = try XCTUnwrap(SyntheticKey.fragments(of: key).first)
        let mixed = "first\n\n" + key + "\nserverneedle after the key\n"
        for name in ["id_rsa", ".server.key", "server.pem.txt"] { try Data(key.utf8).write(to: root.appendingPathComponent(name)) }
        try Data(mixed.utf8).write(to: root.appendingPathComponent("notes.txt"))

        let probed = try runHelper(root: root.path, query: fragment, hidden: true, content: .init())
        XCTAssertEqual(probed.contentMatches.count, 0)
        let found = try runHelper(root: root.path, query: "serverneedle", hidden: true, content: .init())
        let match = try XCTUnwrap(found.contentMatches.first { $0.entry.name == "notes.txt" })
        XCTAssertEqual(match.line, (mixed.components(separatedBy: "serverneedle").first ?? "").reduce(1) { $1.isNewline ? $0 + 1 : $0 })
        let marker = try runHelper(root: root.path, query: "BEGIN RSA", hidden: true, content: .init())
        XCTAssertEqual(marker.contentMatches.map(\.entry.name), ["notes.txt"], "A file that's only a key has no text to match")
        XCTAssertFalse(marker.contentMatches[0].snippet.contains(fragment))
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
    let partialPaths: [String]
    let listed: [String]
    var counts = (attempts: 0, listings: 0)
    init(available: Bool, failure: RemoteFileError? = nil, delay: Duration = .zero, partialPaths: [String] = [], listed: [String] = ["/r/needle.txt"]) {
        self.available = available; self.failure = failure; self.delay = delay; self.partialPaths = partialPaths; self.listed = listed
    }
    func searchFolders(query: String, root: String, profile: ConnectionProfile, includeHidden: Bool,
                       limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?,
                       partial: @escaping @Sendable (RemoteFolderSearch.Update) -> Void) async throws -> RemoteFolderSearch.Update? {
        counts.attempts += 1
        if !partialPaths.isEmpty {
            var update = RemoteFolderSearch.Update()
            update.matches = partialPaths.map { RemoteEntry(name: RemotePath.name(of: $0), path: $0, kind: .file) }
            partial(update)
        }
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
        return .init(path: path, entries: listed.map { RemoteEntry(name: RemotePath.name(of: $0), path: $0, kind: .file) })
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}
