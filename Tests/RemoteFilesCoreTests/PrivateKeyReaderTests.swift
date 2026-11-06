#if os(iOS)
import XCTest
import SwiftUI
import UIKit
import RemoteFilesCore
@testable import RemoteFilesUI

private actor FixedTextService: RemoteFileService {
    let bytes: Data
    init(_ text: String) { bytes = Data(text.utf8) }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { bytes }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}

/// The real reader, on what it reads from a connection, since its state and cache are what a key must stay out of.
@MainActor final class PrivateKeyReaderTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "fixture", identityID: UUID(), startingDirectory: "/")

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func sourceText(_ window: UIWindow) -> String {
        descendants(window).compactMap { $0 as? SourceTextView }.map { $0.text ?? "" }.joined()
    }
    /// Publishing a read records the recent item after it has updated the preview and the cache.
    private func open(_ name: String, text: String, check: (AppModel, UIWindow) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: FixedTextService(text))
        model.metadata.connections = [profile]
        let entry = RemoteEntry(name: name, path: "/" + name, kind: .file)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ReaderView(model: model, profile: profile, entry: entry) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let deadline = ContinuousClock.now + .seconds(120)
        while model.metadata.recents.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(model.metadata.recents.isEmpty, "\(name) was never published")
        try await check(model, window)
    }

    func testAKeyOnlyFileReachesNeitherTheCacheNorASourceView() async throws {
        let key = SyntheticKey.pem()
        for name in ["id_rsa", ".server.key", "server.pem.txt"] {
            try await open(name, text: key) { model, window in
                XCTAssertNil(model.cachedDocument(profile.id, path: "/" + name), name)
                await Task.yield()
                XCTAssertEqual(sourceText(window), "", name)
            }
        }
    }

    func testADocumentWithAKeyShowsOnlyHiddenTextAndIsNotCached() async throws {
        let key = SyntheticKey.pem()
        try await open("notes.txt", text: "first\n\n" + key + "\nneedle after the key\n") { model, window in
            XCTAssertNil(model.cachedDocument(profile.id, path: "/notes.txt"))
            let deadline = ContinuousClock.now + .seconds(120)
            while !sourceText(window).contains("needle after the key"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            let shown = sourceText(window)
            XCTAssertTrue(shown.contains("needle after the key"), "The document should open")
            for fragment in SyntheticKey.fragments(of: key) { XCTAssertFalse(shown.contains(fragment)) }
        }
    }

    func testADocumentWithoutAKeyIsStillCached() async throws {
        let text = "plain report\n"
        try await open("report.txt", text: text) { model, _ in
            XCTAssertEqual(model.cachedDocument(profile.id, path: "/report.txt"), Data(text.utf8))
        }
    }
}
#endif
