import XCTest
import NIOSSH
import BigInt
import Citadel
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif
@testable import RemoteFilesCore

final class IdentitySecKeyFixtureTests: XCTestCase {
    func testSecKeyRSAAndECDSAUIFixturesImportRepeatedly() throws {
        for iteration in 0..<32 {
            for fixture in try ImportedIdentityUIFixture.make() {
                if fixture.algorithm == "ssh-rsa" {
                    try assertRSAComponents(fixture.privateText)
                    XCTAssertNoThrow(try RSASHA2PrivateKey(sshOpenSSH: fixture.privateText),
                                     "SecKey RSA fixture, iteration \(iteration)")
                }
                let imported = try OpenSSHIdentityParser.parse(fixture.privateText, passphrase: nil)
                XCTAssertEqual(String(openSSHPublicKey: imported.key.nioPrivateKey.publicKey),
                               fixture.publicKey, "Fixture \(fixture.name), iteration \(iteration)")
            }
        }
    }

    private func assertRSAComponents(_ text: String) throws {
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var reader = FixtureReader(data: try XCTUnwrap(Data(base64Encoded: body)))
        _ = try reader.take(15)
        for _ in 0..<3 { _ = try reader.field() }
        _ = try reader.integer()
        _ = try reader.field()
        var secret = FixtureReader(data: try reader.field())
        XCTAssertTrue(try secret.integer() == secret.integer(), "Check integers must match")
        XCTAssertTrue(try secret.string() == "ssh-rsa")
        var values: [BigUInt] = []
        for index in 0..<6 {
            let bytes = try secret.field()
            let first = try XCTUnwrap(bytes.first)
            XCTAssertTrue(first < 0x80, "RSA component \(index) must be positive")
            XCTAssertTrue(first != 0 || (bytes.count > 1 && bytes[bytes.startIndex + 1] >= 0x80),
                          "RSA component \(index) must use a canonical mpint")
            values.append(BigUInt(bytes))
        }
        let n = values[0], e = values[1], d = values[2], iqmp = values[3], p = values[4], q = values[5]
        XCTAssertTrue(n.bitWidth == 2048, "SecKey must generate the requested modulus size")
        XCTAssertTrue(p > 1 && q > 1 && p != q)
        guard p > 1, q > 1 else { return }
        XCTAssertTrue(p * q == n, "RSA primes must multiply to the modulus")
        XCTAssertTrue(q * iqmp % p == 1, "OpenSSH requires iqmp = inverse(q) mod p")
        XCTAssertTrue(d < n && d * e % (p - 1) == 1 && d * e % (q - 1) == 1,
                      "RSA private exponent must match both primes")
    }

    #if os(iOS)
    @MainActor
    func testNativePasteStringRepresentationImportsExactUIFixtureText() async throws {
        // A private pasteboard avoids interference from other apps and Universal Clipboard.
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        for fixture in try ImportedIdentityUIFixture.make() {
            fixture.copyPrivateText(to: pasteboard)
            let provider = try XCTUnwrap(pasteboard.itemProviders.first)
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? IdentityError.malformedKey) }
                }
            }
            let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            // Never include either private string in an assertion failure or attachment.
            XCTAssertTrue(text == fixture.privateText, "Native paste changed the fixture bytes")
            let imported = try OpenSSHIdentityParser.parse(text, passphrase: nil)
            XCTAssertEqual(String(openSSHPublicKey: imported.key.nioPrivateKey.publicKey), fixture.publicKey)
        }
    }
    #endif
}

private struct FixtureReader {
    let data: Data
    var offset = 0

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw IdentityError.malformedKey }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func integer() throws -> UInt32 {
        try take(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func field() throws -> Data { try take(Int(integer())) }
    mutating func string() throws -> String {
        try XCTUnwrap(String(data: field(), encoding: .utf8))
    }
}
