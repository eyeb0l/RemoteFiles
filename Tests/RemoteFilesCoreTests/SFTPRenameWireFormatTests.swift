import XCTest
import NIOCore
@testable import Citadel

/// The client asks for SFTP version 3, whose RENAME is two paths and nothing else. OpenSSH ignores a trailing
/// word; AsyncSSH and other servers that check each request's length answer SSH_FX_BAD_MESSAGE, which stopped
/// an uploaded file being named wherever a plain rename was used.
final class SFTPRenameWireFormatTests: XCTestCase {
    func testRenameIsTheTwoPathsAndNothingAfterThem() throws {
        var out = ByteBufferAllocator().buffer(capacity: 64)
        try SFTPMessageSerializer().encode(data: .rename(.init(requestId: 7, oldPath: "/old", newPath: "/newer", flags: 0)), out: &out)
        var expected = ByteBufferAllocator().buffer(capacity: 64)
        let length: UInt32 = 23 // type (1), request id (4), and the two length-prefixed paths (8 and 10)
        expected.writeInteger(length)
        expected.writeInteger(UInt8(18))                     // SSH_FXP_RENAME
        expected.writeInteger(UInt32(7))
        expected.writeInteger(UInt32(4)); expected.writeString("/old")
        expected.writeInteger(UInt32(6)); expected.writeString("/newer")
        XCTAssertEqual(out, expected)
    }

    /// Flags can't be sent in version 3, so asking for any fails before a request goes out.
    func testRenameRefusesFlagsItCannotSend() throws {
        XCTAssertNoThrow(try SFTPClient.requireNoRenameFlags(0))
        XCTAssertThrowsError(try SFTPClient.requireNoRenameFlags(1)) { error in
            guard case SFTPError.unsupportedVersion(.v3) = error else { return XCTFail("\(error)") }
        }
    }
}
