import Foundation
import XCTest
@testable import RemoteFilesCore

final class DocumentPolicyTests: XCTestCase {
    func testMarkdownAndUTF8TextKinds() {
        XCTAssertEqual(DocumentPolicy.decode(Data("# Résumé 🪴".utf8), filename: "Agent Report.MD"), .text("# Résumé 🪴", markdown: true))
        for filename in ["main.swift", "config.toml", ".env", "Dockerfile", "notes.txt", "index.html"] {
            XCTAssertEqual(DocumentPolicy.decode(Data("hello\n\t世界".utf8), filename: filename), .text("hello\n\t世界", markdown: false))
        }
        XCTAssertEqual(DocumentPolicy.decode(Data("%PDF text".utf8), filename: "report.pdf"), .unsupportedFileType)
    }

    func testHTMLRoutingPreservesOriginalSourceAndLimits() {
        let source = "<!doctype html>\r\n<h1>café 東京</h1>\n<script>example()</script>\n"
        for name in ["index.html", "PAGE.HTM", "preview.HTML"] {
            XCTAssertEqual(DocumentPolicy.kind(filename: name), .html)
            XCTAssertEqual(DocumentPolicy.decode(Data(source.utf8), filename: name), .text(source, markdown: false))
            XCTAssertEqual(DocumentPolicy.decode(Data(source.utf8), filename: name, maxBytes: 4), .tooLarge)
            XCTAssertEqual(DocumentPolicy.decode(Data([0xff, 0xfe]), filename: name), .unsupportedEncodingOrBinary)
        }
        XCTAssertEqual(DocumentPolicy.kind(filename: "index.html.exe"), .unsupported)
    }

    func testStandaloneImagePDFAndAdditionalTextKinds() {
        for name in ["photo.JPG", "shot.png", "phone.HEIC", "animation.gif", "scan.tiff", "web.webp", "bitmap.bmp"] {
            XCTAssertEqual(DocumentPolicy.kind(filename: name), .image, name)
            XCTAssertEqual(DocumentPolicy.decode(Data("not image bytes".utf8), filename: name), .unsupportedFileType)
        }
        XCTAssertEqual(DocumentPolicy.kind(filename: "REPORT.PDF"), .pdf)
        XCTAssertEqual(DocumentPolicy.kind(filename: "report.pdf.exe"), .unsupported)
        for name in ["changes.diff", "fix.patch", "notebook.ipynb", "settings.cfg", "main.tf"] {
            XCTAssertEqual(DocumentPolicy.decode(Data("text".utf8), filename: name), .text("text", markdown: false), name)
        }
    }

    func testAudioVideoRoutingAndNoTextOrPlaylistFallback() {
        for name in ["clip.MP4", "clip.m4v", "clip.mov", "clip.3gp", "clip.3g2"] {
            XCTAssertEqual(DocumentPolicy.kind(filename: name), .video, name)
            XCTAssertEqual(DocumentPolicy.decode(Data("text".utf8), filename: name), .unsupportedFileType)
        }
        for ext in ["mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "ac3", "eac3"] {
            let name = "Recording.\(ext.uppercased())"
            XCTAssertEqual(DocumentPolicy.kind(filename: name), .audio, name)
            XCTAssertEqual(DocumentPolicy.decode(Data("text".utf8), filename: name), .unsupportedFileType)
        }
        for name in ["clip.mp4.exe", "audio.mp3.zip", "stream.m3u8", "stream.m3u", "list.pls"] {
            XCTAssertEqual(DocumentPolicy.kind(filename: name), .unsupported, name)
        }
    }

    func testEmptyBOMBinaryAndInvalidEncodingAreDeliberateStates() {
        XCTAssertEqual(DocumentPolicy.decode(Data(), filename: "empty.md"), .empty)
        XCTAssertEqual(DocumentPolicy.decode(Data([0xEF, 0xBB, 0xBF]), filename: "empty.txt"), .empty)
        XCTAssertEqual(DocumentPolicy.decode(Data([0xEF, 0xBB, 0xBF, 0x41]), filename: "a.txt"), .text("A", markdown: false))
        XCTAssertEqual(DocumentPolicy.decode(Data([0xFF, 0xFE, 0x41, 0x00]), filename: "utf16.txt"), .unsupportedEncodingOrBinary)
        XCTAssertEqual(DocumentPolicy.decode(Data([0xC3, 0x28]), filename: "bad.md"), .unsupportedEncodingOrBinary)
        XCTAssertEqual(DocumentPolicy.decode(Data([0x41, 0x00, 0x42]), filename: "binary.txt"), .unsupportedEncodingOrBinary)
        XCTAssertEqual(DocumentPolicy.decode(Data([0x41, 0x1B, 0x42]), filename: "escape.log"), .unsupportedEncodingOrBinary)
        XCTAssertEqual(DocumentPolicy.decode(Data(" \n".utf8), filename: "blank.txt"), .text(" \n", markdown: false))
    }

