import XCTest
@testable import RemoteFilesCore

final class SearchQueryOptionsTests: XCTestCase {
    func testLiteralMatchingAndCaseSensitivity() {
        let text = "Find NEEDLE and a.*b literally"
        XCTAssertNotNil(SearchQueryOptions().range(in: text, query: "needle"))
        XCTAssertNil(SearchQueryOptions(caseSensitive: true).range(in: text, query: "needle"))
        XCTAssertNotNil(SearchQueryOptions(caseSensitive: true).range(in: text, query: "NEEDLE"))
        XCTAssertNotNil(SearchQueryOptions().range(in: text, query: "a.*b"))
        XCTAssertNil(SearchQueryOptions().range(in: text, query: "a.+b"))
        XCTAssertNil(SearchQueryOptions().range(in: text, query: ""))
    }

    func testWholeWordSkipsEmbeddedMatchesAndUsesUnicodeBoundaries() {
        let options = SearchQueryOptions(wholeWord: true)
        let text = "needles _needle needle_ 2needle needle2 éneedle needleé [NEEDLE]"
        let match = options.range(in: text, query: "needle")
        XCTAssertEqual(match.map { String(text[$0]) }, "NEEDLE")
        XCTAssertNotNil(options.range(in: "東京", query: "東京"))
        XCTAssertNil(options.range(in: "東京都", query: "東京"))
        XCTAssertNotNil(options.range(in: "👋needle✨", query: "needle"))
        XCTAssertNotNil(options.range(in: "needle", query: "needle"))
        XCTAssertNil(options.range(in: "needle\u{301}", query: "needle"))
    }

    func testExtensionFilterAcceptsFilesOnlyAndNormalizesUserInput() {
        let options = SearchQueryOptions(fileExtension: " .Md ")
        XCTAssertTrue(options.accepts(.init(name: "Report.MD", path: "/Report.MD", kind: .file)))
        XCTAssertFalse(options.accepts(.init(name: "Report.txt", path: "/Report.txt", kind: .file)))
        XCTAssertFalse(options.accepts(.init(name: "Report.md", path: "/Report.md", kind: .directory)))
        XCTAssertFalse(options.accepts(.init(name: "Report.md", path: "/Report.md", kind: .symlink)))
        XCTAssertTrue(SearchQueryOptions().accepts(.init(name: "folder", path: "/folder", kind: .directory)))
    }
}
