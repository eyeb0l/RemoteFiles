#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Share the original decoded UTF-8 source; attributed rendering never enters the clipboard.
///
/// Source can hold what private-key hiding does not recognise, such as the passwords and tokens
/// in an `.env` file. So a copy stays on this device, where Universal Clipboard would send it to
/// every other one signed in to the same account, and leaves the clipboard after a while instead
/// of waiting there until something else is copied.
@MainActor enum SourceClipboard {
    static let lifetime: TimeInterval = 10 * 60
    static func copy(_ text: String, to clipboard: UIPasteboard = .general, now: Date = Date()) {
        clipboard.setItems([[UTType.utf8PlainText.identifier: Data(text.utf8)]],
                           options: [.localOnly: true, .expirationDate: now.addingTimeInterval(lifetime)])
    }
}
#endif
