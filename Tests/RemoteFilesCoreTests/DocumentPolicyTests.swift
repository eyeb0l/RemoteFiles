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

    func testHTMLIsNeverConvertedToActiveContent() throws {
        let prepared = try DocumentPolicy.prepareMarkdown("<script>alert('never')</script>\n\n<iframe src=\"https://example.invalid\"></iframe>\n\n<img src=\"https://example.invalid/pixel.png\">")
        XCTAssertFalse(prepared.runs.contains(where: { $0.imageURL != nil || $0.link != nil }))
        // Textual renders attributed text, never an HTML document or a web view.
        XCTAssertTrue(String(prepared.characters).contains("<script>"))
    }
}
