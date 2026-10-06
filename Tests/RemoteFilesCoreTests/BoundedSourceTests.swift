import SwiftUI
import XCTest
@testable import RemoteFilesUI

final class BoundedSourceTests: XCTestCase {
    func testLongLinesTallDocumentsAndLargeInputsUseBoundedLayout() {
        XCTAssertFalse(SourceLayout.needsBoundedLayout("{\n  \"value\": 1\n}\n"))
        XCTAssertFalse(SourceLayout.needsBoundedLayout(String(repeating: "a", count: 512)))
        XCTAssertTrue(SourceLayout.needsBoundedLayout(String(repeating: "a", count: 513)))
        XCTAssertTrue(SourceLayout.needsBoundedLayout("{\"prompt\":\"" + String(repeating: "safe sample ", count: 320) + "\"}"))
        XCTAssertTrue(SourceLayout.needsBoundedLayout(String(repeating: "a\n", count: 513)))
        XCTAssertTrue(SourceLayout.needsBoundedLayout(String(repeating: "🌍", count: 17_000)))
        XCTAssertFalse(SourceLayout.needsBoundedLayout(String(repeating: "a\r\n", count: 100)))
    }
}

#if os(iOS)
import UIKit
import WebKit
import RemoteFilesCore

@MainActor final class BoundedSourceDisplayTests: XCTestCase {
    func testLongJSONActuallyDrawsAndKeepsExactSelectableText() async throws {
        let source = "{\n  \"prompt\": \"" + String(repeating: "safe sample 東京 🌍 e\u{301} ", count: 180) + "\",\r\n  \"ready\": true\n}\n"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: DocumentContentView(text: source, markdown: false, source: true, filename: "long.json"))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func find(_ view: UIView) -> SourceTextView? {
            if let text = view as? SourceTextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while find(window) == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let view = try XCTUnwrap(find(window))
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        XCTAssertEqual(Data(view.text.utf8), Data(source.utf8))
        XCTAssertLessThanOrEqual(view.textContainer.size.width, window.bounds.width)
        XCTAssertGreaterThan(view.contentSize.height, view.bounds.height)
        view.selectedRange = NSRange(location: 0, length: source.utf16.count)
        view.copy(nil)
        XCTAssertEqual(Data(try XCTUnwrap(UIPasteboard.general.string).utf8), Data(source.utf8))
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let pixels = try XCTUnwrap(image.cgImage)
        let width = pixels.width, height = min(pixels.height, 600)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(pixels, in: CGRect(x: 0, y: height - pixels.height, width: width, height: pixels.height))
        let ink = stride(from: 0, to: bytes.count, by: 4).filter { min(bytes[$0], bytes[$0+1], bytes[$0+2]) < 180 }.count
        XCTAssertGreaterThan(ink, 100, "Accessibility text alone does not prove that the blank-view regression is fixed")
    }
    func testStaticSVGRendererDisablesContentJavaScriptAndUsesNoPersistentData() async throws {
        let rules = try await SVGResourceBlocker.rules()
        let renderer = StaticSVGWebView(svg: "<svg/>", rules: rules, filename: "safe.svg", onFinish: {}, onFailure: { _ in })
        let html = StaticSVGWebView.html("<svg/>")
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("img-src 'none'"))
        let controller = UIHostingController(rootView: renderer)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func web(_ view: UIView) -> WKWebView? {
            if let value = view as? WKWebView { return value }
            return view.subviews.lazy.compactMap { web($0) }.first
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while web(controller.view) == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let view = try XCTUnwrap(web(controller.view))
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
    }

    func testRendererDefensesBlockActiveMarkupAndResourceRequests() async throws {
        let rules = try await SVGResourceBlocker.rules()
        let config = StaticSVGWebView.configuration(rules: rules)
        let probe = SVGAttackProbe()
        config.setURLSchemeHandler(probe, forURLScheme: "fixture")
        config.userContentController.add(probe, name: "securityProbe")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), configuration: config)
        view.navigationDelegate = probe
        // Deliberately bypass the XML allowlist to check the renderer's independent
        // defenses. All URLs are owned inert custom-scheme probes, never a real server.
        let attack = """
        <svg xmlns="http://www.w3.org/2000/svg" onload="window.webkit.messageHandlers.securityProbe.postMessage('event')">
        <script>window.webkit.messageHandlers.securityProbe.postMessage('script')</script>
        <image href="fixture://blocked/image"/>
        <style>@import url('fixture://blocked/style'); @font-face{font-family:remote;src:url('fixture://blocked/font')}</style>
        <foreignObject><iframe src="fixture://blocked/frame"></iframe></foreignObject></svg>
        """
        view.loadHTMLString(StaticSVGWebView.html(attack), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while !probe.finished && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(probe.finished, "The local document must finish loading to make the negative checks meaningful")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(probe.scripts, 0)
        XCTAssertEqual(probe.resources, 0)
        view.stopLoading(); view.navigationDelegate = nil
        config.userContentController.removeScriptMessageHandler(forName: "securityProbe")
    }
}

