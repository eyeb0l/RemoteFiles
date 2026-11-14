import SwiftUI
import RemoteFilesCore
#if os(iOS)
import WebKit
#endif

/// Asks before opening a link that `ExternalLinkPolicy` would not open on one tap, showing the
/// host it really goes to and its whole address.
struct ExternalLinkConfirmation: ViewModifier {
    @Binding var link: URL?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.alert("Open This Link?", isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }), presenting: link) { url in
            Button("Open in Browser") { openURL(url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(Self.message(for: url))
        }
    }

    static func message(for url: URL) -> String {
        let destination = ExternalLinkPolicy.destination(of: url)
        let reason = destination.isUnencrypted
            ? "This link is not encrypted, so others on the network can see and change the page."
            : "The link’s text shows a different address from the one it opens."
        return "It goes to \(destination.host).\n\n\(destination.address)\n\n\(reason)"
    }
}

extension View {
    func confirmingExternalLink(_ link: Binding<URL?>) -> some View { modifier(ExternalLinkConfirmation(link: link)) }
}

#if os(iOS)
/// Reads the text of the links in a static preview that lead to an address, from the app's own
/// isolated world; the page's scripts never run.
@MainActor enum ExternalLinkText {
    /// Nil if the page could not be asked in time, which is treated as needing confirmation.
    static func visibleTexts(for url: URL, in view: WKWebView) async -> [String]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            let reply = Reply(continuation)
            reply.timeout = Task {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                reply.finish(nil)
            }
            view.callAsyncJavaScript(script, arguments: ["target": url.absoluteString], in: nil, in: .defaultClient) { result in
                if case .success(let value) = result { reply.finish(value as? [String]) } else { reply.finish(nil) }
            }
        }
    }

    /// The tapped link is not known here, only its address, so every link to that address is
    /// read. More of them than are read, or more text than is read, is no answer at all, not a
    /// clean one. `innerText` is the text as laid out: spaces collapsed, and nothing from an
    /// element that is hidden or not displayed.
    private static let script = #"""
    const texts = [];
    for (const anchor of document.querySelectorAll('a[href]')) {
        if (anchor.href !== target && anchor.getAttribute('href') !== target) continue;
        if (texts.length >= 32) return null;
        // A link inside an inline SVG has no `innerText`; its text is its content.
        const text = (typeof anchor.innerText === 'string' ? anchor.innerText : (anchor.textContent || '')).trim();
        if (text.length > 2000) return null;
        texts.push(text);
    }
    return texts;
    """#

    private final class Reply {
        private var continuation: CheckedContinuation<[String]?, Never>?
        var timeout: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<[String]?, Never>) { self.continuation = continuation }
        func finish(_ value: [String]?) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(returning: value)
        }
    }

    /// Opens the link, or asks first when the text any matching link is shown with calls for it.
    static func open(_ url: URL, from view: WKWebView?, open: @escaping (URL) -> Void, confirm: ((URL) -> Void)?) {
        guard let confirm else { open(url); return }
        guard let view else { confirm(url); return }
        Task { @MainActor in
            let texts = await visibleTexts(for: url, in: view)
            let asks = texts.map { $0.isEmpty ? ExternalLinkPolicy.needsConfirmation(url, visibleText: nil)
                : $0.contains { ExternalLinkPolicy.needsConfirmation(url, visibleText: $0) } } ?? true
            if asks { confirm(url) } else { open(url) }
        }
    }
}
#endif
