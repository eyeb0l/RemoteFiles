#if os(iOS)
import SwiftUI
import WebKit
import RemoteFilesCore

struct EnhancedMarkdownView: View {
    let text: String
    let readingPosition: DocumentReadingPosition
    let navigation: ReaderNavigationState?
    let location: RemoteDocumentLocation?
    let resolver: (any RemoteResourceResolving)?
    let openDocumentLink: ((URL) -> Void)?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var scripts: [String]?
    @State private var rules: WKContentRuleList?
    @State private var error: String?
    @State private var loaded = false
    @State private var imagePresentation: ImagePresentation?

    var body: some View {
        ZStack {
            if let error {
                ContentUnavailableView("Rendered Preview Unavailable", systemImage: "doc.text",
                                       description: Text(error))
            } else if let scripts, let rules {
                EnhancedMarkdownWebView(text: text, scripts: scripts, rules: rules,
                    readingPosition: readingPosition, navigation: navigation,
                    location: location, resolver: resolver, active: scenePhase == .active,
                    onFinish: { loaded = true }, onFailure: { error = $0 },
                    openExternalLink: { openURL($0) }, openDocumentLink: openDocumentLink,
                    openImage: { reference, alt in
                        guard let location else { return }
                        imagePresentation = .init(reference: reference,
                            filename: URLComponents(string: reference)?.path.split(separator: "/").last.map(String.init) ?? reference,
                            location: location, alt: alt)
                    })
                    // Run the page to the bottom edge; the web view's automatic content
                    // inset keeps the last line clear of the home indicator.
                    .ignoresSafeArea(.container, edges: .bottom)
                if !loaded { ProgressView("Rendering Markdown…") }
            } else { ProgressView("Preparing Markdown…") }
        }
        .task(id: Data(text.utf8)) {
            error = nil; loaded = false
            do {
                scripts = try await MarkdownRendererAssets.shared.load()
                rules = try await SVGResourceBlocker.rules()
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(20))
                if !loaded { error = "This Markdown could not finish rendering. Use Source to inspect it." }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .fullScreenCover(item: $imagePresentation) { item in
            if let resolver { RemoteImageViewer(item: item, resolver: resolver) }
        }
    }
}

private actor MarkdownRendererAssets {
    static let shared = MarkdownRendererAssets()
    private var scripts: [String]?
    func load() throws -> [String] {
        if let scripts { return scripts }
        let result = try EnhancedMarkdownPolicy.rendererScripts()
        scripts = result
        return result
    }
}

struct EnhancedMarkdownWebView: UIViewRepresentable {
    let text: String
    let scripts: [String]
    let rules: WKContentRuleList
    let readingPosition: DocumentReadingPosition
    let navigation: ReaderNavigationState?
    let location: RemoteDocumentLocation?
    let resolver: (any RemoteResourceResolving)?
    let active: Bool
    let onFinish: () -> Void
    let onFailure: (String) -> Void
    let openExternalLink: (URL) -> Void
    let openDocumentLink: ((URL) -> Void)?
    let openImage: (String, String) -> Void

