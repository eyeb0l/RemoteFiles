#if os(iOS)
import SwiftUI
import WebKit
import RemoteFilesCore

struct SVGContentView: View {
    let text: String
    let filename: String
    @State private var prepared: String?
    @State private var rules: WKContentRuleList?
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        ZStack {
            if let error {
                ContentUnavailableView("Rendered Preview Unavailable", systemImage: "doc.text", description: Text(error))
            } else if let prepared, let rules {
                StaticSVGWebView(svg: prepared, rules: rules, filename: filename,
                                 onFinish: { loaded = true }, onFailure: { error = $0 })
                    .opacity(loaded ? 1 : 0)
                    .accessibilityHidden(!loaded)
                if !loaded { ProgressView("Preparing image…") }
            } else { ProgressView("Preparing image…") }
        }
        .task(id: Data(text.utf8)) {
            prepared = nil; rules = nil; error = nil; loaded = false
            do {
                let svg = try await SVGPreparation.shared.prepare(text)
                let blockers = try await SVGResourceBlocker.rules()
                try Task.checkCancellation()
                rules = blockers; prepared = svg
                try await Task.sleep(for: .seconds(15))
                if !loaded { error = "This SVG could not finish rendering. Use Source to inspect it." }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private actor SVGPreparation {
    static let shared = SVGPreparation()
    func prepare(_ source: String) throws -> String { try SVGPreviewPolicy.prepare(source) }
}

@MainActor enum SVGResourceBlocker {
    static var cached: WKContentRuleList?
    static func rules() async throws -> WKContentRuleList {
        if let cached { return cached }
        let result: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "RemoteFiles.StaticSVG.NoResources.v1",
                encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#) { rules, error in
                if let rules { continuation.resume(returning: rules) }
                else { continuation.resume(throwing: error ?? SVGPreviewPolicy.Failure.unsupported) }
            }
        }
        cached = result
        return result
    }
}

/// No original markup enters WebKit. Static allowlisted SVG, JavaScript disabled,
/// CSP, all-resource blocking and denied navigation are independent boundaries.
struct StaticSVGWebView: UIViewRepresentable {
    let svg: String
    let rules: WKContentRuleList
    let filename: String
    let onFinish: () -> Void
    let onFailure: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onFailure: onFailure) }
    static func configuration(rules: WKContentRuleList) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.add(rules)
        return config
    }
    func makeUIView(context: Context) -> WKWebView {
        let config = Self.configuration(rules: rules)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Rendered SVG image, " + filename
        view.accessibilityIdentifier = "Rendered SVG image"
        view.accessibilityTraits = .image
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.svg != svg else { return }
        context.coordinator.svg = svg
        view.loadHTMLString(Self.html(svg), baseURL: nil)
    }
    static func html(_ svg: String) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; sandbox">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent}body{display:flex;align-items:center;justify-content:center}body>svg{width:calc(100% - 40px);height:calc(100% - 40px);max-width:1600px;max-height:1600px}</style></head><body>\(svg)</body></html>
        """
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var svg: String?
        let onFinish: () -> Void
        let onFailure: (String) -> Void
        init(onFinish: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.onFinish = onFinish; self.onFailure = onFailure
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let initial = action.navigationType == .other && action.targetFrame?.isMainFrame == true && action.request.url?.absoluteString == "about:blank"
            decisionHandler(initial ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure("This SVG could not be rendered. Use Source to inspect it.") }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure("This SVG could not be rendered. Use Source to inspect it.") }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure("The image preview stopped. Use Source or refresh to try again.") }
    }
}
#endif
