import XCTest
import Foundation
@testable import RemoteFilesCore
@testable import RemoteFilesUI

/// The fast paths must agree with the slower definitions they replace, on every kind of name.
final class FolderListingTests: XCTestCase {
    private static let awkwardNames = [
        "a", "A", "b", "file2", "file10", "File2", "file02", "file 2", "file-2", "file_2", "file.2", "résumé", "resume", "RÉSUMÉ",
        "re\u{301}sume\u{301}", "caf\u{E9}", "cafe\u{301}", "東京", "東京タワー", "ｆｕｌｌ", "full", "Ⅷ", "VIII", "😀", "😀😀", "🇬🇧", "ß", "ss", "SS",
        "İ", "i", "I", "ı", "Σ", "σ", "ς", "K", "\u{212A}", "ﬁ", "fi", "\u{FEFF}zero", "zero", "\u{200D}join", "join", ".hidden", "..double", "...",
        "with space", "with\ttab", "with\nnewline", "trailing ", " leading", "UPPER.TXT", "lower.txt", "archive.tar.gz", "noextension", ".env", "a.b.C",
        "1", "01", "001", "1a", "1 a", "9", "10", "100", "١٢٣", "١", "%20", "a%2Fb", "*", "?", "[x]", "\\", "~", "`",
    ]