    static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>:root{color-scheme:light dark}body{font:var(--rf-body-size,17px) -apple-system,sans-serif;-webkit-text-size-adjust:100%;margin:20px;overflow-wrap:break-word;line-height:1.5}h1,h2,h3{line-height:1.2}pre{overflow:auto;padding:12px;background:rgba(128,128,128,.12);border-radius:8px}code{font-family:ui-monospace,monospace}table{display:block;overflow:auto;border-collapse:collapse}td,th{border:1px solid gray;padding:6px 10px}blockquote{margin-inline:0;padding-inline:16px;border-inline-start:3px solid gray}img,svg{max-width:100%;height:auto}.rf-diagram,.rf-math-display{display:block;overflow:auto;margin-block:16px}.rf-error{display:block;color:GrayText}.rf-image{display:block;border:0;border-radius:8px;padding:8px;width:100%;min-height:80px;background:rgba(128,128,128,.1);color:inherit;font:inherit}math{font-size:1.15em}a{color:LinkText}</style>
    </head><body><main id="rf-content"></main></body></html>
    """

    static func configuration(rules: WKContentRuleList, scripts: [String]) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Document-supplied JavaScript never runs. App-owned scripts are injected into an isolated world.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(rules)
        for source in scripts {
            configuration.userContentController.addUserScript(WKUserScript(source: source,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        return configuration
    }
    static func bodyPointSize(for size: DynamicTypeSize) -> CGFloat {
        let category: UIContentSizeCategory
        switch size {
        case .xSmall: category = .extraSmall
        case .small: category = .small
        case .medium: category = .medium
        case .large: category = .large
        case .xLarge: category = .extraLarge
        case .xxLarge: category = .extraExtraLarge
        case .xxxLarge: category = .extraExtraExtraLarge
        case .accessibility1: category = .accessibilityMedium
        case .accessibility2: category = .accessibilityLarge
        case .accessibility3: category = .accessibilityExtraLarge
        case .accessibility4: category = .accessibilityExtraExtraLarge
        case .accessibility5: category = .accessibilityExtraExtraExtraLarge
        @unknown default: category = .large
        }
        return UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = Self.configuration(rules: rules, scripts: scripts)
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "markdownImage")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.scrollView.delegate = context.coordinator
        view.accessibilityIdentifier = "Rendered Markdown document"
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let wasActive = coordinator.parent.active
        coordinator.parent = self
        coordinator.bodyPointSize = Self.bodyPointSize(for: context.environment.dynamicTypeSize)
        if active, !wasActive, coordinator.finished {
            view.evaluateJavaScript("RemoteFilesMarkdown.resumeImages()", in: nil, in: .defaultClient) { _ in }
        }
        if !active { coordinator.cancelImages() }
        if coordinator.source?.utf8.elementsEqual(text.utf8) != true {
            coordinator.cancelImages(); coordinator.cancelGeometryWait(); coordinator.source = text
            coordinator.finished = false; coordinator.initialNavigation = true
            coordinator.load = view.loadHTMLString(Self.html, baseURL: nil)
        } else { coordinator.updateTextSize(); coordinator.revealIfNeeded() }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.mounted = false; coordinator.cancelImages(); coordinator.cancelGeometryWait()
        if coordinator.finished { coordinator.parent.readingPosition.rendered = view.scrollView.contentOffset }
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdownImage", contentWorld: .defaultClient)
        view.stopLoading(); view.navigationDelegate = nil; view.scrollView.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        var parent: EnhancedMarkdownWebView
        weak var view: WKWebView?
        var source: String?
        var load: WKNavigation?
        var initialNavigation = true
        var finished = false
        var mounted = true
        var generation = 0
        var bodyPointSize: CGFloat = 17
        private var appliedBodyPointSize: CGFloat?
        var images: [(reference: String, alt: String)] = []
        var imageTasks: [Int: Task<Void, Never>] = [:]
        var pendingImages: Set<Int> = []
        var lastReveal: UUID?
        private var geometryObservation: NSKeyValueObservation?
        private var geometryDeadline: Task<Void, Never>?
        private var geometryReady: (() -> Void)?
        init(parent: EnhancedMarkdownWebView) { self.parent = parent }
        func cancelImages() { imageTasks.values.forEach { $0.cancel() }; imageTasks = [:]; pendingImages = [] }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === load, let source else { return }
            initialNavigation = false
            appliedBodyPointSize = bodyPointSize
            view.callAsyncJavaScript("document.documentElement.style.setProperty('--rf-body-size', bodySize + 'px'); return await RemoteFilesMarkdown.render(source)",
                arguments: ["source": source, "bodySize": bodyPointSize],
                in: nil, in: .defaultClient) { [weak self, weak view] result in
                guard let self, self.mounted, let view, navigation === self.load else { return }
                switch result {
                case .success(let result):
                    guard let result = result as? [String: Any], let generation = result["generation"] as? Int else {
                        self.parent.onFailure("The Markdown renderer returned no content. Use Source to inspect it."); return
                    }
                    self.generation = generation
                    self.images = (result["images"] as? [[String: String]] ?? []).prefix(EnhancedMarkdownPolicy.maximumImages).map {
                        ($0["reference"] ?? "", $0["alt"] ?? "")
                    }
                    let height = CGFloat((result["height"] as? NSNumber)?.doubleValue ?? 0)
                    self.afterRenderedGeometry(of: view, documentHeight: height) { [weak self, weak view] in
                        guard let self, self.mounted, let view, navigation === self.load else { return }
                        view.scrollView.setContentOffset(self.parent.readingPosition.rendered, animated: false)
                        self.finished = true; self.updateTextSize(); self.parent.onFinish(); self.revealIfNeeded()
                        for index in self.pendingImages { self.loadImage(index) }; self.pendingImages = []
                    }
                case .failure:
                    self.parent.onFailure("This Markdown could not be rendered. Use Source or refresh to try again.")
                }
            }
        }
        /// `render` resolves before WebKit commits the rendered layout, so the native scroll view
        /// can still have the empty template's height. That commit can reset an offset applied
        /// meanwhile to the top, and scroll tracking would then save the top as the reading
        /// position. Restore and start tracking once native geometry covers the document, after
        /// leaving the commit's callback. If it never does, proceed after a bounded wait.
        private func afterRenderedGeometry(of view: WKWebView, documentHeight: CGFloat, _ ready: @escaping () -> Void) {
            cancelGeometryWait()
            let committed = { (scroll: UIScrollView) in scroll.contentSize.height + 1 >= documentHeight * scroll.zoomScale }
            guard !committed(view.scrollView) else { ready(); return }
            geometryReady = ready
            geometryObservation = view.scrollView.observe(\.contentSize) { [weak self] scroll, _ in
                guard MainActor.assumeIsolated({ committed(scroll) }) else { return }
                Task { @MainActor [weak self] in self?.finishGeometryWait() }
            }
            geometryDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finishGeometryWait()
            }
        }
        private func finishGeometryWait() {
            guard let ready = geometryReady else { return }
            cancelGeometryWait(); ready()
        }
        func cancelGeometryWait() {
            geometryObservation = nil; geometryDeadline?.cancel(); geometryDeadline = nil; geometryReady = nil
        }
        func updateTextSize() {
            guard mounted, finished, let view, appliedBodyPointSize != bodyPointSize else { return }
            appliedBodyPointSize = bodyPointSize
            view.callAsyncJavaScript("document.documentElement.style.setProperty('--rf-body-size', bodySize + 'px')",
                arguments: ["bodySize": bodyPointSize], in: nil, in: .defaultClient) { _ in }
        }
        func revealIfNeeded() {
            guard finished, let view, let navigation = parent.navigation,
                  let reveal = navigation.reveal, !reveal.inSource,
                  navigation.pendingRevealID == reveal.id, lastReveal != reveal.id else { return }
            lastReveal = reveal.id
            let heading = navigation.index?.headings.first { $0.target == reveal.target }
            var text = navigation.query, occurrence = navigation.selected
            if text.isEmpty, let part = navigation.index?.parts.first(where: { $0.id == reveal.target.partID }),
               case .text(let attributed) = part.content {
                text = (String(attributed.characters) as NSString).substring(with: reveal.target.range); occurrence = 0
            }
            view.callAsyncJavaScript("return RemoteFilesMarkdown.reveal(text, occurrence, heading)",
                arguments: ["text": text, "occurrence": occurrence, "heading": heading?.id as Any? ?? NSNull()],
                in: nil, in: .defaultClient) { result in
                    // A missing rendered match remains pending; Source can reveal the original notation.
                    if case .success(let value) = result, value as? Bool == true { navigation.didReveal(reveal.id) }
                }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard mounted, parent.active, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any] else { return }
            if body["kind"] as? String == "link", let reference = body["reference"] as? String,
               let url = URL(string: reference) {
                if DocumentPolicy.allowsExternalLink(url) { parent.openExternalLink(url) }
                else if DocumentPolicy.isRelativeDocumentLink(url) { parent.openDocumentLink?(url) }
                return
            }
            guard let index = body["index"] as? Int,
                  index >= 0, index < EnhancedMarkdownPolicy.maximumImages,
                  let revision = body["generation"] as? Int else { return }
            if !finished { if body["kind"] as? String == "load" { pendingImages.insert(index) }; return }
            guard revision == generation, images.indices.contains(index) else { return }
            if body["kind"] as? String == "open" { parent.openImage(images[index].reference, images[index].alt) }
            else if body["kind"] as? String == "load" { loadImage(index) }
        }
        func loadImage(_ index: Int) {
            guard mounted, parent.active, images.indices.contains(index), imageTasks[index] == nil,
                  let resolver = parent.resolver, let location = parent.location else { return }
            let image = images[index], generation = generation, load = load
            imageTasks[index] = Task { [weak self] in
                var data = "", failureMessage = ""
                do {
                    let file = try await resolver.localFile(for: image.reference, in: location)
                    let decoded = try await RemoteImageDecoder.shared.decode(file, maxPixel: 1600)
                    try Task.checkCancellation()
                    guard let encoded = UIImage(cgImage: decoded.image).pngData() else { throw RemoteResourceError.notImage }
                    data = "data:image/png;base64," + encoded.base64EncodedString()
                } catch is CancellationError { return }
                catch { failureMessage = error.localizedDescription }
                guard let self, self.mounted, load === self.load, !Task.isCancelled, let view = self.view else { return }
                view.callAsyncJavaScript("RemoteFilesMarkdown.setImage(index, generation, data, error)",
                    arguments: ["index": index, "generation": generation, "data": data, "error": failureMessage], in: nil, in: .defaultClient) { _ in }
                self.imageTasks[index] = nil
            }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if finished { parent.readingPosition.rendered = scrollView.contentOffset }
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if initialNavigation, action.navigationType == .other, action.targetFrame?.isMainFrame == true,
               action.request.url?.absoluteString == "about:blank" { decisionHandler(.allow); return }
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.scheme == "about", url.path == "blank", url.fragment != nil { decisionHandler(.allow); return }
                if DocumentPolicy.allowsExternalLink(url) { parent.openExternalLink(url) }
                else if DocumentPolicy.isRelativeDocumentLink(url) { parent.openDocumentLink?(url) }
            }
            decisionHandler(.cancel)
        }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(navigation) }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(navigation) }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) { failed(load) }
        private func failed(_ navigation: WKNavigation?) {
            if mounted, navigation === load { parent.onFailure("This Markdown could not be rendered. Use Source or refresh to try again.") }
        }
    }
}
#endif
