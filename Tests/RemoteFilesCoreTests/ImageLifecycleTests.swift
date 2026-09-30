#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import RemoteFilesCore
@testable import RemoteFilesUI

private actor ImageReloadResolver: RemoteResourceResolving {
    let file: URL
    let reloadError: Error
    private(set) var calls = 0
    init(file: URL, reloadError: Error) { self.file = file; self.reloadError = reloadError }
    func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        calls += 1
        if calls == 2 { throw reloadError }
        return file
    }
}

@MainActor @Observable private final class ImageViewerPhase { var value: ScenePhase = .active }
private struct ImageViewerFixture: View {
    let phase: ImageViewerPhase
    let item: ImagePresentation
    let resolver: ImageReloadResolver
    var body: some View { RemoteImageViewer(item: item, resolver: resolver).environment(\.scenePhase, phase.value) }
}

@MainActor final class ImageLifecycleTests: XCTestCase {
    private func png() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 150))
        try renderer.pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        }.write(to: url)
        return url
    }
    private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }
    private func shareEnabled(_ window: UIWindow) -> Bool? {
        func navigationItem(_ controller: UIViewController) -> UIBarButtonItem? {
            if let navigation = controller as? UINavigationController,
               let topItem = navigation.topViewController?.navigationItem,
               let item = topItem.trailingItemGroups.flatMap(\.barButtonItems).first ?? topItem.rightBarButtonItems?.first {
                return item
            }
            return controller.children.lazy.compactMap(navigationItem).first
        }
        // The viewer has one trailing navigation action: Share. UIKit can render
        // that item without a UIButton carrying the action's accessibility label.
        return window.rootViewController.flatMap(navigationItem)?.isEnabled
    }
    private func hasZoomImage(_ window: UIWindow) -> Bool {
        views(window).contains { view in
            // Ignore toolbar symbols and the unavailable-view's photo icon.
            view is UIScrollView && view.subviews.contains { ($0 as? UIImageView)?.image != nil }
        }
    }
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for image lifecycle state", file: file, line: line)
    }
    private func capture(_ name: String, _ window: UIWindow) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func checkReloadFailure(_ error: Error) async throws {
        let url = try png()
        defer { try? FileManager.default.removeItem(at: url) }
        await RemoteImageDecoder.shared.clear()
        let resolver = ImageReloadResolver(file: url, reloadError: error)
        let phase = ImageViewerPhase()
        let profile = ConnectionProfile(name: "Image tests", host: "fixture.invalid", username: "fixture", identityID: UUID())
        let item = ImagePresentation(reference: "image.png", filename: "image.png", location: .init(profile: profile, path: "/fixture/report.md"))
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try host(ImageViewerFixture(phase: phase, item: item, resolver: resolver))
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        try await waitUntil { self.hasZoomImage(window) }
        let initialCalls = await resolver.calls
        XCTAssertEqual(initialCalls, 1)
        phase.value = .background
        try await Task.sleep(for: .milliseconds(200))
        phase.value = .active
        try await waitUntil { await resolver.calls == 2 }
        // Allow the throwing task and SwiftUI to publish the failure screen.
        try await Task.sleep(for: .milliseconds(200))
        capture("image-reload-failure", window)
        XCTAssertFalse(hasZoomImage(window), "A failed reload must expose error/retry instead of retaining the zoom image")
        try await waitUntil { self.shareEnabled(window) == false }
        XCTAssertEqual(shareEnabled(window), false, "The discarded image must not remain shareable")
        phase.value = .background
        try await Task.sleep(for: .milliseconds(200))
        phase.value = .active
        try await waitUntil { self.hasZoomImage(window) }
        let recoveredCalls = await resolver.calls
        XCTAssertEqual(recoveredCalls, 3, "A later reload must recover after failure")
        try await waitUntil { self.shareEnabled(window) == true }
    }
    func testFullScreenReloadFailureExposesErrorAndRecovers() async throws {
        try await checkReloadFailure(NSError(domain: "ImageFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "INJECTED RELOAD FAILURE"]))
    }
    func testIdentityFailureDiscardsPreviousFullScreenImage() async throws {
        try await checkReloadFailure(IdentityError.missingPassphrase)
    }
    private func checkImageAccessibility(alt: String, expected: String) async throws {
        let url = try png()
        defer { try? FileManager.default.removeItem(at: url) }
        let resolver = ImageReloadResolver(file: url, reloadError: IdentityError.missingPassphrase)
        let profile = ConnectionProfile(name: "Image accessibility tests", host: "fixture.invalid", username: "fixture", identityID: UUID())
        let item = ImagePresentation(reference: "image.png", filename: "image.png",
                                    location: .init(profile: profile, path: "/fixture/report.md"), alt: alt)
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try host(RemoteImageViewer(item: item, resolver: resolver).environment(\.scenePhase, .active))
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        try await waitUntil { self.hasZoomImage(window) }
        let image = try XCTUnwrap(views(window).compactMap { $0 as? UIScrollView }
            .flatMap(\.subviews).compactMap { $0 as? UIImageView }.first { $0.image != nil })
        XCTAssertTrue(image.isAccessibilityElement)
        XCTAssertTrue(image.accessibilityTraits.contains(.image))
        XCTAssertEqual(image.accessibilityLabel, expected)
    }
    func testFullScreenImageExposesAltDescription() async throws {
        try await checkImageAccessibility(alt: "Purple project diagram", expected: "Purple project diagram")
    }
    func testFullScreenImageUsesFilenameWhenAltIsBlank() async throws {
        try await checkImageAccessibility(alt: " \n\t", expected: "image.png")
    }
    func testMemoryWarningEvictsBothDecodedImageSizes() async throws {
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try host(RemoteFilesRootView().environment(\.scenePhase, .active))
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        try await Task.sleep(for: .milliseconds(300))
        let url = try png()
        defer { try? FileManager.default.removeItem(at: url) }
        await RemoteImageDecoder.shared.clear()
        let inline = try await RemoteImageDecoder.shared.decode(url, maxPixel: 1600)
        let viewer = try await RemoteImageDecoder.shared.decode(url, maxPixel: 3072)
        let cached = try await RemoteImageDecoder.shared.decode(url, maxPixel: 1600)
        XCTAssertTrue(inline.image === cached.image, "Establish a cache hit before the warning")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await waitUntil {
            guard let decoded = try? await RemoteImageDecoder.shared.decode(url, maxPixel: 1600) else { return false }
            return inline.image !== decoded.image
        }
        let after = try await RemoteImageDecoder.shared.decode(url, maxPixel: 3072)
        XCTAssertFalse(viewer.image === after.image, "The actual root warning handler must evict viewer pixels too")
        // Existing views may retain their pixels; only the decoder LRU is evicted.
        XCTAssertGreaterThan(inline.cost, 0)
        XCTAssertGreaterThan(viewer.cost, 0)
        await RemoteImageDecoder.shared.clear()
    }
}
#endif
