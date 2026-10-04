import Foundation
import XCTest
@testable import RemoteFilesCore

final class DocumentNavigationTests: XCTestCase {
    private let root = "/Projects/RemoteFiles"
    private var document: String { root + "/reports/review.md" }

    func testParentAndNestedLinksStayInsideConnectionRoot() throws {
        for (reference, target) in [
            ("notes.md", "/reports/notes.md"),
            ("./nested/../notes.md", "/reports/notes.md"),
            ("../README.md", "/README.md"),
            ("../reports/../src/main.swift", "/src/main.swift"),
            ("../images/diagram.png", "/images/diagram.png"),
            ("../report.pdf", "/report.pdf")
        ] {
            XCTAssertEqual(try RemoteDocumentLinkPath.resolve(reference, relativeTo: document, connectionRoot: root), root + target)
        }
        XCTAssertEqual(try RemoteDocumentLinkPath.resolve("../home.md", relativeTo: "/reports/review.md", connectionRoot: "/"), "/home.md")
    }

    func testReferencesDecodeExactlyOnceAndPreserveUnicodeFilenames() throws {
        XCTAssertEqual(try RemoteDocumentLinkPath.resolve("../R%C3%A9sum%C3%A9%20%E6%9D%B1%E4%BA%AC.md", relativeTo: document, connectionRoot: root), root + "/Résumé 東京.md")
        XCTAssertEqual(try RemoteDocumentLinkPath.resolve("%252e%252e.md", relativeTo: document, connectionRoot: root), root + "/reports/%2e%2e.md")
        XCTAssertEqual(try RemoteDocumentLinkPath.resolve("section%23one%3Ftwo.md", relativeTo: document, connectionRoot: root), root + "/reports/section#one?two.md")
    }

