import XCTest
import Foundation
import Crypto
import Citadel

/// The app checks a key file's container before it hands it to Citadel's parser (`IdentityStore`).
/// These go to the parser directly: it must refuse the same inputs itself, not read out of bounds or trap.
final class VendoredKeyParserTests: XCTestCase {
    func testAnEncryptedKeyThatNamesNoKeyDerivationIsRefused() {
        func string(_ bytes: [UInt8]) -> [UInt8] { withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init) + bytes }
        func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }
        var container = Array("openssh-key-v1".utf8) + [0]
        container += string("aes256-ctr") + string("none") + string([])
        container += [0, 0, 0, 1]
        container += string(string("ssh-ed25519") + string([UInt8](repeating: 7, count: 32)))
        container += string([UInt8](repeating: 0, count: 64))
        let label = "OPENSSH " + "PRIVATE " + "KEY"
        let file = "-----BEGIN \(label)-----\n" + Data(container).base64EncodedString() + "\n-----END \(label)-----\n"
        XCTAssertThrowsError(try Curve25519.Signing.PrivateKey(sshEd25519: file, decryptionKey: Data("passphrase".utf8)))
        XCTAssertThrowsError(try Curve25519.Signing.PrivateKey(sshEd25519: file))
    }

    func testAnEmptyPassphraseIsRefusedLikeAMissingOne() {
        XCTAssertThrowsError(try Curve25519.Signing.PrivateKey(sshEd25519: EncryptedKeyFixture.openSSH, decryptionKey: Data()))
        XCTAssertThrowsError(try Curve25519.Signing.PrivateKey(sshEd25519: EncryptedKeyFixture.openSSH))
        XCTAssertNoThrow(try Curve25519.Signing.PrivateKey(sshEd25519: EncryptedKeyFixture.openSSH,
                                                           decryptionKey: Data(EncryptedKeyFixture.passphrase.utf8)))
    }
}
