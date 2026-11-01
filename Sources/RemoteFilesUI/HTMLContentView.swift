#if os(iOS)
import SwiftUI
import WebKit
import RemoteFilesCore

struct HTMLContentView: View {
    let text: String
    let filename: String
    let readingPosition: DocumentReadingPosition
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var fontSize = 17.0
    @State private var rules: WKContentRuleList?
    @State private var error: String?
    @State private var loaded = false
    @State private var needsScripts = false
    var body: some View {
        ZStack {
            if let error {
                ContentUnavailableView("Rendered Preview Unavailable", systemImage: "doc.text", description: Text(error))
            } else if let rules {
                StaticHTMLWebView(text: text, filename: filename, rules: rules, readingPosition: readingPosition, fontScale: fontSize / 17,
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
                // A hang guard, not a performance target. Every rendered view starts a new WebKit
                // content process, and on loaded hosted runners those launches took 13 seconds or
                // more, so a 15-second guard failed documents that rendered moments later
                // (docs/CI.md). Source stays one tap away while this spinner shows.
                try await Task.sleep(for: .seconds(30))
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
    var fontScale: Double = 1
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
    /// WebKit's CSS scroll anchoring requests its own native scroll after reflow,
    /// which can override or interrupt the app's text/block anchor restoration.
    static func html(_ source: String) -> String {
        """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark;overflow-anchor:none!important}body{font:17px -apple-system,sans-serif;margin:20px;overflow-wrap:break-word}img,video,svg{max-width:100%;height:auto}</style>
        </head><body>\(source)</body></html>
        """
    }
    func makeCoordinator() -> Coordinator {
        Coordinator(readingPosition: readingPosition, onFinish: onFinish, onFailure: onFailure, openExternalLink: openExternalLink)
    }
    func makeUIView(context: Context) -> WKWebView {
        let view = AnchoredHTMLWebView(frame: .zero, configuration: Self.configuration(rules: rules))
        context.coordinator.attach(view)
        view.navigationDelegate = context.coordinator
        view.scrollView.delegate = context.coordinator
        // SwiftUI already places this viewport within the reader's safe area.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.accessibilityIdentifier = "Rendered HTML document"
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.text.map({ $0.utf8.elementsEqual(text.utf8) }) != true {
            coordinator.beginLoading(text)
            coordinator.navigation = view.loadHTMLString(Self.html(text), baseURL: nil)
        }
        if abs(view.pageZoom - fontScale) > 0.001 {
            coordinator.restorePosition()
            view.pageZoom = fontScale
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        view.stopLoading(); view.navigationDelegate = nil; view.scrollView.delegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var text: String?
        var navigation: WKNavigation?
        var initialNavigation = true
        var finishedLoading = false
        var active = true
        weak var view: AnchoredHTMLWebView?
        private var sessionID = UUID()
        private var generation = UUID()
        private var captureTask: Task<Void, Never>?
        private var geometryObservation: NSKeyValueObservation?
        private var restorationTask: Task<Void, Never>?
        private var restoring = false
        private var applyingRestoration = false
        private var expectedOffset = CGPoint.zero
        private var restorationViewport = CGSize.zero
        private var restorationContent = CGSize.zero
        let readingPosition: DocumentReadingPosition
        let onFinish: (Bool) -> Void
        let onFailure: (String) -> Void
        let openExternalLink: (URL) -> Void
        init(readingPosition: DocumentReadingPosition, onFinish: @escaping (Bool) -> Void,
             onFailure: @escaping (String) -> Void, openExternalLink: @escaping (URL) -> Void) {
            self.readingPosition = readingPosition; self.onFinish = onFinish
            self.onFailure = onFailure; self.openExternalLink = openExternalLink
        }
        func attach(_ view: AnchoredHTMLWebView) {
            self.view = view
            readingPosition.htmlSessionID = sessionID
            readingPosition.captureHTMLPosition = { [weak self] in await self?.capturePosition() }
            view.layoutChanged = { [weak self] in self?.restorePosition() }
            view.userScrolled = { [weak self] in self?.cancelRestoration() }
        }
        func beginLoading(_ text: String) {
            generation = UUID()
            captureTask?.cancel(); restorationTask?.cancel()
            sessionID = UUID()
            readingPosition.htmlSessionID = sessionID
            readingPosition.captureHTMLPosition = { [weak self] in await self?.capturePosition() }
            self.text = text; initialNavigation = true; finishedLoading = false; restoring = false
            geometryObservation = nil
        }
        func detach() {
            active = false
            restorationTask?.cancel(); captureTask?.cancel(); geometryObservation = nil
            view?.layoutChanged = nil; view?.userScrolled = nil
            // Keep only this final capture alive through representable teardown. Session
            // and generation checks prevent it writing into a replacement reader.
            Task { [self, view] in
                await capturePosition()
                withExtendedLifetime(view) {} // Final DOM capture has a one-second deadline.
                if readingPosition.htmlSessionID == sessionID {
                    readingPosition.captureHTMLPosition = nil
                    readingPosition.htmlSessionID = nil
                    await readingPosition.flush()
                }
            }
        }
        func capturePosition(attempt: Int = 0) async {
            guard finishedLoading, !restoring, let view,
                  readingPosition.htmlSessionID == sessionID else { return }
            let token = generation
            let offset = view.scrollView.contentOffset
            recordCoordinateFallback(offset)
            let anchor: SavedReadingPosition.Anchor?
            do { anchor = try await HTMLReadingAnchor.capture(in: view) }
            catch {
                // A newly launched web process may miss the short inspection deadline.
                // Retry only while this renderer still owns the same live session.
                if active, attempt < 2, token == generation, !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    await capturePosition(attempt: attempt + 1)
                }
                return // The current coordinate fallback was saved before inspection.
            }
            guard !Task.isCancelled, token == generation, !restoring, readingPosition.htmlSessionID == sessionID,
                  abs(view.scrollView.contentOffset.y - offset.y) < 1,
                  abs(view.scrollView.contentOffset.x - offset.x) < 1 else { return }
            readingPosition.htmlAnchor = anchor
            readingPosition.rendered = CGPoint(x: max(0, offset.x), y: max(0, offset.y))
        }
        private func recordCoordinateFallback(_ offset: CGPoint) {
            guard finishedLoading, !restoring, readingPosition.htmlSessionID == sessionID,
                  offset.x.isFinite, offset.y.isFinite else { return }
            let point = CGPoint(x: max(0, offset.x), y: max(0, offset.y))
            if point != readingPosition.rendered {
                // A previous DOM anchor must not override a newer native position if
                // inspection fails or this renderer disappears before it completes.
                readingPosition.htmlAnchor = nil
                readingPosition.rendered = point
            }
        }
        func restorePosition() {
            guard active, finishedLoading, let view, !view.scrollView.isDragging,
                  !view.scrollView.isDecelerating, readingPosition.htmlSessionID == sessionID else { return }
            captureTask?.cancel(); restorationTask?.cancel()
            restoring = true
            expectedOffset = view.scrollView.contentOffset
            restorationViewport = view.bounds.size
            restorationContent = view.scrollView.contentSize
            generation = UUID()
            let token = generation
            let anchor = readingPosition.htmlAnchor
            let fallback = readingPosition.rendered
            restorationTask = Task { [weak self, weak view] in
                defer {
                    if let self, self.generation == token { self.restoring = false }
                }
                // A hidden/replaced viewport must not consume its saved anchor before
                // it has a real layout. The wait is bounded and cancelled on detach.
                for _ in 0..<25 {
                    guard let view else { return }
                    if view.window != nil, view.bounds.width > 0, view.bounds.height > 0 { break }
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                }
                guard let view, view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return }
                // WebKit lays out asynchronously after UIKit bounds/pageZoom changes.
                // Keep the original target throughout these bounded corrections.
                var corrections = 0
                for attempt in 0..<60 {
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                    guard let self, self.active, self.generation == token,
                          self.readingPosition.htmlSessionID == self.sessionID,
                          !view.scrollView.isDragging, !view.scrollView.isDecelerating else { return }
                    let maxY = max(0, view.scrollView.contentSize.height - view.scrollView.bounds.height)
                    // didFinish/DOM readiness can precede delivery of WebKit's native
                    // scroll geometry. Do not consume the target by clamping it to zero
                    // during that interval. Truly shorter documents clamp at the deadline.
                    if attempt < 59, fallback.y > 0,
                       (maxY == 0 || (anchor == nil && maxY + 1 < fallback.y)) { continue }
                    let target: CGPoint?
                    if let anchor { target = try? await HTMLReadingAnchor.target(for: anchor, in: view) }
                    else { target = nil }
                    guard !Task.isCancelled, self.active, self.generation == token,
                          self.readingPosition.htmlSessionID == self.sessionID,
                          !view.scrollView.isDragging, !view.scrollView.isDecelerating else { return }
                    let scroll = view.scrollView
                    // DOM work only resolves geometry. Apply scrolling natively after
                    // cancellation checks so an old WebKit reply cannot undo user input.
                    self.expectedOffset = CGPoint(
                        x: min(max(0, fallback.x), max(0, scroll.contentSize.width - scroll.bounds.width)),
                        y: min(max(0, target?.y ?? fallback.y), max(0, scroll.contentSize.height - scroll.bounds.height)))
                    self.restorationViewport = view.bounds.size
                    self.restorationContent = scroll.contentSize
                    self.applyingRestoration = true
                    scroll.setContentOffset(self.expectedOffset, animated: false)
                    self.applyingRestoration = false
                    corrections += 1
                    if corrections >= 3 { break }
                }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.restoring = false
                await self.capturePosition()
            }
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if initialNavigation, action.navigationType == .other, action.targetFrame?.isMainFrame == true,
               action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow); return
            }
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.scheme == "about", url.path == "blank", url.fragment != nil {
                    cancelRestoration()
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
            let token = generation
            view.evaluateJavaScript("""
            document.body.innerText.trim().length === 0 &&
            !Array.from(document.querySelectorAll('img,svg,video')).some(e => e.getBoundingClientRect().height > 0)
            """, in: nil, in: .defaultClient) { [weak self, weak view] result in
                guard let self, self.active, let view, self.generation == token else { return }
                switch result {
                case .success(let value):
                    let needsScripts = hasScripts && (value as? Bool ?? false)
                    self.afterNativeGeometry(of: view, token: token) { [weak self] in
                        guard let self else { return }
                        self.finishedLoading = true
                        self.restorePosition()
                        self.onFinish(needsScripts)
                    }
                case .failure(let error):
                    self.onFailure("The HTML preview could not finish loading: " + error.localizedDescription)
                }
            }
        }
        /// didFinish and DOM readiness can precede WebKit's first layer-tree commit,
        /// which then resets the native offset to the top. Restoration, capture and
        /// scroll tracking start only once that commit has supplied native geometry.
        /// A reused viewport keeps its geometry; its changed revision starts at the top.
        private func afterNativeGeometry(of view: WKWebView, token: UUID, _ ready: @escaping () -> Void) {
            func committed(_ scroll: UIScrollView) -> Bool { scroll.contentSize.width > 0 && scroll.contentSize.height > 0 }
            guard !committed(view.scrollView) else { ready(); return }
            geometryObservation = view.scrollView.observe(\.contentSize) { [weak self] scroll, _ in
                guard MainActor.assumeIsolated({ committed(scroll) }) else { return }
                // Leave this callback and WebKit's commit, including its offset reset, first.
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.generation == token, self.geometryObservation != nil else { return }
                    self.geometryObservation = nil
                    ready()
                }
            }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard active, finishedLoading else { return }
            if restoring {
                let layoutChanged = restorationViewport != scrollView.bounds.size || restorationContent != scrollView.contentSize
                restorationViewport = scrollView.bounds.size
                restorationContent = scrollView.contentSize
                if applyingRestoration { return }
                if layoutChanged {
                    let clamped = CGPoint(
                        x: min(max(0, expectedOffset.x), max(0, scrollView.contentSize.width - scrollView.bounds.width)),
                        y: min(max(0, expectedOffset.y), max(0, scrollView.contentSize.height - scrollView.bounds.height)))
                    if abs(scrollView.contentOffset.y - clamped.y) < 1 &&
                        abs(scrollView.contentOffset.x - clamped.x) < 1 {
                        expectedOffset = clamped
                        return
                    }
                }
                if abs(scrollView.contentOffset.y - expectedOffset.y) < 1 &&
                    abs(scrollView.contentOffset.x - expectedOffset.x) < 1 { return }
                // Keyboard and accessibility scrolling can arrive without touch flags.
                // Only our own offset writes and reflow corrections are suppressed.
                cancelRestoration()
            }
            recordCoordinateFallback(scrollView.contentOffset)
            captureTask?.cancel()
            captureTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                await self?.capturePosition()
            }
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cancelRestoration() }
        private func cancelRestoration() {
            guard finishedLoading else { return }
            generation = UUID()
            restorationTask?.cancel(); restoring = false
        }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed() }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed() }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) { failed() }
        private func failed() {
            generation = UUID(); finishedLoading = false; restoring = false
            restorationTask?.cancel(); captureTask?.cancel(); geometryObservation = nil
            if active { onFailure("This HTML could not be rendered. Use Source or refresh to try again.") }
        }
    }
}

/// A viewport callback avoids retaining document layout in route-level state.
final class AnchoredHTMLWebView: WKWebView {
    var layoutChanged: (() -> Void)?
    var userScrolled: (() -> Void)?
    private var previousSize = CGSize.zero
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { layoutChanged?() }
    }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        userScrolled?()
        return super.accessibilityScroll(direction)
    }
    override func layoutSubviews() {
        let changed = previousSize != .zero && previousSize != bounds.size
        previousSize = bounds.size
        super.layoutSubviews()
        if changed { layoutChanged?() }
    }
}
#endif
