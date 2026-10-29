import XCTest
@testable import RemoteFilesCore

final class EnhancedMarkdownPolicyTests: XCTestCase {
    func testRichSyntaxSelectsOfflineRendererAndOrdinaryMarkdownStaysNative() {
        for source in ["```mermaid\ngraph TD\n A-->B\n```", "~~~mermaid\nsequenceDiagram\n A->>B: Hello\n~~~",
                       "Inline $x^2$ equation", "$$\n\\int_0^1 x dx\n$$", #"\(a+b\)"#, #"\[a+b\]"#,
                       "<details><summary>More</summary>HTML content</details>", "Hello <strong>world</strong>"] {
            XCTAssertTrue(EnhancedMarkdownPolicy.requiresEnhancedRendering(source), source)
        }
        for source in ["# Heading\n\n**ordinary** [link](Guide.md)", "![alt](image.png)", "Cost: $5", "2 < 3", "`plain code`"] {
            XCTAssertFalse(EnhancedMarkdownPolicy.requiresEnhancedRendering(source), source)
        }
    }
    func testCodeExamplesAndGenericTypesStayInNativeMarkdown() {
        let examples = [
            "Use `$HOME` and `$PATH` in your shell.",
            "Inline `$x^2$`, `\\(a+b\\)` and `<details>text</details>` examples.",
            "Use ``a ` nested $x$ <strong>example</strong>`` as literal code.",
            "`multiline\n$x$ <strong>example</strong>\ncode`",
            "Array<String> and Result<T,E> are Swift types.",
            "```html\n<strong>example</strong>\n$x^2$\n```",
            "~~~markdown\n$$\nx+y\n$$\n~~~",
            "````markdown\n```mermaid\ngraph TD\n A-->B\n```\n````",
            "    $x^2$\n    <details>example</details>\n",
            "\t$x^2$\n\t<details>example</details>\n",
            "> ```html\n> <strong>example</strong> $x$\n> ```",
            #"Escaped \$x\$ and \\(x\\) stay literal."#,
            "<script>$x$</script>",
            "<!-- <details>$x$</details> -->"
        ]
        for source in examples { XCTAssertFalse(EnhancedMarkdownPolicy.requiresEnhancedRendering(source), source) }
        for source in ["`$HOME` followed by $x^2$", "```html\n<p>example</p>\n```\n\n$x$",
                       "> ```mermaid\n> graph TD\n> A-->B\n> ```", "Hello <STRONG>world</STRONG>",
                       "Inline $**x**$ equation", #"An unmatched \[ followed by $x$ still contains math."#] {
            XCTAssertTrue(EnhancedMarkdownPolicy.requiresEnhancedRendering(source), source)
        }
    }