    private func entries() -> [RemoteEntry] {
        var result: [RemoteEntry] = []
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, name) in Self.awkwardNames.enumerated() {
            let path = "/p/" + name
            switch index % 6 {
            case 0:
                result.append(.init(name: name, path: path, kind: .directory, modifiedAt: date.addingTimeInterval(Double(index % 5))))
            case 1:
                result.append(.init(name: name, path: path, kind: .file, size: UInt64(index % 7), modifiedAt: date.addingTimeInterval(Double(index % 3))))
            case 2:
                result.append(.init(name: name, path: path, kind: .file))
            case 3:
                let target = RemoteEntry(name: name, path: "/t/" + name, kind: index % 4 == 0 ? .directory : .file, size: 7, modifiedAt: date)
                result.append(.init(name: name, path: path, kind: .symlink, link: .target(target)))
            case 4:
                result.append(.init(name: name, path: path, kind: .symlink, link: .broken))
            default:
                result.append(.init(name: name, path: path, kind: .other, size: UInt64.max, modifiedAt: nil))
            }
        }
        return result + BenchmarkData.entries(count: 2_000, parent: "/p")
    }

    func testNameOrderMatchesTheDefinition() {
        let entries = entries()
        for seed in 0..<3 {
            var generator = SeededGenerator(state: UInt64(seed + 1))
            let shuffled = entries.shuffled(using: &generator)
            XCTAssertEqual(FolderListing.sortedByName(shuffled).map(\.path),
                           shuffled.sorted { FolderListing.precedes($0, $1, by: .name) }.map(\.path))
        }
        XCTAssertEqual(FolderListing.sortedByName([]).count, 0)
    }

    func testEveryOtherOrderMatchesTheDefinition() {
        let rows = FolderListing(DirectorySnapshot(path: "/p", entries: entries())).rows
        for order in FolderSortOrder.allCases {
            XCTAssertEqual(FolderListing.sorted(rows, by: order).map(\.id),
                           rows.sorted { FolderListing.precedes($0.entry, $1.entry, by: order) }.map(\.id), "\(order)")
        }
        XCTAssertTrue(FolderListing.sorted([], by: .kind).isEmpty)
    }

    func testFilterMatchesFoundationOnEveryName() {
        let names = Self.awkwardNames + BenchmarkData.entries(count: 500).map(\.name)
        let queries = ["a", "A", "fi", "ss", "SS", "resume", "RESUME", "résumé", "e\u{301}", "2", "file", "FILE2", ".", " ", "k", "K", "i", "I", "東", "😀",
                       "tar.gz", "zero", "join", "report", "%", "\\", "*", "s", "\t", "\u{7F}", "a\u{0}"]
        let everyOption = [SearchQueryOptions(), .init(caseSensitive: true), .init(wholeWord: true), .init(caseSensitive: true, wholeWord: true)]
        for options in everyOption {
            for query in queries {
                let filter = FolderFilter(query: query, options: options)
                for name in names {
                    let entry = RemoteEntry(name: name, path: "/p/" + name, kind: .file)
                    XCTAssertEqual(filter.accepts(entry), options.range(in: name, query: query) != nil, "\(query.debugDescription) in \(name.debugDescription) \(options)")
                }
            }
        }
    }

    func testFilterAgreesWithFoundationOnRandomPrintableText() {
        var generator = SeededGenerator(state: 42)
        let alphabet = Array("abcdefgABCDEFG0123 ._-")
        func text(_ length: Int) -> String { String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }) }
        for _ in 0..<3_000 {
            let name = text(Int.random(in: 0..<24, using: &generator)), query = text(Int.random(in: 1..<5, using: &generator))
            for options in [SearchQueryOptions(), .init(caseSensitive: true), .init(wholeWord: true)] {
                let entry = RemoteEntry(name: name, path: "/p/x", kind: .file)
                XCTAssertEqual(FolderFilter(query: query, options: options).accepts(entry), options.range(in: name, query: query) != nil, "\(query) in \(name)")
            }
        }
    }

    func testFilterBoundaries() {
        func accepted(_ query: String, in name: String, caseSensitive: Bool = false) -> Bool {
            FolderFilter(query: query, options: .init(caseSensitive: caseSensitive)).accepts(.init(name: name, path: "/" + name, kind: .file))
        }
        XCTAssertTrue(accepted("c", in: "abc"), "At the very end")
        XCTAssertTrue(accepted("a", in: "abc"), "At the very start")
        XCTAssertTrue(accepted("abc", in: "abc"), "The whole name")
        XCTAssertFalse(accepted("abcd", in: "abc"), "Longer than the name")
        XCTAssertFalse(accepted("a", in: ""), "An empty name")
        XCTAssertFalse(accepted("bc", in: "AbC", caseSensitive: true))
        XCTAssertTrue(accepted("bC", in: "AbC", caseSensitive: true))
        XCTAssertTrue(accepted("BC", in: "abc"))
        XCTAssertTrue(accepted("", in: "abc"), "An empty query with no extension lets everything through")
    }

    func testVisibleKeepsItsOrderAndExtensionRule() {
        let listing = FolderListing(DirectorySnapshot(path: "/p", entries: [
            .init(name: "B.MD", path: "/p/B.MD", kind: .file), .init(name: "a.md", path: "/p/a.md", kind: .file),
            .init(name: "c.txt", path: "/p/c.txt", kind: .file), .init(name: "d.md", path: "/p/d.md", kind: .directory),
            .init(name: ".e.md", path: "/p/.e.md", kind: .file),
        ]))
        XCTAssertEqual(listing.visible(query: "", showHidden: false, order: .name).map(\.entry.name), ["d.md", "a.md", "B.MD", "c.txt"])
        let extensionOnly = SearchQueryOptions(fileExtension: " .MD ")
        XCTAssertEqual(listing.visible(query: "", showHidden: false, order: .name, options: extensionOnly).map(\.entry.name), ["a.md", "B.MD"])
        XCTAssertEqual(listing.visible(query: "", showHidden: true, order: .name, options: extensionOnly).map(\.entry.name), [".e.md", "a.md", "B.MD"])
        XCTAssertEqual(listing.visible(query: "b", showHidden: false, order: .name, options: extensionOnly).map(\.entry.name), ["B.MD"])
    }

    func testAListingWithoutHiddenNamesKeepsThemTheSame() {
        let plain = FolderListing(DirectorySnapshot(path: "/p", entries: [.init(name: "a", path: "/p/a", kind: .file)]))
        XCTAssertEqual(plain.rows.map(\.id), plain.defaultRows.map(\.id))
        let hidden = FolderListing(DirectorySnapshot(path: "/p", entries: [.init(name: ".a", path: "/p/.a", kind: .file), .init(name: "b", path: "/p/b", kind: .file)]))
        XCTAssertEqual(hidden.rows.map(\.id), ["/p/.a", "/p/b"])
        XCTAssertEqual(hidden.defaultRows.map(\.id), ["/p/b"])
    }

    func testRowDescriptionsAreTheSameWhenWorkedOutLate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = date.formatted(date: .abbreviated, time: .omitted)
        let size = ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .file)
        func row(_ entry: RemoteEntry) -> FolderRow { FolderRow(entry) }
        let file = row(.init(name: "a.md", path: "/a.md", kind: .file, size: 2_048, modifiedAt: date))
        XCTAssertEqual(file.subtitle, size + " · " + day)
        XCTAssertEqual(file.visibleSubtitle, file.subtitle)
        XCTAssertEqual(file.symbol, "doc.richtext")
        let folder = row(.init(name: "f", path: "/f", kind: .directory, modifiedAt: date))
        XCTAssertEqual(folder.subtitle, "Folder")
        XCTAssertNil(folder.visibleSubtitle)
        XCTAssertEqual(folder.symbol, "folder.fill")
        XCTAssertEqual(row(.init(name: "x", path: "/x", kind: .file)).subtitle, "File")
        XCTAssertEqual(row(.init(name: "x", path: "/x", kind: .other, size: 2_048)).subtitle, size)
        XCTAssertEqual(row(.init(name: "l", path: "/l", kind: .symlink)).subtitle, "Symbolic link")
        XCTAssertEqual(row(.init(name: "l", path: "/l", kind: .symlink)).symbol, "link")
        XCTAssertEqual(row(.init(name: "l", path: "/l", kind: .symlink, link: .broken)).subtitle, "Broken link")
        XCTAssertEqual(row(.init(name: "l", path: "/l", kind: .symlink, link: .broken)).symbol, "link")
        let toFolder = row(.init(name: "l", path: "/l", kind: .symlink, link: .target(.init(name: "t", path: "/t", kind: .directory))))
        XCTAssertEqual(toFolder.subtitle, "Link to folder")
        XCTAssertEqual(toFolder.visibleSubtitle, "Link to folder")
        XCTAssertEqual(toFolder.symbol, "folder.fill")
        let toFile = row(.init(name: "l", path: "/l", kind: .symlink, link: .target(.init(name: "t.png", path: "/t.png", kind: .file, size: 2_048, modifiedAt: date))))
        XCTAssertEqual(toFile.subtitle, "Link to file · " + size + " · " + day)
        XCTAssertEqual(toFile.symbol, "photo")
    }

    func testPartialRowsWaitThenShowOnlyWhenTheyHaveGrownByHalf() {
        let gate = PartialListingGate(delay: .milliseconds(100)), start = ContinuousClock.now
        XCTAssertFalse(gate.shouldShow(count: 0, now: start), "Nothing to show yet")
        XCTAssertFalse(gate.shouldShow(count: 100, now: start), "A first batch starts the wait")
        XCTAssertFalse(gate.shouldShow(count: 200, now: start + .milliseconds(99)), "A folder finishing this soon never shows partial rows")
        XCTAssertTrue(gate.shouldShow(count: 300, now: start + .milliseconds(100)))
        XCTAssertFalse(gate.shouldShow(count: 400, now: start + .seconds(1)))
        XCTAssertTrue(gate.shouldShow(count: 450, now: start + .seconds(1)))
        XCTAssertFalse(gate.shouldShow(count: 674, now: start + .seconds(2)))
        XCTAssertTrue(gate.shouldShow(count: 675, now: start + .seconds(2)))
    }

    @MainActor func testSearchBatcherShowsFirstMatchesAndEverythingElseSoonAfter() async throws {
        var applied: [RemoteFolderSearch.Update] = []
        let batcher = FolderSearchBatcher(interval: .milliseconds(50)) { applied.append($0) }
        func update(_ name: String? = nil, folders: Int, finished: Bool = false) -> RemoteFolderSearch.Update {
            var value = RemoteFolderSearch.Update()
            if let name { value.matches = [.init(name: name, path: "/" + name, kind: .file)] }
            value.foldersSearched = folders; value.isFinished = finished
            return value
        }
        batcher.add(update(folders: 1))
        XCTAssertEqual(applied.count, 1, "The first report appears at once")
        batcher.add(update(folders: 2))
        XCTAssertEqual(applied.count, 1, "Held until the interval")
        batcher.add(update("first", folders: 3))
        XCTAssertEqual(applied.count, 2, "The first match does not wait")
        XCTAssertEqual(applied.last?.foldersSearched, 3)
        batcher.add(update("second", folders: 4))
        batcher.add(update("third", folders: 5))
        XCTAssertEqual(applied.count, 2)
        // A search that goes quiet still shows what it found.
        for _ in 0..<400 where applied.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(applied.count, 3)
        XCTAssertEqual(applied.last?.matches.map(\.name), ["second", "third"], "In order, with none lost")
        XCTAssertEqual(applied.last?.foldersSearched, 5)
        batcher.add(update("fourth", folders: 6))
        batcher.add(update(folders: 7, finished: true))
        XCTAssertEqual(applied.last?.isFinished, true, "The end does not wait")
        XCTAssertEqual(applied.flatMap(\.matches).map(\.name), ["first", "second", "third", "fourth"])
        batcher.cancel()
    }
}

