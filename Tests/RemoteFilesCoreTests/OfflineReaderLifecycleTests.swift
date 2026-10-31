#if os(iOS)
import XCTest
import SwiftUI
import WebKit
@testable import RemoteFilesCore
@testable import RemoteFilesUI

private actor OfflineReaderTransport: RemoteFileService {
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        .init(path: path, entries: ["README.md", "notes.md"].map {
            .init(name: $0, path: "/docs/" + $0, kind: .file)
        })
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: "docs", path: path, kind: .directory)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        throw RemoteFileError.unsupportedFile
    }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL,
                      limit: Int) async throws -> RemoteEntry {
        let target = path.hasSuffix("README.md") ? "notes.md" : "README.md"
        // Math selects the WebKit Markdown renderer so the test can inspect real
        // rendered scroll restoration without driving asynchronous JavaScript navigation.
        let text = "# \(RemotePath.name(of: path))\n\n[Next](\(target))\n\n$x$\n\n" +
            (0..<80).map { "Paragraph \($0) of the saved document.\n\n" }.joined()
        try Data(text.utf8).write(to: destination)
        return .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func disconnect() {}
    func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                              limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        try await downloadFile(profile: profile, path: path, allowedRoot: canonicalRoot, destination: destination, limit: limit)
    }
}

@MainActor @Observable private final class OfflineReaderFixtureState {
    var path: [OfflineDocumentRoute] = []
    var phase = ScenePhase.active
}

private struct OfflineReaderFixture: View {
    @Bindable var state: OfflineReaderFixtureState
    let store: OfflineFileStore
    var body: some View {
        NavigationStack(path: $state.path) {
            Text("Offline library")
                .navigationDestination(for: OfflineDocumentRoute.self) { route in
                    OfflineReaderView(pin: route.pin, store: store, initialFragment: route.fragment,
                                      openDocument: { state.path.append($0) })
                }
        }.environment(\.scenePhase, state.phase)
    }
}

@MainActor final class OfflineReaderLifecycleTests: XCTestCase {
    func testLinkedReadersReleaseCoveredLeasesAndReverifyOnBackAndForeground() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OfflineFileStore(directory: directory)
        let profile = ConnectionProfile(name: "Offline fixture", host: "fixture.invalid", username: "reader",
                                        identityID: UUID(), startingDirectory: "/docs")
        _ = try await store.pinFolder(profile: profile, path: "/docs", service: OfflineReaderTransport())
        let pins = await store.snapshot()
        let first = try XCTUnwrap(pins.first { $0.filename == "README.md" })
        let state = OfflineReaderFixtureState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: OfflineReaderFixture(state: state, store: store))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        state.path.append(.init(pin: first))
        var web = try await reader(in: window, named: "README.md")
        web.scrollView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let originalURL = try XCTUnwrap(leaseURLs(directory).first)
        for hop in 1...12 {
            let previousWeb = web
            let source = try XCTUnwrap(state.path.last?.pin)
            let target = try await store.resolveDocumentLink(from: source,
                reference: hop.isMultiple(of: 2) ? "README.md" : "notes.md")
            // Use the same route appended by openDocument, outside evaluateJavaScript:
            // a successful link removes that web view before its JS completion returns.
            state.path.append(.init(pin: target))
            try await waitUntil { previousWeb.window == nil }
            web = try await reader(in: window, named: hop.isMultiple(of: 2) ? "README.md" : "notes.md")
            try await waitUntil { self.leaseURLs(directory).count == 1 }
            XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path),
                           "Covered reader must release its lease at hop \(hop)")
            print("Offline link hop \(hop): \(self.leaseURLs(directory).count) live lease directories")
        }
        try await waitUntil { self.leaseURLs(directory).count == 1 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path), "The first covered reader must release its file")

        // Covered destinations must not reopen on scene changes. The visible reader alone
        // gets a new verified lease, while the navigation history remains intact.
        state.phase = .background
        try await waitUntil { self.leaseURLs(directory).isEmpty }
        try await waitUntil { web.window == nil }
        state.phase = .active
        web = try await reader(in: window, named: "README.md")
        try await waitUntil { self.leaseURLs(directory).count == 1 }
        XCTAssertEqual(state.path.count, 13)

        let previousWeb = web
        state.path.removeLast(12)
        try await waitUntil { previousWeb.window == nil }
        web = try await reader(in: window, named: "README.md")
        try await waitUntil { abs(web.scrollView.contentOffset.y - 500) < 5 }
        XCTAssertNotEqual(leaseURLs(directory).first, originalURL, "Back must acquire a new verified lease")

        // A new directory alone does not prove verification. Cover this route again,
        // corrupt its committed bytes without changing their length, then go Back.
        let target = try await store.resolveDocumentLink(from: first, reference: "notes.md")
        state.path.append(.init(pin: target))
        let coveredWeb = try await reader(in: window, named: "notes.md")
        try await waitUntil { self.leaseURLs(directory).count == 1 }
        let original = directory.appendingPathComponent(first.blobID.uuidString).appendingPathComponent("original")
        var damaged = try Data(contentsOf: original)
        damaged[0] ^= 1
        try damaged.write(to: original, options: .atomic)
        state.path.removeLast()
        try await waitUntil { coveredWeb.window == nil }
        // Observe the protected resources, not SwiftUI's private accessibility tree.
        // A cached preview/lease must not survive a failed verification on Back.
        try await waitUntil { self.leaseURLs(directory).isEmpty }
        XCTAssertTrue(webViews(in: window).isEmpty, "Back must not render unverified bytes")
        do {
            _ = try await store.lease(first.id)
            XCTFail("Same-length corruption must fail digest verification")
        } catch OfflineFileError.damaged { }

        state.path.removeAll()
        try await waitUntil { self.leaseURLs(directory).isEmpty }
    }

    private func leaseURLs(_ directory: URL) -> [URL] {
        let base = directory.appendingPathComponent(".leases")
        return (try? FileManager.default.contentsOfDirectory(at: base,
            includingPropertiesForKeys: [.isDirectoryKey]))?.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            } ?? []
    }
    private func webViews(in view: UIView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }
    private func reader(in window: UIWindow, named name: String) async throws -> WKWebView {
        var result: WKWebView?
        try await waitUntil {
            guard let web = self.webViews(in: window).last, web.scrollView.contentSize.height > web.bounds.height else { return false }
            let title = try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
            guard title == name else { return false }
            result = web
            return true
        }
        return try XCTUnwrap(result)
    }
    private func waitUntil(_ condition: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Offline reader lifecycle did not settle", file: file, line: line)
        throw OfflineFileError.timedOut
    }
}
#endif
