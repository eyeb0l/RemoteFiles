import XCTest
@testable import RemoteFilesCore

final class RemotePathBoundaryTests: XCTestCase {
    func testCanonicalRootConfinementUsesExactRemoteFilenameBytes() {
        let composed = "/workspace/é"
        let decomposed = "/workspace/e\u{301}"
        XCTAssertTrue(RemoteResourcePath.contains(composed, in: composed))
        XCTAssertTrue(RemoteResourcePath.contains(composed + "/report.md", in: composed))
        XCTAssertFalse(RemoteResourcePath.contains(decomposed + "/report.md", in: composed))
        XCTAssertFalse(RemoteResourcePath.contains(composed + "vil/report.md", in: composed))
        XCTAssertTrue(RemoteResourcePath.contains("/workspace/report.md", in: "/"))
    }

    /// A slash beside a combining or prepended mark is one Character with it, which a split by Character
    /// keeps whole. The server only ever sees bytes.
    func testNamesAreSeparatedByTheSlashByteWhateverSurroundsIt() {
        let joiner = "\u{200D}join.txt", accent = "\u{301}x", prepended = "a\u{600}"
        XCTAssertEqual(RemotePath.name(of: "/r/" + joiner), joiner)
        XCTAssertEqual(RemotePath.parent(of: "/r/" + joiner), "/r")
        XCTAssertEqual(RemotePath.name(of: "/" + accent), accent)
        XCTAssertEqual(RemotePath.parent(of: "/" + accent), "/")
        XCTAssertEqual(RemotePath.parent(of: "/" + prepended + "/b"), "/" + prepended)
        XCTAssertEqual(RemotePath.name(of: "/" + prepended + "/b"), "b")
        XCTAssertEqual(RemotePath.components(of: "/" + prepended + "/../b").map(String.init), [prepended, "..", "b"])
        XCTAssertEqual(RemotePath.components(of: "/r/" + accent + "/c", under: "/r").map(String.init), [accent, "c"])
        XCTAssertEqual(RemotePath.components(of: "/" + accent + "/c", under: "/").map(String.init), [accent, "c"])
        XCTAssertEqual(RemotePath.appending("c", to: "/" + accent), "/" + accent + "/c")
        // Unchanged for ordinary paths.
        XCTAssertEqual(RemotePath.name(of: "/"), "/")
        XCTAssertEqual(RemotePath.name(of: ""), "/")
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/a"), "/")
        XCTAssertEqual(RemotePath.name(of: "/a/b/"), "b")
        XCTAssertEqual(RemotePath.parent(of: "/a//b/"), "/a")
        XCTAssertEqual(RemotePath.components(of: "/a//b/", omittingEmpty: false).map(String.init), ["", "a", "", "b", ""])
    }

    func testHiddenMeansAFirstByteOfFullStop() {
        XCTAssertTrue(RemotePath.isHidden(".profile"))
        XCTAssertTrue(RemotePath.isHidden(".\u{301}x"), "Hidden to the server and to ls, though its first Character isn't a full stop")
        XCTAssertFalse(RemotePath.isHidden("profile."))
        XCTAssertFalse(RemotePath.isHidden(""))
    }

    func testPathChecksSeeEverySlashAndParentName() {
        let accent = "\u{301}", prepended = "\u{600}"
        XCTAssertTrue(OfflineFolderPin.validPath("/" + accent + "x"))
        XCTAssertTrue(OfflineFolderPin.validPath("/r/\u{200D}join.txt"))
        XCTAssertTrue(OfflineFolderPin.validPath("/"))
        for path in ["/a" + prepended + "/../b", "/a/.." + "/" + accent + "b", "/a" + prepended + "//b", "/a" + prepended + "/",
                     "/a/./b", "relative", "//a", "/a/..", ""] {
            XCTAssertFalse(OfflineFolderPin.validPath(path), path.debugDescription)
        }
        for name in ["a" + prepended + "/b", "../" + accent + "b", "a\\" + accent, ".", "..", "", "a/b"] {
            XCTAssertFalse(OfflineFileStore.validFilename(name), name.debugDescription)
        }
        XCTAssertTrue(OfflineFileStore.validFilename(accent + "x"))
        XCTAssertTrue(OfflineFileStore.validFilename("..." + accent))
    }