    func testAllOfflineLibrariesAreBundled() throws {
        let scripts = try EnhancedMarkdownPolicy.rendererScripts()
        XCTAssertEqual(scripts.count, 5)
        XCTAssertTrue(scripts.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(scripts.last?.contains("window.RemoteFilesMarkdown") == true)
    }
}

#if os(iOS)
import SwiftUI
import WebKit
@testable import RemoteFilesUI

@MainActor final class EnhancedMarkdownDisplayTests: XCTestCase {
    private var window: UIWindow?
    private weak var previous: UIWindow?
    private var probe: MarkdownLoadProbe?

    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previous?.makeKey(); probe = nil
        super.tearDown()
    }
    private func renderer() async throws -> WKWebView {
        let rules = try await SVGResourceBlocker.rules()
        let scripts = try EnhancedMarkdownPolicy.rendererScripts()
        let config = EnhancedMarkdownWebView.configuration(rules: rules, scripts: scripts)
        let probe = MarkdownLoadProbe(); self.probe = probe
        config.setURLSchemeHandler(probe, forURLScheme: "fixture")
        config.userContentController.add(probe, name: "attack")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        view.navigationDelegate = probe
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); self.window = window
        let controller = UIViewController(); controller.view = view; window.rootViewController = controller
        window.makeKeyAndVisible()
        view.loadHTMLString(EnhancedMarkdownWebView.html, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while !probe.finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(probe.finished, "The offline renderer must initialize")
        return view
    }
    private func render(_ source: String, in view: WKWebView) async throws -> [String: Any] {
        let value = try await view.callAsyncJavaScript("return await RemoteFilesMarkdown.render(source)",
            arguments: ["source": source], in: nil, contentWorld: .defaultClient)
        return try XCTUnwrap(value as? [String: Any])
    }
    private func inspect(_ script: String, in view: WKWebView) async throws -> Any? {
        try await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
    }
    private func assertScript<T: Equatable>(_ script: String, in view: WKWebView, equals expected: T,
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await inspect(script, in: view) as? T
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    func testMermaidMathAndEmbeddedHTMLRenderOffline() async throws {
        let view = try await renderer()
        _ = try await render(#"""
        # Rich document

        Inline $x^2 + y^2 = z^2$ and \(\frac{1}{2}\).

        $$
        \int_0^1 x^2\,dx = \frac{1}{3}
        $$

        ```mermaid
        graph TD
          A[Start] --> B[Finish]
        ```

        <details open><summary>Details</summary><p>Visible <strong>HTML</strong></p></details>

        `literal $code$` and <em>inline emphasis</em>.
        """#, in: view)
        try await assertScript("document.querySelectorAll('math').length", in: view, equals: 3)
        try await assertScript("document.querySelectorAll('.rf-diagram svg').length", in: view, equals: 1)
        try await assertScript("document.querySelectorAll('.rf-error').length", in: view, equals: 0)
        try await assertScript("document.querySelector('details strong').textContent", in: view, equals: "HTML")
        try await assertScript("document.querySelector('em').textContent", in: view, equals: "inline emphasis")
        try await assertScript("document.querySelector('code').textContent", in: view, equals: "literal $code$")
        let size = try await inspect("document.querySelector('.rf-diagram svg').getBoundingClientRect().height", in: view) as? Double
        XCTAssertGreaterThan(size ?? 0, 30, "A Mermaid diagram must have actual laid-out geometry")
        let revealed = try await inspect("RemoteFilesMarkdown.reveal('Rich document',0,'rich-document')", in: view) as? Bool
        XCTAssertEqual(revealed, true)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(probe?.resources, 0)
    }
    func testEmbeddedHTMLCannotExecuteOrLoadAndInvalidNotationStaysReadable() async throws {
        let view = try await renderer()
        let result = try await render(#"""
        <script>window.webkit.messageHandlers.attack.postMessage('script')</script>
        <img src="fixture://blocked/image" onerror="window.webkit.messageHandlers.attack.postMessage('event')">
        <iframe src="fixture://blocked/frame"></iframe>
        <style>@import 'fixture://blocked/css';</style>
        <svg onload="window.webkit.messageHandlers.attack.postMessage('svg')"><use href="fixture://blocked/svg"></use></svg>
        <div style="background-image:url(fixture://blocked/background)">No authored CSS</div>
        <form action="fixture://blocked/form"><input autofocus onfocus="window.webkit.messageHandlers.attack.postMessage('focus')"></form>
        <a href="javascript:window.webkit.messageHandlers.attack.postMessage('link')">Bad link</a>
        <p onclick="window.webkit.messageHandlers.attack.postMessage('click')">Safe visible text</p>
        <img src="relative.png" alt="Bounded local image">

        $\def\a{\a}\a$

        ```mermaid
        %%{init: {securityLevel: 'loose'}}%%
        graph TD
          A-->B
        ```
        """#, in: view)
        XCTAssertEqual((result["images"] as? [[String:String]])?.first?["reference"], "relative.png")
        XCTAssertEqual((result["images"] as? [[String:String]])?.count, 1)
        try await assertScript("document.getElementById('rf-content').querySelectorAll('script,iframe,form,input,style,svg,[style],[onclick],[onerror],[onfocus],[onload]').length", in: view, equals: 0)
        try await assertScript("document.querySelector('a').hasAttribute('href')", in: view, equals: false)
        try await assertScript("document.querySelectorAll('.rf-error').length", in: view, equals: 2)
        let body = try await inspect("document.body.innerText", in: view) as? String
        XCTAssertTrue(body?.contains("Safe visible text") == true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(probe?.attacks, 0)
        XCTAssertEqual(probe?.resources, 0)
    }
    func testRelativeLinksImagesAndDuplicateHeadingsUseNativeIntegration() async throws {
        let rules = try await SVGResourceBlocker.rules()
        let scripts = try EnhancedMarkdownPolicy.rendererScripts()
        let source = "![Bounded image](picture.png)\n\n# Repeat\n\n$x$\n\n[Next](Guide.md#chapter) [Web](https://example.com)\n\n# Repeat\n\n# Repeat-1\n\n# Math $x$"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try image.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolver = MarkdownImageResolver(file: file)
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "test", identityID: UUID())
        let location = RemoteDocumentLocation(profile: profile, path: "/docs/index.md")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); self.window = window
        var loaded = false, links: [URL] = [], external: [URL] = [], openedImages: [String] = []
        window.rootViewController = UIHostingController(rootView: EnhancedMarkdownWebView(text: source,
            scripts: scripts, rules: rules, readingPosition: DocumentReadingPosition(), navigation: nil,
            location: location, resolver: resolver, active: true,
            onFinish: { loaded = true }, onFailure: { XCTFail($0) },
            openExternalLink: { external.append($0) }, openDocumentLink: { links.append($0) },
            openImage: { reference, _ in openedImages.append(reference) }))
        window.makeKeyAndVisible()
        let deadline = ContinuousClock.now + .seconds(20)
        while !loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(loaded)
        func web(_ root: UIView) -> WKWebView? {
            if let view = root as? WKWebView { return view }
            return root.subviews.lazy.compactMap { web($0) }.first
        }
        let view = try XCTUnwrap(web(window))
        let expectedIDs = try DocumentTextIndex(text: source, markdown: true).headings.map(\.id).joined(separator: ",")
        try await assertScript("Array.from(document.querySelectorAll('h1')).map(e=>e.id).join(',')", in: view, equals: expectedIDs)
        _ = try await inspect("Array.from(document.querySelectorAll('a')).find(e=>e.textContent==='Next').click(); Array.from(document.querySelectorAll('a')).find(e=>e.textContent==='Web').click(); document.querySelector('.rf-image').click()", in: view)
        let callbackDeadline = ContinuousClock.now + .seconds(5)
        while (links.isEmpty || external.isEmpty || openedImages.isEmpty), ContinuousClock.now < callbackDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(links.map(\.absoluteString), ["Guide.md#chapter"])
        XCTAssertEqual(external.map(\.absoluteString), ["https://example.com"])
        XCTAssertEqual(openedImages, ["picture.png"])
        XCTAssertEqual(view.url?.absoluteString, "about:blank")
        var imageReady = false
        let imageDeadline = ContinuousClock.now + .seconds(10)
        while !imageReady, ContinuousClock.now < imageDeadline {
            imageReady = try await inspect("(document.querySelector('.rf-image img')?.naturalWidth || 0) > 0", in: view) as? Bool ?? false
            if !imageReady { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertTrue(imageReady, "Native decoded image bytes must display through the resource blocker")
        let references = await resolver.references
        XCTAssertEqual(references, ["picture.png"])
    }

    func testDynamicTypeChangesRichTextSizeWithoutReloadingDocument() async throws {
        let rules = try await SVGResourceBlocker.rules()
        let scripts = try EnhancedMarkdownPolicy.rendererScripts()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); self.window = window
        var loads = 0
        func content(_ size: DynamicTypeSize) -> some View {
            EnhancedMarkdownWebView(text: "<p>Accessible rich text wraps into more lines when the reader increases the text size.</p>\n\n$x^2$",
                scripts: scripts, rules: rules, readingPosition: DocumentReadingPosition(), navigation: nil,
                location: nil, resolver: nil, active: true, onFinish: { loads += 1 }, onFailure: { XCTFail($0) },
                openExternalLink: { _ in }, openDocumentLink: nil, openImage: { _, _ in })
                .environment(\.dynamicTypeSize, size)
        }
        let controller = UIHostingController(rootView: content(.large))
        window.rootViewController = controller; window.makeKeyAndVisible()
        let deadline = ContinuousClock.now + .seconds(20)
        while loads == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(loads, 1)
        func web(_ root: UIView) -> WKWebView? {
            if let view = root as? WKWebView { return view }
            return root.subviews.lazy.compactMap { web($0) }.first
        }
        let view = try XCTUnwrap(web(window))
        let fontValue = try await inspect("parseFloat(getComputedStyle(document.body).fontSize)", in: view) as? Double
        let heightValue = try await inspect("document.querySelector('p').getBoundingClientRect().height", in: view) as? Double
        let originalFont = try XCTUnwrap(fontValue), originalHeight = try XCTUnwrap(heightValue)
        XCTAssertEqual(originalFont, Double(EnhancedMarkdownWebView.bodyPointSize(for: .large)), accuracy: 0.1)
        controller.rootView = content(.accessibility5)
        let expectedSize = Double(EnhancedMarkdownWebView.bodyPointSize(for: .accessibility5))
        var updatedFont = originalFont
        let updateDeadline = ContinuousClock.now + .seconds(5)
        while abs(updatedFont - expectedSize) > 0.1, ContinuousClock.now < updateDeadline {
            try await Task.sleep(for: .milliseconds(25))
            updatedFont = try await inspect("parseFloat(getComputedStyle(document.body).fontSize)", in: view) as? Double ?? 0
        }
        XCTAssertEqual(updatedFont, expectedSize, accuracy: 0.1)
        XCTAssertGreaterThan(updatedFont, originalFont * 2)
        let updatedHeightValue = try await inspect("document.querySelector('p').getBoundingClientRect().height", in: view) as? Double
        let updatedHeight = try XCTUnwrap(updatedHeightValue)
        XCTAssertGreaterThan(updatedHeight, originalHeight * 2, "Accessibility sizing must change real text layout")
        XCTAssertTrue(web(window) === view, "Changing Dynamic Type must keep the current renderer")
        XCTAssertEqual(loads, 1, "Dynamic Type updates CSS without reloading the document or its images")
    }

    func testNotationBudgetsAndSourceLimitFailClosed() async throws {
        let view = try await renderer()
        _ = try await render(Array(repeating: "$x$", count: 129).joined(separator: "\n\n"), in: view)
        try await assertScript("document.querySelectorAll('math').length", in: view, equals: 128)
        try await assertScript("document.querySelectorAll('.rf-error').length", in: view, equals: 1)
        do {
            _ = try await render(String(repeating: "x", count: EnhancedMarkdownPolicy.maximumSourceBytes + 1), in: view)
            XCTFail("Oversized Markdown must fail before parsing")
        } catch { }
    }
}

private actor MarkdownImageResolver: RemoteResourceResolving {
    let file: URL
    private(set) var references: [String] = []
    init(file: URL) { self.file = file }
    func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        references.append(reference); return file
    }
}

@MainActor private final class MarkdownLoadProbe: NSObject, WKNavigationDelegate, WKURLSchemeHandler, WKScriptMessageHandler {
    var finished = false, resources = 0, attacks = 0
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        resources += 1; urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { attacks += 1 }
}
#endif
