import SwiftUI
import XCTest
@testable import RemoteFilesUI

final class SourceHighlightingTests: XCTestCase {
    func testLanguageSelectionUsesFilenameAndKeepsUnknownTextPlain() {
        for (filename, language) in [
            ("/Projects/App.SWIFT", "swift"), ("README.md", "markdown"),
            ("config.JSON", "json"), ("script.py", "python"), ("App.tsx", "tsx"),
            ("Dockerfile", "docker"), ("Dockerfile.dev", "docker"),
            (".zshrc", "bash"), (".env", "bash"), ("Cargo.lock", "toml")
        ] {
            XCTAssertEqual(SourceLanguage.forFilename(filename), language, filename)
        }
        for filename in [nil, "notes.txt", "table.csv", "server.log", "unknown.custom"] {
            XCTAssertNil(SourceLanguage.forFilename(filename))
        }
    }

    func testSwiftHighlightingPreservesUnicodeWhitespaceAndTrailingNewline() async throws {
        let source = "// 東京 ✨\r\n\tlet message = \"Hello 🌍\"\r\nlet count = 42\r\n"
        let highlighter = SourceHighlighting()
        let lightResult = try await highlighter.highlight(source, language: "swift", dark: false)
        let darkResult = try await highlighter.highlight(source, language: "swift", dark: true)
        let light = try XCTUnwrap(lightResult)
        let dark = try XCTUnwrap(darkResult)
        XCTAssertEqual(Array(String(light.characters).utf8), Array(source.utf8))
        XCTAssertEqual(Array(String(dark.characters).utf8), Array(source.utf8))
        XCTAssertNotEqual(light, dark, "Appearance changes should update the palette, not the source")
        let colors = light.runs.compactMap(\.foregroundColor)
        XCTAssertGreaterThan(Set(colors).count, 2, "Keywords, comments and strings should be distinguishable")
    }

    func testCachePreservesCanonicallyEquivalentButDifferentUnicodeBytes() async throws {
        let highlighter = SourceHighlighting()
        for source in ["let name = \"\u{E9}\"\n", "let name = \"e\u{301}\"\n"] {
            let result = try await highlighter.highlight(source, language: "swift", dark: false)
            let highlighted = try XCTUnwrap(result)
            XCTAssertEqual(Array(String(highlighted.characters).utf8), Array(source.utf8))
        }
    }

    func testCommonGrammarsProduceLosslessColoredSource() async throws {
        let highlighter = SourceHighlighting()
        for (language, source) in [
            ("json", "{\"title\": \"東京\", \"count\": 42, \"active\": true}\n"),
            ("python", "# Comment\ndef greet(name):\n\treturn \"Hello \" + name\n"),
            ("typescript", "const value: number = 42; // Comment\n"),
            ("yaml", "title: Report\nactive: true\ncount: 42\n"),
            ("markdown", "# Report\n\n**Ready** and `source`\n\n![Image](./private.png)\n"),
            ("markup", "<script>neverRun()</script>\n<p>Read only</p>\n")
        ] {
            let result = try await highlighter.highlight(source, language: language, dark: false)
            let highlighted = try XCTUnwrap(result, language)
            XCTAssertEqual(Array(String(highlighted.characters).utf8), Array(source.utf8), language)
            XCTAssertTrue(highlighted.runs.contains { $0.foregroundColor != nil }, language)
        }
    }

    func testLargeComplexOrUnknownSourcesFallBackToPlainText() async throws {
        let highlighter = SourceHighlighting()
        let large = String(repeating: "a", count: SourceHighlighting.byteLimit + 1)
        let complex = String(repeating: "let x = 1;\n", count: 4_000)
        let oversized = try await highlighter.highlight(large, language: "swift", dark: false)
        let manyTokens = try await highlighter.highlight(complex, language: "swift", dark: false)
        let unknown = try await highlighter.highlight("plain text\n", language: nil, dark: false)
        let unsupported = try await highlighter.highlight("plain text\n", language: "not-a-grammar", dark: false)
        let empty = try await highlighter.highlight("", language: "swift", dark: false)
        XCTAssertNil(oversized)
        XCTAssertNil(manyTokens)
        XCTAssertNil(unknown)
        XCTAssertNil(unsupported)
        XCTAssertNil(empty)
    }

    func testCancelledWorkDoesNotReturnHighlightedSource() async throws {
        let highlighter = SourceHighlighting()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await highlighter.highlight("let value = 42\n", language: "swift", dark: false)
        }
        do { _ = try await task.value; XCTFail("Cancelled work must not publish") }
        catch is CancellationError { }
    }
}
