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
    let failingCall: Int
    init(file: URL, reloadError: Error, failingCall: Int = 2) { self.file = file; self.reloadError = reloadError; self.failingCall = failingCall }
    func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        calls += 1
        if calls == failingCall { throw reloadError }
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
private struct RootPhaseFixture: View {
    let phase: ImageViewerPhase
    var body: some View { RemoteFilesRootView().environment(\.scenePhase, phase.value) }
}

@MainActor final class ImageLifecycleTests: XCTestCase {
    private let zoomDelegate = ZoomableRemoteImage.Coordinator()
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
    private func hasAccessibilityIdentifier(_ identifier: String, in window: UIWindow) -> Bool {
        views(window).contains { $0.accessibilityIdentifier == identifier }
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
    private func zoomView(image: CGSize, bounds: CGSize) -> ImageZoomScrollView {
        let scroll = ImageZoomScrollView(frame: CGRect(origin: .zero, size: bounds))
        scroll.delegate = zoomDelegate
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        let picture = UIGraphicsImageRenderer(size: image, format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }()).image { _ in }
        scroll.show(picture)
        scroll.addSubview(scroll.imageView)
        scroll.layoutIfNeeded()
        return scroll
    }
    func testDoubleTapZoomFillsTheScreenThenReturnsToTheWholePicture() async throws {
        let scroll = zoomView(image: CGSize(width: 1400, height: 600), bounds: CGSize(width: 400, height: 800))
        scroll.toggleZoom(at: CGPoint(x: 200, y: 85))
        try await waitUntil { abs(scroll.zoomScale - 800 / (400 * 600.0 / 1400)) < 0.05 }
        scroll.toggleZoom(at: CGPoint(x: 200, y: 85))
        try await waitUntil { abs(scroll.zoomScale - 1) < 0.01 }
        XCTAssertEqual(scroll.contentInset.top, 314.3, accuracy: 0.5, "Back to fitted, the picture is centred again")
    }
    func testDoubleTapOnAPictureThatNearlyFillsTheScreenStillZooms() async throws {
        let scroll = zoomView(image: CGSize(width: 400, height: 800), bounds: CGSize(width: 400, height: 800))
        scroll.toggleZoom(at: CGPoint(x: 200, y: 400))
        try await waitUntil { abs(scroll.zoomScale - 2.5) < 0.05 }
    }
    func testFittedPictureIsCentredAndCannotPanIntoEmptySpace() {
        let scroll = zoomView(image: CGSize(width: 1400, height: 600), bounds: CGSize(width: 400, height: 800))
        XCTAssertEqual(scroll.imageView.frame.width, 400, accuracy: 0.5)
        XCTAssertEqual(scroll.imageView.frame.height, 171.4, accuracy: 0.5)
        XCTAssertEqual(scroll.contentSize.width, 400, accuracy: 0.5)
        XCTAssertEqual(scroll.contentSize.height, 171.4, accuracy: 0.5)
        XCTAssertEqual(scroll.contentInset.top, 314.3, accuracy: 0.5)
        XCTAssertEqual(scroll.contentOffset.y, -314.3, accuracy: 0.5)
    }
    func testZoomedPicturePansOnlyAsFarAsItsEdges() {
        let scroll = zoomView(image: CGSize(width: 1400, height: 600), bounds: CGSize(width: 400, height: 800))
        scroll.setZoomScale(3, animated: false)
        // 1200 x 514 in a 400 x 800 window: free to pan across, and still centred down.
        XCTAssertEqual(scroll.contentSize.width, 1200, accuracy: 0.5)
        XCTAssertEqual(scroll.contentInset.left, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentInset.right, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentInset.top, 142.9, accuracy: 0.5)
        scroll.setZoomScale(6, animated: false)
        // 2400 x 1029: larger than the window both ways, so no empty space remains to pan into.
        XCTAssertEqual(scroll.contentInset, .zero)
    }
    func testSharperCopyOfTheSamePictureKeepsZoomAndADifferentPictureRefits() {
        let scroll = zoomView(image: CGSize(width: 1400, height: 600), bounds: CGSize(width: 400, height: 800))
        scroll.setZoomScale(3, animated: false)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        scroll.show(UIGraphicsImageRenderer(size: CGSize(width: 2800, height: 1200), format: format).image { _ in })
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, 3, accuracy: 0.01, "The full-size decode arrives while someone may be zooming")
        scroll.show(UIGraphicsImageRenderer(size: CGSize(width: 600, height: 1400), format: format).image { _ in })
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, 1, accuracy: 0.01)
        XCTAssertEqual(scroll.imageView.frame.height, 800, accuracy: 0.5)
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
    func testFailedReloadDiscardsTheReadersPreviewAndCannotShareIt() async throws {
        await RemoteImageDecoder.shared.clear()
        let url = try png()
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try await RemoteImageDecoder.shared.decode(url, maxPixel: 100)
        let profile = ConnectionProfile(name: "Image preview tests", host: "fixture.invalid", username: "fixture", identityID: UUID())
        let item = ImagePresentation(reference: "image.png", filename: "image.png",
                                     location: .init(profile: profile, path: "/fixture/report.md"), preview: preview)
        let resolver = ImageReloadResolver(file: url, reloadError: IdentityError.missingPassphrase, failingCall: 1)
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try host(RemoteImageViewer(item: item, resolver: resolver).environment(\.scenePhase, .active))
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        try await waitUntil { await resolver.calls >= 1 && !self.hasZoomImage(window) }
        try await waitUntil { self.shareEnabled(window) == false }
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

    func testRootPrivacyCoverTracksInactiveAndBackgroundPhases() async throws {
        let previousWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        let phase = ImageViewerPhase()
        let window = try host(RootPhaseFixture(phase: phase))
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }

        XCTAssertFalse(hasAccessibilityIdentifier("privacy-cover", in: window))
        phase.value = .inactive
        try await waitUntil { self.hasAccessibilityIdentifier("privacy-cover", in: window) }
        phase.value = .background
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(hasAccessibilityIdentifier("privacy-cover", in: window))
        phase.value = .active
        try await waitUntil { !self.hasAccessibilityIdentifier("privacy-cover", in: window) }
    }

    func testDeferredRootPrivacyCoverDoesNotReturnAfterBecomingActive() async throws {
        let coordinator = RootWindowPrivacyInstaller.Coordinator()
        let anchor = UIView(frame: .zero)
        coordinator.update(anchor: anchor, isVisible: true)
        coordinator.update(anchor: anchor, isVisible: false)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.addSubview(anchor)
        let deferredUpdateHandled = expectation(description: "deferred privacy-cover update handled")
        DispatchQueue.main.async { deferredUpdateHandled.fulfill() }
        await fulfillment(of: [deferredUpdateHandled], timeout: 1)

        XCTAssertFalse(hasAccessibilityIdentifier("privacy-cover", in: window))
    }
}
#endif
