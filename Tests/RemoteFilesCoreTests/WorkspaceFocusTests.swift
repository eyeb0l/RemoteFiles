#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import RemoteFilesCore
@testable import RemoteFilesUI

/// Tab moves keyboard focus between focus groups, and only reaches a group with a row that can take
/// focus. On iPad it once stopped at the folder's search field: the library's rows couldn't take
/// focus, and the folder's rows were in the search field's group.
@MainActor final class WorkspaceFocusTests: XCTestCase {
    private func host<Content: View>(_ content: Content) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        return (window, previous)
    }
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    /// Hosted runners are slow; the bound only ends a failing run.
    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testLibraryRowsInTheWorkspaceCanTakeKeyboardFocus() async throws {
        let id = UUID()
        let library = List {
            Section("Connections") {
                ForEach(["Studio", "Archive", "Build"], id: \.self) { name in
                    WorkspaceLink(route: .folder(id, "/" + name)) { Text(name) }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.workspaceNavigation, { _ in })
        let (window, previous) = try host(library)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await wait("the library's rows") { views(UICollectionView.self, in: window).first.map { $0.visibleCells.count == 3 } ?? false }
        let cells = try XCTUnwrap(views(UICollectionView.self, in: window).first).visibleCells
        XCTAssertTrue(cells.allSatisfy(\.canBecomeFocused), "Each library row can take keyboard focus")
    }

    func testFolderRowsHaveAFocusGroupOfTheirOwnBesideTheSearchField() async throws {
        let model = try AppModel(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 fileService: SmallFolderService())
        let profile = ConnectionProfile(name: "Focus", host: "fixture.invalid", username: "focus", identityID: UUID(), startingDirectory: "/focus")
        let (window, previous) = try host(NavigationStack { FolderView(model: model, profile: profile, requestedPath: "/focus") })
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var list: UICollectionView?
        try await wait("the folder's rows and their focus group") {
            list = views(UICollectionView.self, in: window).first { !$0.visibleCells.isEmpty }
            return list?.focusGroupIdentifier == "dev.iris.RemoteFiles.folder-rows"
        }
        let rows = try XCTUnwrap(list)
        let field = try XCTUnwrap(views(UISearchTextField.self, in: window).first, "The folder has a search field")
        XCTAssertNotEqual(field.focusGroupIdentifier, rows.focusGroupIdentifier, "The rows are not the search field's results group")
        XCTAssertTrue(rows.visibleCells.allSatisfy(\.canBecomeFocused), "Each folder row can take keyboard focus")
    }
}

private actor SmallFolderService: RemoteFileService {
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        .init(path: path, entries: (1...20).map { RemoteEntry(name: "Note \($0).md", path: path + "/Note \($0).md", kind: .file, size: 1) })
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unavailable("Not used")
    }
    func disconnect() async {}
}
#endif