    func testPreviewByteBoundaryAndCustomLimit() {
        XCTAssertEqual(DocumentPolicy.decode(Data("1234".utf8), filename: "a.txt", maxBytes: 4), .text("1234", markdown: false))
        XCTAssertEqual(DocumentPolicy.decode(Data("12345".utf8), filename: "a.txt", maxBytes: 4), .tooLarge)
        XCTAssertEqual(DocumentPolicy.decode(Data(repeating: 0x41, count: DocumentPolicy.previewByteLimit + 1), filename: "a.md"), .tooLarge)
    }

    func testOnlyAbsoluteHTTPLinksWithoutCredentialsAreAllowed() {
        for value in ["https://example.com/report?q=1#findings", "http://localhost:8080/report", "HTTPS://example.com"] {
            XCTAssertTrue(DocumentPolicy.allowsExternalLink(URL(string: value)!), value)
        }
        for value in ["javascript:alert(1)", "data:text/html,test", "file:///etc/passwd", "mailto:a@example.com", "ssh://mac",
                      "../report.md", "/report.md", "#section", "//example.com/report", "https:report", "https://user:secret@example.com"] {
            XCTAssertFalse(DocumentPolicy.allowsExternalLink(URL(string: value)!), value)
        }
        XCTAssertFalse(DocumentPolicy.allowsExternalLink(URL(string: "report", relativeTo: URL(string: "https://example.com")!)!))
    }

    func testImagesNeverReachRendererAsLoadableURLsAndUnsafeLinksLoseActions() throws {
        let markdown = """
        ![External alt](https://example.invalid/should-never-load.png)
        ![Local alt](file:///private/secret.png)
        ![Relative alt](images/report.png)
        ![](data:image/png;base64,aGVsbG8=)

        [Allowed](https://example.com) [Relative](other.md) [Unsafe](javascript:alert%281%29)
        """
        let prepared = try DocumentPolicy.prepareMarkdown(markdown)
        let text = String(prepared.characters)
        XCTAssertTrue(text.contains("External alt — preview unavailable"))
        XCTAssertTrue(text.contains("Local alt — preview unavailable"))
        XCTAssertTrue(text.contains("Relative alt — preview unavailable"))
        XCTAssertTrue(text.contains("Image preview unavailable"))
        XCTAssertFalse(prepared.runs.contains(where: { $0.imageURL != nil }))
        XCTAssertEqual(prepared.runs.compactMap(\.link), [URL(string: "https://example.com")!])
    }