/// A rarely used field must not change an entry's identity through how it is stored.
final class RemoteEntryLayoutTests: XCTestCase {
    func testRareFieldsRoundTripAndTakePartInEquality() {
        let target = RemoteEntry(name: "t", path: "/t", kind: .file)
        let full = RemoteEntry(name: "n", path: "/n", kind: .symlink, size: 1, modifiedAt: Date(timeIntervalSince1970: 1), navigationRoot: "/root",
                               exportFilename: "export", link: .target(target), canonicalRoot: "/canon").openingHeading("h").openingPage(3)
        XCTAssertEqual(full.navigationRoot, "/root")
        XCTAssertEqual(full.exportFilename, "export")
        XCTAssertEqual(full.canonicalRoot, "/canon")
        XCTAssertEqual(full.headingFragment, "h")
        XCTAssertEqual(full.openingPage, 3)
        XCTAssertEqual(full.linkTarget, target)
        let plain = RemoteEntry(name: "n", path: "/n", kind: .file)
        XCTAssertNil(plain.navigationRoot); XCTAssertNil(plain.exportFilename); XCTAssertNil(plain.canonicalRoot)
        XCTAssertNil(plain.headingFragment); XCTAssertNil(plain.openingPage); XCTAssertNil(plain.link)
        XCTAssertEqual(plain, RemoteEntry(name: "n", path: "/n", kind: .file))
        XCTAssertEqual(plain.hashValue, RemoteEntry(name: "n", path: "/n", kind: .file).hashValue)
        XCTAssertEqual(plain.openingPage(nil), plain, "Asking for nothing rare leaves nothing rare")
        XCTAssertEqual(plain.openingPage(0), plain, "An out-of-range page is ignored")
        for different in [plain.openingPage(1), plain.openingHeading("h"),
                          RemoteEntry(name: "n", path: "/n", kind: .file, navigationRoot: "/r"),
                          RemoteEntry(name: "n", path: "/n", kind: .file, exportFilename: "e"),
                          RemoteEntry(name: "n", path: "/n", kind: .file, link: .broken),
                          RemoteEntry(name: "n", path: "/n", kind: .file, canonicalRoot: "/c")] {
            XCTAssertNotEqual(plain, different)
        }
        XCTAssertNotEqual(plain.openingPage(1), plain.openingPage(2))
        XCTAssertEqual(full.selectedForTransfer.canonicalRoot, "/canon")
        XCTAssertEqual(full.selectionRoot, "/canon")
        XCTAssertLessThanOrEqual(MemoryLayout<RemoteEntry>.stride, 80, "The fields every row has, and one reference")
    }

    func testChildPrefixMatchesTheOriginalDefinition() {
        func original(_ name: String, _ parent: String) -> String {
            let trimmed = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return parent == "/" ? "/" + name : (parent.hasPrefix("/") ? "/" + trimmed : trimmed) + "/" + name
        }
        for parent in ["/", "//", "///", "", "a", "/a", "a/", "/a/", "//a//", "/a/b", "/a/b/", "a/b", "/é/東京/", "/a//b/", ".", "./", "/.", "/ /"] {
            XCTAssertEqual(RemotePath.appending("n", to: parent), original("n", parent), parent)
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