    /// `invoice` + U+202E + `fdp.html` is drawn as `invoicelmth.pdf`: the name is HTML and reads as a PDF.
    func testDirectionControlsAreShownInNamesAndRefusedInSavedOnes() {
        let spoofed = "invoice\u{202E}fdp.html"
        XCTAssertTrue(RemotePath.hasDirectionControl(spoofed))
        XCTAssertEqual(RemotePath.displayName(spoofed), "invoice\u{FFFD}fdp.html", "The letters are shown in stored order, with the control visible")
        XCTAssertTrue(RemotePath.displayName(spoofed).hasSuffix(".html"))
        for control in ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
                        "\u{200E}", "\u{200F}", "\u{061C}"] {
            let name = "a" + control + "b.txt"
            XCTAssertEqual(RemotePath.displayName(name), "a\u{FFFD}b.txt", name.debugDescription)
            XCTAssertFalse(OfflineFileStore.validFilename(name), name.debugDescription)
        }
        // Joiners and the marks real names in other scripts depend on are left alone, as are right-to-left letters.
        for name in ["family 👨‍👩‍👧.png", "می‌خواهم.txt", "שלום.txt", "مرحبا.pdf", "e\u{301}.md", "plain.txt"] {
            XCTAssertFalse(RemotePath.hasDirectionControl(name), name)
            XCTAssertEqual(Array(RemotePath.displayName(name).utf8), Array(name.utf8), name)
            XCTAssertTrue(OfflineFileStore.validFilename(name), name)
        }
    }

    /// `String` equality folds canonically equivalent names together; a server's file system does not.
    func testPathKeysTellApartNamesThatDifferOnlyInNormalisation() {
        let composed = "/r/caf\u{E9}.txt", decomposed = "/r/cafe\u{301}.txt"
        XCTAssertEqual(composed, decomposed, "Swift treats these as the same string")
        XCTAssertNotEqual(RemotePathKey(composed), RemotePathKey(decomposed))
        XCTAssertEqual(RemotePathKey(composed), RemotePathKey("/r/caf\u{E9}.txt"))
        var cache: [RemotePathKey: Int] = [:]
        cache[RemotePathKey(composed)] = 1; cache[RemotePathKey(decomposed)] = 2
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache[RemotePathKey(composed)], 1); XCTAssertEqual(cache[RemotePathKey(decomposed)], 2)
    }

    /// On the server a backslash is a byte like any other, so a path holding one is still a path: saved
    /// indexes and offline folders keep it, and links resolve beside it. A link's own reference, written by
    /// whoever wrote the document, still may not hold one, and neither may a name made into a local file.
    func testBackslashIsAnOrdinaryByteInRemotePathsButNotInReferencesOrLocalNames() throws {
        let accent = "\u{301}"
        for path in ["/r/C:\\notes.txt", "/a\\" + accent, "/share\\docs/a.md", "/\\", "/r/..\\x", "/r/\\..\\"] {
            XCTAssertTrue(OfflineFolderPin.validPath(path), path.debugDescription)
            XCTAssertTrue(RemotePath.wasAcceptedAsPath(path), "Saved by this version, so it must load: " + path.debugDescription)
        }
        XCTAssertEqual(RemotePath.name(of: "/r/C:\\notes.txt"), "C:\\notes.txt")
        XCTAssertEqual(RemotePath.parent(of: "/r/..\\x"), "/r")
        // Still refused: what a backslash doesn't change.
        for path in ["/r\\/../x", "/r/\\/./x", "r\\x", "/r\\//x", "/r\\/"] {
            XCTAssertFalse(OfflineFolderPin.validPath(path), path.debugDescription)
            XCTAssertFalse(RemotePath.wasAcceptedAsPath(path), path.debugDescription)
        }
        for name in ["C:\\notes.txt", "\\", "..\\x"] {
            XCTAssertFalse(OfflineFileStore.validFilename(name), name.debugDescription)
            XCTAssertFalse(RemotePath.wasAcceptedAsFilename(name), name.debugDescription)
        }

        for (root, document) in [("/Projects", "/Projects/C:\\docs/review.md"), ("/srv\\share", "/srv\\share/review.md")] {
            let folder = RemotePath.parent(of: document)
            XCTAssertEqual(try RemoteDocumentLinkPath.resolve("notes.md", relativeTo: document, connectionRoot: root), folder + "/notes.md")
            XCTAssertEqual(try RemoteDocumentLinkPath.resolve("sub/../notes.md", relativeTo: document, connectionRoot: root), folder + "/notes.md")
            XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve("../../secret.md", relativeTo: document, connectionRoot: root)) {
                XCTAssertEqual($0 as? RemoteDocumentLinkError, .outsideConnection)
            }
            for reference in ["..\\secret.md", "a%5Cb.md", "..%5C..%5Csecret.md"] {
                XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve(reference, relativeTo: document, connectionRoot: root), reference) {
                    XCTAssertEqual($0 as? RemoteDocumentLinkError, .invalidReference)
                }
            }
            let profile = ConnectionProfile(name: "Paths", host: "example.invalid", username: "reader", identityID: UUID())
            let location = RemoteDocumentLocation(profile: profile, path: document)
            XCTAssertEqual(try RemoteResourcePath.resolve("one.png", relativeTo: location), folder + "/one.png")
            for reference in ["..\\one.png", "a%5Cone.png", "\\one.png"] {
                XCTAssertThrowsError(try RemoteResourcePath.resolve(reference, relativeTo: location), reference)
            }
        }
    }

    func testLinksAndImagesResolveParentNamesHiddenBesideMarks() throws {
        let root = "/Projects/RemoteFiles", document = root + "/reports/review.md"
        let accent = "%CC%81", prepended = "%D8%80"
        // In bytes these are "..", then a name starting with a mark: one level up each time.
        XCTAssertEqual(try RemoteDocumentLinkPath.resolve("../" + accent + "notes.md", relativeTo: document, connectionRoot: root),
                       root + "/\u{301}notes.md")
        XCTAssertEqual(try RemoteDocumentLinkPath.resolve("a" + prepended + "/../notes.md", relativeTo: document, connectionRoot: root),
                       root + "/reports/notes.md")
        for reference in ["../../" + accent + "secret.md", "a" + prepended + "/../../../secret.md", "../" + accent + "x/../../secret.md"] {
            XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve(reference, relativeTo: document, connectionRoot: root), reference) {
                XCTAssertEqual($0 as? RemoteDocumentLinkError, .outsideConnection)
            }
        }
        XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve("notes" + prepended + "/", relativeTo: document, connectionRoot: root)) {
            XCTAssertEqual($0 as? RemoteDocumentLinkError, .invalidReference)
        }
        let profile = ConnectionProfile(name: "Paths", host: "example.invalid", username: "reader", identityID: UUID())
        let location = RemoteDocumentLocation(profile: profile, path: document)
        XCTAssertEqual(try RemoteResourcePath.resolve("a" + prepended + "/../one.png", relativeTo: location), root + "/reports/one.png")
        XCTAssertEqual(try RemoteResourcePath.resolve(root + "/reports/" + accent + "one.png", relativeTo: location),
                       root + "/reports/\u{301}one.png", "An absolute reference keeps the whole of its name")
        for reference in ["../" + accent + "one.png", "a" + prepended + "/../../one.png"] {
            XCTAssertThrowsError(try RemoteResourcePath.resolve(reference, relativeTo: location), reference)
        }
    }
}
