#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Share the original decoded UTF-8 source; attributed rendering never enters the clipboard.
@MainActor enum SourceClipboard {
    static func copy(_ text: String, to clipboard: UIPasteboard = .general) {
        clipboard.setData(Data(text.utf8), forPasteboardType: UTType.utf8PlainText.identifier)
    }
}
#endif
