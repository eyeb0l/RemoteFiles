#if os(iOS)
import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import RemoteFilesUI

@MainActor final class SourceClipboardTests: XCTestCase {
    func testProductionClipboardPreservesOriginalUTF8Bytes() throws {
        // Exercise the production encoder and UIKit storage in an owned pasteboard.
        // Reading the personal/general pasteboard can request cross-device permission.
        let clipboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: clipboard.name) }
        for source in [
            "// 東京 ✨\r\n\tlet name = \"é\";  \r\n\r\n",
            "let name = \"e\u{301}\";\n\t ",
            "\u{FEFF}# Source\r\n",
            ""
        ] {
            SourceClipboard.copy(source, to: clipboard)
            let bytes = try XCTUnwrap(clipboard.data(forPasteboardType: UTType.utf8PlainText.identifier))
            XCTAssertEqual(bytes, Data(source.utf8), "Copy must retain CRLF, normalization and trailing whitespace")
            // UIKit's convenience string getter consumes a UTF-8 BOM as encoding metadata.
            // The raw data representation above is the exact-byte contract.
            let visible = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
            XCTAssertEqual(Array(try XCTUnwrap(clipboard.string).utf8), Array(visible.utf8))
        }
    }
}
#endif
