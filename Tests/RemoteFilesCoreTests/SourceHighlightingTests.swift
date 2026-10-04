import SwiftUI
import XCTest
import Textual
@testable import RemoteFilesUI

/// Completes real tokenization, then holds its first result before the highlighter
/// can validate or cache it. No scheduler timing or unusually large input is needed.
private actor HighlightTokenizationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var calls = 0

    func tokenize(_ source: String, _ language: String) async -> [SourceCodeToken] {
        calls += 1
        let firstCall = calls == 1
        let tokens = await SourceCodeTokenization.tokens(for: source, language: language)
        if firstCall && !released { await withCheckedContinuation { continuation = $0 } }
        return tokens
    }
    func waitUntilSuspended() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while continuation == nil {
            guard ContinuousClock.now < deadline else { throw GateTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func resume() { released = true; continuation?.resume(); continuation = nil }
    private struct GateTimeout: Error {}
}

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
        let source = "// 東京 ✨\r\n\tlet message = \"Hello 🌍 e\u{301} é\"  \t\r\nlet count = 42\r\n\t  \r\n"
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
    private func verifyDiscardedTokenization(cancel: Bool) async throws {
        let source = "let greeting = \"東京 🌍 e\u{301}\"  \r\n"
        let gate = HighlightTokenizationGate()
        let highlighter = SourceHighlighting(tokenize: { await gate.tokenize($0, $1) })
        let task = Task { try await highlighter.highlight(source, language: "swift", dark: false) }
        do { try await gate.waitUntilSuspended() }
        catch {
            task.cancel(); await gate.resume(); _ = try? await task.value
            throw error
        }
        if cancel { task.cancel() } else { await highlighter.clear() }
        await gate.resume()
        do { _ = try await task.value; XCTFail("Discarded in-flight tokens must not publish") }
        catch is CancellationError { }

        let retry = try await highlighter.highlight(source, language: "swift", dark: false)
        XCTAssertEqual(Data(String(try XCTUnwrap(retry).characters).utf8), Data(source.utf8))
        let retriedCalls = await gate.calls
        XCTAssertEqual(retriedCalls, 2, "Cancelled or cleared tokenization must not populate the cache")
        let cached = try await highlighter.highlight(source, language: "swift", dark: true)
        XCTAssertEqual(Data(String(try XCTUnwrap(cached).characters).utf8), Data(source.utf8))
        let cachedCalls = await gate.calls
        XCTAssertEqual(cachedCalls, 2, "The valid retry should be cached for the other palette")
    }

    func testCancellationDuringTokenizationCannotPublishOrCache() async throws {
        try await verifyDiscardedTokenization(cancel: true)
    }

    func testCacheClearDuringTokenizationCannotPublishOrRepopulateCache() async throws {
        try await verifyDiscardedTokenization(cancel: false)
    }

    func testCanonicallyEquivalentButByteChangedTokensFallBackToOriginalSource() async throws {
        let source = "let name = \"e\u{301}\"  \r\n"
        let normalized = source.precomposedStringWithCanonicalMapping
        XCTAssertEqual(source, normalized, "String equality alone cannot validate lossless tokens")
        XCTAssertNotEqual(Data(source.utf8), Data(normalized.utf8))
        let highlighter = SourceHighlighting(tokenize: { _, language in
            await SourceCodeTokenization.tokens(for: normalized, language: language)
        })
        let result = try await highlighter.highlight(source, language: "swift", dark: false)
        XCTAssertNil(result, "Byte-changing tokens must leave the original plain source visible")
    }

    func testHighlightingByteLimitCountsMultibyteSource() async throws {
        let highlighter = SourceHighlighting()
        let source = "// " + String(repeating: "🌍", count: SourceHighlighting.byteLimit / 4)
        XCTAssertLessThan(source.count, SourceHighlighting.byteLimit)
        XCTAssertGreaterThan(source.utf8.count, SourceHighlighting.byteLimit)
        let result = try await highlighter.highlight(source, language: "swift", dark: false)
        XCTAssertNil(result)
    }

}
