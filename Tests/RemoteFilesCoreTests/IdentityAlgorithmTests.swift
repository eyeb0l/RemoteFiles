import XCTest
import Crypto
import Foundation
import NIOSSH
@testable import RemoteFilesCore

final class IdentityAlgorithmTests: XCTestCase {
    func testECDSAImportsEachCurveWithCanonicalPublicKey() throws {
        for fixture in ECDSAIdentityFixture.all() {
            let imported = try OpenSSHIdentityParser.parse(fixture.text(), passphrase: nil)
            XCTAssertEqual(String(openSSHPublicKey: imported.key.nioPrivateKey.publicKey), fixture.publicKey)
            XCTAssertFalse(imported.encrypted)
            XCTAssertEqual(try IdentityPrivateKey(algorithm: fixture.algorithm, bytes: imported.key.rawRepresentation).nioPrivateKey.publicKey,
                           imported.key.nioPrivateKey.publicKey)
        }
    }

    func testECDSARejectsMismatchedCurvesPublicPointsScalarsAndPadding() throws {
        for fixture in ECDSAIdentityFixture.all() {
            var wrongPoint = fixture.point; wrongPoint[wrongPoint.count - 1] ^= 1
            var negativeScalar = fixture.scalar; negativeScalar[0] |= 0x80
            let values = [fixture.text(curve: "wrong-curve"), fixture.text(point: wrongPoint),
                          fixture.text(scalar: Data([0])), fixture.text(scalar: negativeScalar),
                          fixture.text(scalar: Data(repeating: 1, count: 100)),
                          fixture.text(extraPublicBytes: Data([0])), fixture.text(badPadding: true)]
            for text in values {
                XCTAssertThrowsError(try OpenSSHIdentityParser.parse(text, passphrase: nil)) { error in
                    XCTAssertEqual(error as? IdentityError, .malformedKey)
                }
            }
            XCTAssertThrowsError(try OpenSSHIdentityParser.parse(fixture.publicKey, passphrase: nil)) {
                XCTAssertEqual($0 as? IdentityError, .publicKeyOnly)
            }
        }
    }

    func testECDSAValidatesEveryPaddingByteIncludingFullBlock() throws {
        let fixture = ECDSAIdentityFixture.all()[0]
        // Vary comment length to cover every padding size, including a complete block.
        for count in 0..<16 {
            XCTAssertNoThrow(try OpenSSHIdentityParser.parse(fixture.text(comment: String(repeating: "x", count: count)), passphrase: nil))
            XCTAssertThrowsError(try OpenSSHIdentityParser.parse(fixture.text(comment: String(repeating: "x", count: count), badPadding: true), passphrase: nil))
        }
    }

    func testUnsupportedPEMAndSecurityKeysStillFailClearly() throws {
        let sample = ECDSAIdentityFixture.all()[0]
        let securityKey = ECDSAIdentityFixture(algorithm: "sk-ecdsa-sha2-nistp256@openssh.com", curve: sample.curve, point: sample.point, scalar: sample.scalar)
        XCTAssertThrowsError(try OpenSSHIdentityParser.parse(securityKey.text(), passphrase: nil)) {
            guard case IdentityError.unsupportedFormat = $0 else { return XCTFail("Security-key identities remain unsupported") }
        }
        for pem in ["RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY"] {
            XCTAssertThrowsError(try OpenSSHIdentityParser.parse("-----BEGIN \(pem)-----\nignored\n-----END \(pem)-----", passphrase: nil)) {
                guard case IdentityError.unsupportedFormat = $0 else { return XCTFail("Expected OpenSSH format guidance") }
            }
        }
    }
}

/// Synthetic keys are generated in memory; no private fixtures or personal key material are committed.
struct ECDSAIdentityFixture {
    let algorithm: String
    let curve: String
    let point: Data
    let scalar: Data
    var publicBytes: Data { Self.field(Data(algorithm.utf8)) + Self.field(Data(curve.utf8)) + Self.field(point) }
    var publicKey: String { algorithm + " " + publicBytes.base64EncodedString() }

    static func all() -> [Self] {
        let p256 = P256.Signing.PrivateKey(), p384 = P384.Signing.PrivateKey(), p521 = P521.Signing.PrivateKey()
        return [Self(algorithm: "ecdsa-sha2-nistp256", curve: "nistp256", point: p256.publicKey.x963Representation, scalar: mpint(p256.rawRepresentation)),
                Self(algorithm: "ecdsa-sha2-nistp384", curve: "nistp384", point: p384.publicKey.x963Representation, scalar: mpint(p384.rawRepresentation)),
                Self(algorithm: "ecdsa-sha2-nistp521", curve: "nistp521", point: p521.publicKey.x963Representation, scalar: mpint(p521.rawRepresentation))]
    }

    func text(curve: String? = nil, point: Data? = nil, scalar: Data? = nil,
              extraPublicBytes: Data = Data(), comment: String = "", badPadding: Bool = false) -> String {
        var secret = Data(repeating: 42, count: 8) + Self.field(Data(algorithm.utf8))
        secret += Self.field(Data((curve ?? self.curve).utf8)) + Self.field(point ?? self.point)
        secret += Self.field(scalar ?? self.scalar) + Self.field(Data(comment.utf8))
        let count = 8 - secret.count % 8
        secret += Data((1...count).map(UInt8.init))
        if badPadding { secret[secret.count - 1] = 0 }
        let data = Data("openssh-key-v1\0".utf8) + Self.field(Data("none".utf8)) + Self.field(Data("none".utf8))
            + Self.field(Data()) + Self.integer(1) + Self.field(publicBytes + extraPublicBytes) + Self.field(secret)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + data.base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    static func mpint(_ data: Data) -> Data {
        let bytes = Data(data.drop(while: { $0 == 0 }))
        return (bytes.first ?? 0) & 0x80 != 0 ? Data([0]) + bytes : bytes
    }
    static func integer(_ value: Int) -> Data { var n = UInt32(value).bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
    static func field(_ data: Data) -> Data { integer(data.count) + data }
}