@MainActor final class HTMLDisplayTests: XCTestCase {
    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(ready(), "HTML renderer must finish loading")
    }
    func testStyledHTMLRendersDOMAndVisiblePixels() async throws {
        let rules = try await SVGResourceBlocker.rules()
        let source = "<!doctype html><html><head><style>h1{color:rgb(90,40,220)}</style></head><body><h1>café 東京</h1><table><tr><td>Rendered cell</td></tr></table></body></html>"
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 400), configuration: StaticHTMLWebView.configuration(rules: rules))
        let probe = SVGAttackProbe(); view.navigationDelegate = probe
        view.loadHTMLString(StaticHTMLWebView.html(source), baseURL: nil)
        try await wait { probe.finished }
        let body = try await view.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(body?.contains("café 東京") == true)
        XCTAssertTrue(body?.contains("Rendered cell") == true)
        let color = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('h1')).color") as? String
        XCTAssertEqual(color, "rgb(90, 40, 220)")
        let snapshot = try await view.takeSnapshot(configuration: nil)
        let pixels = try XCTUnwrap(snapshot.cgImage)
        var bytes = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: pixels.width, height: pixels.height, bitsPerComponent: 8,
            bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        let purple = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0+2] > 160 && bytes[$0] < 140 && bytes[$0+1] < 110 }.count
        XCTAssertGreaterThan(purple, 100, "Actual styled pixels must be drawn, not only exposed to accessibility")
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        view.stopLoading(); view.navigationDelegate = nil
    }
    func testHTMLCannotRunDocumentScriptsOrLoadResources() async throws {
        let rules = try await SVGResourceBlocker.rules()
        let config = StaticHTMLWebView.configuration(rules: rules)
        let probe = SVGAttackProbe()
        config.setURLSchemeHandler(probe, forURLScheme: "fixture")
        config.userContentController.add(probe, name: "securityProbe")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), configuration: config)
        view.navigationDelegate = probe
        let source = """
        <html><head><base href="fixture://blocked/"><link rel="stylesheet" href="fixture://blocked/style">
        <style>@import url('fixture://blocked/import');body{background-image:url('fixture://blocked/background')}</style></head>
        <body onload="window.webkit.messageHandlers.securityProbe.postMessage('event')">
        <h1>Static HTML remains visible</h1>
        <script>window.webkit.messageHandlers.securityProbe.postMessage('script')</script>
        <script src="fixture://blocked/script"></script><img src="fixture://blocked/image">
        <iframe src="fixture://blocked/frame"></iframe><object data="fixture://blocked/object"></object>
        <form action="fixture://blocked/form"><input autofocus onfocus="window.webkit.messageHandlers.securityProbe.postMessage('focus')"></form>
        </body></html>
        """
        view.loadHTMLString(StaticHTMLWebView.html(source), baseURL: nil)
        try await wait { probe.finished }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(probe.scripts, 0)
        XCTAssertEqual(probe.resources, 0)
        let content = try await view.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(content?.contains("Static HTML remains visible") == true)
        view.stopLoading(); view.navigationDelegate = nil
        config.userContentController.removeScriptMessageHandler(forName: "securityProbe")
    }
    func testScriptOnlyEntryExplainsEmptyPreview() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let rules = try await SVGResourceBlocker.rules()
        var finished = false, needsScripts = false
        let source = "<!doctype html><html><body><div id='root'></div><script type='module' src='/src/main.tsx'></script></body></html>"
        window.rootViewController = UIHostingController(rootView: StaticHTMLWebView(text: source, filename: "index.html", rules: rules,
            readingPosition: DocumentReadingPosition(), onFinish: { needsScripts = $0; finished = true },
            onFailure: { XCTFail($0) }, openExternalLink: { _ in XCTFail("No automatic browser navigation") }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await wait { finished }
        XCTAssertTrue(needsScripts, "An app entry file must not be presented as a successfully rendered blank page")
    }
}

@MainActor private final class SVGAttackProbe: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    var finished = false, scripts = 0, resources = 0
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { scripts += 1 }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        resources += 1
        urlSchemeTask.didFailWithError(NSError(domain: "OwnedSVGResourceProbe", code: 1))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
#endif
