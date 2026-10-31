import Foundation
import CryptoKit
import Security
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

/// In-memory, disposable keys exercise the real import form without private fixtures in source.
struct ImportedIdentityUIFixture {
    let name: String
    let algorithm: String
    let publicKey: String
    let privateText: String

    #if os(iOS)
    @MainActor
    func copyPrivateText(to pasteboard: UIPasteboard) {
        // Disposable test secrets must not participate in Universal Clipboard.
        pasteboard.setItems([[UTType.utf8PlainText.identifier: Data(privateText.utf8)]],
                            options: [.localOnly: true])
    }
    #endif

    static func make() throws -> [Self] {
        let key = P256.Signing.PrivateKey()
        let curve = field(Data("nistp256".utf8))
        let point = field(key.publicKey.x963Representation)
        let ec = make(name: "ECDSA P-256", algorithm: "ecdsa-sha2-nistp256", publicFields: curve + point,
                      privateFields: curve + point + field(mpint(key.rawRepresentation)))
        // SecKey returns a PKCS#1 sequence: version, n, e, d, p, q, dp, dq, iqmp.
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                        kSecAttrKeySizeInBits as String: 2048, kSecAttrIsPermanent as String: false]
        guard let rsa = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let bytes = SecKeyCopyExternalRepresentation(rsa, &error) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw NSError(domain: "IdentityUIFixture", code: 1)
        }
        var der = DERReader(data: bytes)
        var sequence = DERReader(data: try der.read(tag: 0x30))
        var values: [Data] = []
        for _ in 0..<9 { values.append(try sequence.read(tag: 0x02)) }
        let rsaFixture = make(name: "RSA", algorithm: "ssh-rsa", publicFields: field(values[2]) + field(values[1]),
                              privateFields: [1, 2, 3, 8, 4, 5].reduce(Data()) { $0 + field(values[$1]) })
        return [rsaFixture, ec]
    }
    private static func make(name: String, algorithm: String, publicFields: Data, privateFields: Data) -> Self {
        let type = field(Data(algorithm.utf8)), publicBytes = type + publicFields
        var secret = Data(repeating: 42, count: 8) + type + privateFields + field(Data())
        secret += Data((1...(8 - secret.count % 8)).map(UInt8.init))
        let body = Data("openssh-key-v1\0".utf8) + field(Data("none".utf8)) + field(Data("none".utf8))
            + field(Data()) + integer(1) + field(publicBytes) + field(secret)
        return Self(name: name, algorithm: algorithm, publicKey: algorithm + " " + publicBytes.base64EncodedString(),
                    privateText: "-----BEGIN OPENSSH PRIVATE KEY-----\n" + body.base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----\n")
    }
    private static func mpint(_ data: Data) -> Data {
        let bytes = Data(data.drop(while: { $0 == 0 }))
        return (bytes.first ?? 0) & 0x80 != 0 ? Data([0]) + bytes : bytes
    }
    private static func integer(_ value: Int) -> Data { var n = UInt32(value).bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
    private static func field(_ data: Data) -> Data { integer(data.count) + data }

    private struct DERReader {
        let data: Data
        var offset = 0
        mutating func read(tag: UInt8) throws -> Data {
            func failure() -> NSError { NSError(domain: "IdentityUIFixture", code: 2) }
            guard offset + 2 <= data.count, data[offset] == tag else { throw failure() }
            offset += 1
            var count = Int(data[offset]); offset += 1
            if count >= 128 {
                let width = count & 127
                guard (1...4).contains(width), offset + width <= data.count else { throw failure() }
                count = data[offset..<(offset + width)].reduce(0) { ($0 << 8) | Int($1) }; offset += width
            }
            guard count <= data.count - offset else { throw failure() }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
    }
}
