import NIOCore
@testable import NIOSSH
import XCTest

final class SecurityBoundaryTests: XCTestCase {
    func testEncryptedPacketLengthRejectsIntegerOverflowAndInexactMACLengths() throws {
        XCTAssertThrowsError(
            try SSHPacketParser.validatedEncryptedPacketLength(
                packetLength: .max,
                macBytes: 1,
                maximumPacketSize: 1 << 17
            )
        ) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .invalidEncryptedPacketLength)
        }

        XCTAssertThrowsError(
            try SSHPacketParser.validatedEncryptedPacketLength(
                packetLength: 1,
                macBytes: -1,
                maximumPacketSize: 1 << 17
            )
        )
    }

    func testEncryptedPacketLengthChecksTheAuthenticatedTotalAgainstTheLimit() throws {
        XCTAssertEqual(
            try SSHPacketParser.validatedEncryptedPacketLength(
                packetLength: 1_000,
                macBytes: 16,
                maximumPacketSize: 1_017
            ),
            1_016
        )

        XCTAssertThrowsError(
            try SSHPacketParser.validatedEncryptedPacketLength(
                packetLength: 1_000,
                macBytes: 16,
                maximumPacketSize: 1_016
            )
        )
    }

    func testPeerMaximumPacketSizeRejectsOnlyZero() throws {
        XCTAssertThrowsError(try SSHChildChannel.validatePeerMaximumPacketSize(0)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }

        XCTAssertNoThrow(try SSHChildChannel.validatePeerMaximumPacketSize(1))
        XCTAssertNoThrow(try SSHChildChannel.validatePeerMaximumPacketSize(.max))
    }

    func testECDSAMPIntAcceptsRequiredLeadingZero() throws {
        var scalar = ByteBufferAllocator().buffer(capacity: 2)
        scalar.writeBytes([0x00, 0x80])

        XCTAssertEqual(Array(try scalar.validatedECDSAScalarMPInt(maximumBytes: 1)), [0x80])
    }

    func testECDSASignatureParserAcceptsRequiredLeadingZero() throws {
        var signatureComponents = ByteBufferAllocator().buffer(capacity: 16)
        signatureComponents.writeSSHString([0x00, 0x80])
        signatureComponents.writeSSHString([0x01])

        var signature = ByteBufferAllocator().buffer(capacity: 64)
        signature.writeSSHString("ecdsa-sha2-nistp256".utf8)
        signature.writeSSHString(&signatureComponents)

        XCTAssertNotNil(try signature.readSSHSignature())
    }

    func testECDSAMPIntRejectsNegativeNoncanonicalZeroAndOversizedScalars() throws {
        let invalidScalars: [([UInt8], Int)] = [
            ([], 32),
            ([0x00], 32),
            ([0x00, 0x01], 32),
            ([0x80], 32),
            ([0x01, 0x00], 1),
        ]

        for (bytes, maximumBytes) in invalidScalars {
            var scalar = ByteBufferAllocator().buffer(capacity: bytes.count)
            scalar.writeBytes(bytes)

            XCTAssertThrowsError(try scalar.validatedECDSAScalarMPInt(maximumBytes: maximumBytes), "Accepted \(bytes)") { error in
                XCTAssertEqual((error as? NIOSSHError)?.type, .invalidSSHMessage)
            }
        }
    }

    func testECDSASignatureParserRejectsOversizedScalarsForEveryCurveWithoutTrapping() throws {
        let curves = [
            ("ecdsa-sha2-nistp256", 32),
            ("ecdsa-sha2-nistp384", 48),
            ("ecdsa-sha2-nistp521", 66),
        ]

        for (algorithm, pointSize) in curves {
            var signatureComponents = ByteBufferAllocator().buffer(capacity: pointSize + 16)
            signatureComponents.writeSSHString([UInt8](repeating: 0x01, count: pointSize + 1))
            signatureComponents.writeSSHString([0x01])

            var signature = ByteBufferAllocator().buffer(capacity: pointSize + 64)
            signature.writeSSHString(algorithm.utf8)
            signature.writeSSHString(&signatureComponents)

            XCTAssertThrowsError(try signature.readSSHSignature(), "Accepted oversized \(algorithm) scalar") { error in
                XCTAssertEqual((error as? NIOSSHError)?.type, .invalidSSHMessage)
            }
        }
    }
}
