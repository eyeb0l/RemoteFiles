#if os(iOS)
import SwiftUI
import WebKit
import RemoteFilesCore

struct HTMLContentView: View {
    let text: String
    let filename: String
    let readingPosition: DocumentReadingPosition
    @Environment(\.openURL) private var openURL
    @State private var rules: WKContentRuleList?
    @State private var error: String?
    @State private var loaded = false
    @State private var needsScripts = false
    var body: some View {
        ZStack {
            if let error {
                ContentUnavailableView("Rendered Preview Unavailable", systemImage: "doc.text", description: Text(error))
            } else if let rules {
                StaticHTMLWebView(text: text, filename: filename, rules: rules, readingPosition: readingPosition,
                    onFinish: { needsScripts = $0; loaded = true },
                    onFailure: { error = $0 }, openExternalLink: { openURL($0) })
                    .opacity(needsScripts ? 0 : 1)
                    .accessibilityHidden(needsScripts)
                if needsScripts {
                    ContentUnavailableView("This page needs JavaScript", systemImage: "globe",
                        description: Text("This file has no content to show without running its scripts. Open the running website to view the app, or choose Source to inspect the HTML."))
                } else if !loaded { ProgressView("Rendering HTML…") }
            } else { ProgressView("Rendering HTML…") }
        }
        .task(id: Data(text.utf8)) {
            rules = nil; error = nil; loaded = false; needsScripts = false
            do {
                // The shared blocker denies every automatic resource request.
                let blockers = try await SVGResourceBlocker.rules()
                try Task.checkCancellation()
                rules = blockers
                try await Task.sleep(for: .seconds(15))
                if !loaded { error = "This HTML could not finish rendering. Use Source to inspect it." }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// An offline HTML document. Its own markup cannot run scripts or automatically
/// load resources; user-tapped HTTP links open outside this ephemeral renderer.
struct StaticHTMLWebView: UIViewRepresentable {
    let text: String
    let filename: String
    let rules: WKContentRuleList
    let readingPosition: DocumentReadingPosition
    let onFinish: (Bool) -> Void
    let onFailure: (String) -> Void
    let openExternalLink: (URL) -> Void

    static func configuration(rules: WKContentRuleList) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.add(rules)
        return config
    }
    static func html(_ source: String) -> String {
        """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark}body{font:17px -apple-system,sans-serif;margin:20px;overflow-wrap:break-word}img,video,svg{max-width:100%;height:auto}</style>
        </head><body>\(source)</body></html>
        """
    }
    func makeCoordinator() -> Coordinator {
        Coordinator(readingPosition: readingPosition, onFinish: onFinish, onFailure: onFailure, openExternalLink: openExternalLink)
    }
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.configuration(rules: rules))
        view.navigationDelegate = context.coordinator
        view.scrollView.delegate = context.coordinator
        view.accessibilityIdentifier = "Rendered HTML document"
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.text != text else { return }
        context.coordinator.text = text
        context.coordinator.initialNavigation = true
        context.coordinator.finishedLoading = false
        context.coordinator.navigation = view.loadHTMLString(Self.html(text), baseURL: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        if coordinator.finishedLoading { coordinator.readingPosition.rendered = view.scrollView.contentOffset }
        view.stopLoading(); view.navigationDelegate = nil; view.scrollView.delegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var text: String?
        var navigation: WKNavigation?
        var initialNavigation = true
        var finishedLoading = false
        var active = true
        let readingPosition: DocumentReadingPosition
        let onFinish: (Bool) -> Void
        let onFailure: (String) -> Void
        let openExternalLink: (URL) -> Void
        init(readingPosition: DocumentReadingPosition, onFinish: @escaping (Bool) -> Void,
             onFailure: @escaping (String) -> Void, openExternalLink: @escaping (URL) -> Void) {
            self.readingPosition = readingPosition; self.onFinish = onFinish
            self.onFailure = onFailure; self.openExternalLink = openExternalLink
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if initialNavigation, action.navigationType == .other, action.targetFrame?.isMainFrame == true,
               action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow); return
            }
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.scheme == "about", url.path == "blank", url.fragment != nil {
                    decisionHandler(.allow); return
                }
                if DocumentPolicy.allowsExternalLink(url) { openExternalLink(url) }
            }
            decisionHandler(.cancel)
        }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            initialNavigation = false
            // App-owned inspection still works with content JavaScript disabled.
            // This avoids displaying an empty React/Vue entry point as a successful preview.
            let hasScripts = text?.range(of: #"<script(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil
            view.evaluateJavaScript("""
            document.body.innerText.trim().length === 0 &&
            !Array.from(document.querySelectorAll('img,svg,video')).some(e => e.getBoundingClientRect().height > 0)
            """, in: nil, in: .defaultClient) { [weak self, weak view] result in
                guard let self, self.active, let view else { return }
                switch result {
                case .success(let value):
                    view.scrollView.setContentOffset(self.readingPosition.rendered, animated: false)
                    self.finishedLoading = true
                    self.onFinish(hasScripts && (value as? Bool ?? false))
                case .failure(let error):
                    self.onFailure("The HTML preview could not finish loading: " + error.localizedDescription)
                }
            }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if finishedLoading { readingPosition.rendered = scrollView.contentOffset }
        }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed() }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed() }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) { failed() }
        private func failed() { if active { onFailure("This HTML could not be rendered. Use Source or refresh to try again.") } }
    }
}
#endif
