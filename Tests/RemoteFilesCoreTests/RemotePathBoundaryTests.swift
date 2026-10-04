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
}