    func testEscapesAndUnconfinedSourceFailClosed() {
        for reference in ["../../secret.md", "../..", "%2e%2e/%2e%2e/secret.md", "nested/../../../secret.md"] {
            XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve(reference, relativeTo: document, connectionRoot: root)) {
                XCTAssertEqual($0 as? RemoteDocumentLinkError, .outsideConnection)
            }
        }
        for (source, boundary) in [("reports/review.md", root), (document, "."), ("/Projects/RemoteFiles-other/review.md", root), ("/Projects/review.md", root), (document, root + "/.."), (root, root)] {
            XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve("notes.md", relativeTo: source, connectionRoot: boundary)) {
                XCTAssertEqual($0 as? RemoteDocumentLinkError, .outsideConnection)
            }
        }
    }

    func testAbsoluteSchemesAndMalformedReferencesFailClosed() {
        for reference in ["/Projects/RemoteFiles/report.md", "%2FProjects/report.md", "//server/report.md", "https://example.com/report.md", "file:///secret.md", "data:text/plain,hello", "ssh://mac/report.md", "javascript:alert(1)", "..\\secret.md", "notes%5Csecret.md", "notes%00.md", "notes%0A.md", "", "folder/"] {
            XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve(reference, relativeTo: document, connectionRoot: root)) {
                XCTAssertEqual($0 as? RemoteDocumentLinkError, .invalidReference, reference)
            }
        }
    }

    func testFragmentsQueriesAndUnsupportedTypesHaveActionableErrors() {
        for reference in ["#details", "notes.md#details", "notes.md#"] {
            XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve(reference, relativeTo: document, connectionRoot: root)) {
                XCTAssertEqual($0 as? RemoteDocumentLinkError, .anchorsUnsupported)
                XCTAssertTrue($0.localizedDescription.contains("#"))
            }
        }
        XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve("notes.md?download=1", relativeTo: document, connectionRoot: root)) {
            XCTAssertEqual($0 as? RemoteDocumentLinkError, .queryUnsupported)
        }
        XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve("Archive.zip", relativeTo: document, connectionRoot: root)) {
            XCTAssertEqual($0 as? RemoteDocumentLinkError, .unsupportedFile)
        }
    }

    func testRemotePreparationRetainsRelativeActionsWithoutEnablingUnsafeSchemesOrImages() throws {
        let input = "[Sibling](notes.md) [Parent](../README.md) [Heading](notes.md#details) [Query](notes.md?download=1) [External](https://example.com) [File](file:///etc/passwd) [Root](/etc/passwd) ![Diagram](../image.png)"
        let prepared = try DocumentPolicy.prepareMarkdown(input, preserveDocumentLinks: true)
        XCTAssertFalse(prepared.runs.contains { $0.imageURL != nil })
        let links = prepared.runs.compactMap(\.link).map(\.absoluteString)
        XCTAssertEqual(links, ["notes.md", "../README.md", "notes.md#details", "notes.md?download=1", "https://example.com"])
        let remoteParts = try DocumentPolicy.remoteMarkdownParts(input)
        let retained = remoteParts.flatMap { part -> [String] in
            if case .text(let text) = part.content { return text.runs.compactMap(\.link).map(\.absoluteString) }
            return []
        }
        XCTAssertEqual(retained, links)
        XCTAssertTrue(DocumentPolicy.isRelativeDocumentLink(URL(string: "#details")!))
        XCTAssertFalse(DocumentPolicy.isRelativeDocumentLink(URL(string: "notes.md", relativeTo: URL(string: "https://example.com")!)!))
    }

    func testDocumentParentsDoNotWidenAutomaticImageBoundary() {
        let profile = ConnectionProfile(name: "Fixture", host: "fixture.invalid", username: "fixture", identityID: UUID(), startingDirectory: root)
        XCTAssertThrowsError(try RemoteResourcePath.resolve("../image.png", relativeTo: .init(profile: profile, path: document)))
    }

    func testDemoNavigationFindsNestedAndParentFilesAndReportsMissing() async throws {
        let service = DemoRemoteFileService(delayNanoseconds: 0)
        let profile = ConnectionProfile(name: "Demo", host: "demo.invalid", username: "demo", identityID: UUID(), startingDirectory: "/Projects")
        let nested = try await service.resolveDocumentLink(profile: profile, documentPath: "/Projects/Navigation guide.md", reference: "Reports/Linked%20notes.md")
        XCTAssertEqual(nested.path, "/Projects/Reports/Linked notes.md")
        XCTAssertEqual(nested.navigationRoot, "/Projects")
        let parent = try await service.resolveDocumentLink(profile: profile, documentPath: nested.path, reference: "../Navigation%20guide.md")
        XCTAssertEqual(parent.path, "/Projects/Navigation guide.md")
        do {
            _ = try await service.resolveDocumentLink(profile: profile, documentPath: parent.path, reference: "Reports/Missing.md")
            XCTFail("Missing links must not invent a document")
        } catch { XCTAssertTrue(error.localizedDescription.contains("could not be found")) }
    }

    func testDemoConfinedReadRejectsPathOutsideNavigationRoot() async throws {
        let service = DemoRemoteFileService(delayNanoseconds: 0)
        let profile = ConnectionProfile(name: "Demo", host: "demo.invalid", username: "demo", identityID: UUID(), startingDirectory: "/Projects")
        do {
            _ = try await service.readDocumentFile(profile: profile, path: "/Other/secret.md", allowedRoot: "/Projects", limit: 10_000)
            XCTFail("A linked reader must not read outside its navigation root")
        } catch { XCTAssertEqual(error as? RemoteDocumentLinkError, .outsideConnection) }
        let bytes = try await service.readDocumentFile(profile: profile, path: "/Projects/Reports/Linked notes.md", allowedRoot: "/Projects", limit: 10_000)
        XCTAssertEqual(bytes, Data(DemoRemoteFileService.linkedNotes.utf8))
    }

    func testCancellingDemoNavigationDoesNotReturnAnEntry() async throws {
        let service = DemoRemoteFileService(delayNanoseconds: 5_000_000_000)
        let profile = ConnectionProfile(name: "Demo", host: "demo.invalid", username: "demo", identityID: UUID(), startingDirectory: "/Projects")
        let task = Task { try await service.resolveDocumentLink(profile: profile, documentPath: "/Projects/Navigation guide.md", reference: "Reports/Linked%20notes.md") }
        // Let the request enter its injected multi-second transfer delay before cancelling.
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled navigation must not return") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