    private func assertLimit(_ expected: MarkdownLimitError, _ source: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DocumentPolicy.prepareMarkdown(source), file: file, line: line) {
            XCTAssertEqual($0 as? MarkdownLimitError, expected, file: file, line: line)
        }
        // The reader's parts and its text index use the same preparation, so neither renders it.
        XCTAssertThrowsError(try DocumentPolicy.remoteMarkdownParts(source), file: file, line: line)
        let index = try? DocumentTextIndex(text: source, markdown: true)
        XCTAssertEqual(index?.isSourceOnly, true, file: file, line: line)
        XCTAssertEqual(index?.parts.count, 0, file: file, line: line)
    }

    /// The renderer nests one view per block level, and a few hundred overflow its stack.
    func testDeeplyNestedBlocksAreNotRendered() throws {
        let quotes = { (depth: Int) in String(repeating: ">", count: depth) + " quoted" }
        XCTAssertNoThrow(try DocumentPolicy.prepareMarkdown(quotes(MarkdownLimits.maximumDepth - 1)))
        assertLimit(.tooDeeplyNested, quotes(MarkdownLimits.maximumDepth))
        assertLimit(.tooDeeplyNested, quotes(500))
        assertLimit(.tooDeeplyNested, "Before\n\n" + quotes(100_000) + "\n\nAfter")
        assertLimit(.tooDeeplyNested, (0..<40).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n"))
        // Ten lists inside one another, each item quoted: deep for writing, and well within the limit.
        let nested = (0..<10).map { String(repeating: "  ", count: $0) + "- item \($0)" }.joined(separator: "\n")
        XCTAssertNoThrow(try DocumentPolicy.prepareMarkdown(nested + "\n\n> - > quoted list"))
        // A source view shows the same text whatever its structure.
        guard case .text(_, markdown: true, _) = DocumentPolicy.decode(Data(quotes(500).utf8), filename: "deep.md") else {
            return XCTFail("Decoding is unaffected")
        }
    }

    func testTablesWiderThanTheLimitAreNotParsed() throws {
        func table(columns: Int) -> String {
            let row = "|" + String(repeating: "a|", count: columns)
            return [row, "|" + String(repeating: "-|", count: columns), row].joined(separator: "\n")
        }
        let widest = try DocumentPolicy.prepareMarkdown(table(columns: MarkdownLimits.maximumBarsPerLine - 1))
        XCTAssertTrue(widest.runs.contains { run in
            run.presentationIntent?.components.contains { if case .table = $0.kind { return true }; return false } == true
        })
        let started = ContinuousClock.now
        assertLimit(.tableTooWide, table(columns: MarkdownLimits.maximumBarsPerLine))
        assertLimit(.tableTooWide, "# Title\n\n" + table(columns: 20_000))
        XCTAssertLessThan(started.duration(to: .now), .seconds(5), "Refused before parsing, which takes far longer")
        // Bars are counted a line at a time.
        let rows = Array(repeating: "|a|b|c|", count: 1_000)
        XCTAssertNoThrow(try DocumentPolicy.prepareMarkdown((["|a|b|c|", "|-|-|-|"] + rows).joined(separator: "\n")))
    }

    func testDocumentsThatChangeFormattingEveryFewBytesAreNotParsed() throws {
        let started = ContinuousClock.now
        assertLimit(.tooManyMarkers, String(repeating: "*a* ", count: 130_000))
        assertLimit(.tooManyMarkers, String(repeating: "a\n\n", count: 130_000))
        XCTAssertLessThan(started.duration(to: .now), .seconds(5), "Refused before parsing, which takes far longer")
        // The count after parsing catches what the characters did not predict.
        let document = try AttributedString(markdown: "one *two* three **four** `five`")
        let runs = Array(document.runs)
        XCTAssertNoThrow(try MarkdownLimits.checkStructure(runs, maximumRuns: runs.count))
        XCTAssertThrowsError(try MarkdownLimits.checkStructure(runs, maximumRuns: runs.count - 1)) {
            XCTAssertEqual($0 as? MarkdownLimitError, .tooManyRuns)
        }
        // Ordinary long writing is far inside both limits.
        let prose = String(repeating: "A paragraph of ordinary prose with `code`, *emphasis* and a [link](https://example.com).\n\n", count: 3_000)
        XCTAssertGreaterThan(prose.utf8.count, 256 * 1_024)
        XCTAssertNoThrow(try DocumentPolicy.remoteMarkdownParts(prose))
    }

    func testImagesBeyondTheLimitBecomeTheirAlternativeText() throws {
        let source = (0..<(MarkdownLimits.maximumImages + 2)).map { "![alt \($0)](images/\($0).png)" }.joined(separator: "\n\n")
        let parts = try DocumentPolicy.remoteMarkdownParts(source)
        let references = parts.compactMap { part -> String? in
            if case .image(let reference, _) = part.content { return reference }; return nil
        }
        XCTAssertEqual(references, (0..<MarkdownLimits.maximumImages).map { "images/\($0).png" }, "The first images are kept, in order")
        guard case .text(let last) = parts.last?.content else { return XCTFail("The later images are text") }
        let text = String(last.characters)
        XCTAssertTrue(text.contains("alt \(MarkdownLimits.maximumImages) — preview unavailable"), text)
        XCTAssertTrue(text.contains("alt \(MarkdownLimits.maximumImages + 1) — preview unavailable"), text)
        XCTAssertFalse(last.runs.contains { $0.imageURL != nil })
        XCTAssertEqual(try DocumentTextIndex(text: source, markdown: true).parts.count, parts.count)
    }

    func testMarkdownStructureAndReadOnlyTasks() throws {
        let prepared = try DocumentPolicy.prepareMarkdown("""
        # Heading

        Paragraph **strong**, *emphasis*, and `code`.

        - [x] Complete
        - [ ] Pending
        - `[x]` is literal code

        1. First
        2. Second

        > Evidence quotation.

        ```swift
        let value = 1
        ```

        | Name | Result |
        | --- | --- |
        | Read | Passed |

        ---
        """)
        let text = String(prepared.characters)
        XCTAssertTrue(text.contains("☑ Complete"))
        XCTAssertTrue(text.contains("☐ Pending"))
        XCTAssertTrue(text.contains("[x] is literal code"))
        let kinds = prepared.runs.compactMap(\.presentationIntent).flatMap(\.components).map(\.kind)
        XCTAssertTrue(kinds.contains(where: { if case .header = $0 { return true }; return false }))
        XCTAssertTrue(kinds.contains(where: { if case .codeBlock = $0 { return true }; return false }))
        XCTAssertTrue(kinds.contains(where: { if case .table = $0 { return true }; return false }))
        XCTAssertTrue(kinds.contains(where: { if case .blockQuote = $0 { return true }; return false }))
        XCTAssertTrue(kinds.contains(where: { if case .thematicBreak = $0 { return true }; return false }))
    }

    func testHTMLInsideMarkdownRemainsInactiveText() throws {
        let prepared = try DocumentPolicy.prepareMarkdown("<script>alert('never')</script>\n\n<iframe src=\"https://example.invalid\"></iframe>\n\n<img src=\"https://example.invalid/pixel.png\">")
        XCTAssertFalse(prepared.runs.contains(where: { $0.imageURL != nil || $0.link != nil }))
        // Textual renders attributed text, never an HTML document or a web view.
        XCTAssertTrue(String(prepared.characters).contains("<script>"))
    }
}
