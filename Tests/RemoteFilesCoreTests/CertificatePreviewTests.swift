import XCTest
import Foundation
@testable import RemoteFilesCore

/// Synthetic fixtures made with OpenSSL 4.1 for these tests; their keys were not kept. The expected
/// values are what OpenSSL itself reported, so the parser is checked against another implementation.
private enum Fixtures {
    static let ed448PEM = """
    -----BEGIN CERTIFICATE-----
    MIIBMTCBsqADAgECAgEHMAUGAytlcTAdMRswGQYDVQQDDBJlZDQ0OC5leGFtcGxl
    LnRlc3QwHhcNMjYwMTAxMDAwMDAwWhcNNDYwMTAxMDAwMDAwWjAdMRswGQYDVQQD
    DBJlZDQ0OC5leGFtcGxlLnRlc3QwQzAFBgMrZXEDOgBa5XhU2RkOXwI2y6UeU4GM
    NCtt4NPxr7hDO50qcuWDiZrBQszbqTtM0yRWaRkGxlXEJSfKq5wZLYAwBQYDK2Vx
    A3MAeuUSEkpXqDTpDPe6sCjby4KK6dbPqe+knbimMMm2nt5tzIzMoQue+TNL5GsB
    a5qwbr9AxKXziDyAzAiUuH9ueQOspXkUGA6LWofJoD1RYrzIRyNnT+psJ4XonE96
    k3J412qgBgSKFbrqAUGDox/wwCAA
    -----END CERTIFICATE-----
    """
    static let dsaPEM = """
    -----BEGIN CERTIFICATE-----
    MIIEBzCCA7WgAwIBAgIBCDALBglghkgBZQMEAwIwGzEZMBcGA1UEAwwQZHNhLmV4
    YW1wbGUudGVzdDAeFw0yNjAxMDEwMDAwMDBaFw00NjAxMDEwMDAwMDBaMBsxGTAX
    BgNVBAMMEGRzYS5leGFtcGxlLnRlc3QwggNCMIICNQYHKoZIzjgEATCCAigCggEB
    AIVPbSblg+UkMj0DtJxzlD0LRgAgBSG4ZpgWLQywUwsxnmTuNALTd575+8WcHXwu
    skfiRvHiuVoDjLx6/DOKz3DroWNDA5gOVGrA77BNVOdLsNV+0Dy0AgVmctTG7Vun
    OcJUKjEH/d1MMVpgSGuV2We6khE2DhANv4lVSwh2+JjJoR1IwiFkPt+c2XNjRaEf
    coy5+f8qtZ6fMqC7vIbGA/GWETxhOHjfsvEGORoIq89e6bn7m2iGj0SSUpkb+lLx
    7Ava1U3dAJeaFAuPfBxrMIriZEnAuwrPXHXwCiIS3mMCILeKA3187DyF79MZK+Vq
    j/TmH5ZN5UUJpFkBJ/PfvrsCHQDB0sBtMU+2WsX7nk/hXBnDAhRPvwbuhgUbb1EH
    AoIBAGGTJJ5ftrPguMNdGpGlOloJEmHhdXRsJf+wA93Z3PcygVM+3SpvAT6UFAjD
    NIZWxweniCQSRI371CrGJZazAyMlIhoJzUee3ifuU7Lk/hs2lr/80p7YpqbpD+yD
    gcSk43tqjvfR3Hif3bNT5O9fmH106zJ5Dwm/JMs9K/r3Uw4oGdhYQLRsl3qACYqF
    h110f5Dhxrb6gucdwSruBNNswNdgo6cSXTfOzsALCQq9U6476Z0pNs0flSN7oz2s
    9atKfqYJLzfL2DWagVMwrFjbj2EaCxoMhU9/NhsTRUbkaD7dCN63hl7LfHc9E2eM
    xMG/qgdkfxFIcSXiagcGvC/yZDkDggEFAAKCAQArJWhzmRCL/7z2m7hYrvfKcBa3
    5EupE6YYrIxNnA4qV9ju1TLifzOTArMio2bY0o6d+ELVR3RyJwKOKE63RcotFqR4
    Ri9t/Bv/+savv9NsiZH9rNt3BO5n2hJjne9EvVZoreP618yvtvP2VbTm9SPPTazU
    2yCtiwrbuB2nSg9zLW+dszRSPgtGRrvgTOXBeZMLGLJ02THjZpRA4x6wDp8Nex2F
    +Zgs1fZvnVMfjWXgmldRA1odfeeepiGA/0fnDYFePxY71EN6r1li8suy8saVPchV
    vCJMPQDWxDpyxPBiqHyUeaf1dEuVXEqG8b9kA152S6vwlt5R73yI0b8kPSAJMAsG
    CWCGSAFlAwQDAgM/ADA8AhxycvY0joWkgxk2ZddnEwnkamzPT1W9vlE5GBkZAhxt
    OHAsyrn/Lh+JuGsQvvI+0mNoeT1TYHPepZv2
    -----END CERTIFICATE-----
    """
    static let requestPEM = """
    -----BEGIN CERTIFICATE REQUEST-----
    MIICxjCCAa4CAQAwOjEZMBcGA1UECgwQUmVtb3RlRmlsZXMgRGVtbzEdMBsGA1UE
    AwwUcmVxdWVzdC5leGFtcGxlLnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
    ggEKAoIBAQChaccQkedZ60DIb83tOCjp0d3/I/WMq1ZAa4+zfF15LWFfCsddmgwI
    aMxE9BZEQlvdJhfbTFg42y5he7djPIiC/88r1CHvP4B5IS/fah+vRJ3QGDPJrgZe
    7ImAr/Oh5jIhc/nBvde8MHWPdjKDZ7fdwToI/Tk68SnDNWFz1slxWSaUfkBhxSNO
    vkK9zeYiLkAdrvLlkGwh+BzLalZcyNzmsAfEWdcnlmpEKZ5zY9yLEtXpsvR6rUta
    SveF4tH92txu9ZG/fwhudh/gMr7pbilv4QAJlZkmaChlmnSmIAlUNrmwfHvqZ+XO
    30jVaQtBSSQnxZoMO7fg7aOvAvlB8t4FAgMBAAGgRzBFBgkqhkiG9w0BCQ4xODA2
    MB8GA1UdEQQYMBaCFHJlcXVlc3QuZXhhbXBsZS50ZXN0MBMGA1UdJQQMMAoGCCsG
    AQUFBwMBMA0GCSqGSIb3DQEBCwUAA4IBAQCdldO4K/xE9iLgnmdHV77dHO21hgTy
    oqOIiFxZUiGiEHNUSjiBuqo9zEa/N+rmjAbh++mng8hkfm/EOq4CZSKnfwLbbBAc
    gaiU492vlqHe6EC5+Ii5flaN0SFcbWyK8rs+nFjlb7g98WCzWkGm96mfux4ZKiTT
    dcGJsifUmQKHud3cNIMWcfdn8fhygdKeUSyGe6vrdRSS69lbQOD2GTh9SfG4afux
    cX7UsiphN58BIDi8Zj5+nlfGm0rgWoXXQIp/s/OyvbZxSzIQlI1iyJs5xQBkhq3O
    3g/wi3O5Z/ORqZdYbmPGD7JRyD5/7YifDGGS8UNooC9/9V8JJ3oTNWuj
    -----END CERTIFICATE REQUEST-----
    """
    static let bundlePEM = """
    -----BEGIN PKCS7-----
    MIIFDQYJKoZIhvcNAQcCoIIE/jCCBPoCAQExADALBgkqhkiG9w0BBwGgggTiMIID
    QDCCAuWgAwIBAgIJAMD/7gEjRWeJMAoGCCqGSM49BAMDMFgxGTAXBgNVBAoMEFJl
    bW90ZUZpbGVzIERlbW8xFTATBgNVBAsMDENlcnRpZmljYXRlczEkMCIGA1UEAwwb
    UmVtb3RlRmlsZXMgRGVtbyBJc3N1aW5nIENBMB4XDTI2MDEwMTAwMDAwMFoXDTQ2
    MDEwMTAwMDAwMFowaDELMAkGA1UEBhMCR0IxDzANBgNVBAgMBkFudHJpbTEQMA4G
    A1UEBwwHQmVsZmFzdDEZMBcGA1UECgwQUmVtb3RlRmlsZXMgRGVtbzEbMBkGA1UE
    AwwSZmlsZXMuZXhhbXBsZS50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
    CgKCAQEAoWnHEJHnWetAyG/N7Tgo6dHd/yP1jKtWQGuPs3xdeS1hXwrHXZoMCGjM
    RPQWREJb3SYX20xYONsuYXu3YzyIgv/PK9Qh7z+AeSEv32ofr0Sd0Bgzya4GXuyJ
    gK/zoeYyIXP5wb3XvDB1j3Yyg2e33cE6CP05OvEpwzVhc9bJcVkmlH5AYcUjTr5C
    vc3mIi5AHa7y5ZBsIfgcy2pWXMjc5rAHxFnXJ5ZqRCmec2PcixLV6bL0eq1LWkr3
    heLR/drcbvWRv38IbnYf4DK+6W4pb+EACZWZJmgoZZp0piAJVDa5sHx76mflzt9I
    1WkLQUkkJ8WaDDu34O2jrwL5QfLeBQIDAQABo4G8MIG5MAwGA1UdEwEB/wQCMAAw
    DgYDVR0PAQH/BAQDAgWgMB0GA1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcDAjB6
    BgNVHREEczBxghJmaWxlcy5leGFtcGxlLnRlc3SCFCouZmlsZXMuZXhhbXBsZS50
    ZXN0hwTAAAIKhxAgAQ24AAAAAAAAAAAAAAAQgRBvcHNAZXhhbXBsZS50ZXN0hhto
    dHRwczovL2ZpbGVzLmV4YW1wbGUudGVzdC8wCgYIKoZIzj0EAwMDSQAwRgIhAI0d
    nVlPxeM1+1pRXiyKPbRckB4J2KgXEsyB9+vhKv9QAiEAoRBKLf8timEMxkVR7FWx
    agQUhPNvC6c7Ts7ONdSBL6cwggGaMIIBTKADAgECAgISNDAFBgMrZXAwOzEZMBcG
    A1UECgwQUmVtb3RlRmlsZXMgRGVtbzEeMBwGA1UEAwwVUmVtb3RlRmlsZXMgRGVt
    byBSb290MCAXDTI2MDEwMTAwMDAwMFoYDzIwNTEwMTAxMDAwMDAwWjBYMRkwFwYD
    VQQKDBBSZW1vdGVGaWxlcyBEZW1vMRUwEwYDVQQLDAxDZXJ0aWZpY2F0ZXMxJDAi
    BgNVBAMMG1JlbW90ZUZpbGVzIERlbW8gSXNzdWluZyBDQTBZMBMGByqGSM49AgEG
    CCqGSM49AwEHA0IABBhQbh0XbCFpTO5xEOnUj5DlNQZXmEVk8bQ4TSxM1IkYlb/5
    UimmnmAPYVxDSPECsqSDBa+ikXKqxK6Fx19xf1ujJjAkMBIGA1UdEwEB/wQIMAYB
    Af8CAQAwDgYDVR0PAQH/BAQDAgEGMAUGAytlcANBAAcvAAFG/aGqj3GJt8LxfBh+
    LpjXMT7LpGg4QjNE6s0+trIajJa+ScsrXOx8okH41EGGnxQ2ltHL63V30fKDxwkx
    AA==
    -----END PKCS7-----
    """
    static let trustedPEM = """
    -----BEGIN TRUSTED CERTIFICATE-----
    MIIBSTCB/KADAgECAgEBMAUGAytlcDA7MRkwFwYDVQQKDBBSZW1vdGVGaWxlcyBE
    ZW1vMR4wHAYDVQQDDBVSZW1vdGVGaWxlcyBEZW1vIFJvb3QwIBcNMjYwMTAxMDAw
    MDAwWhgPMjA1NjAxMDEwMDAwMDBaMDsxGTAXBgNVBAoMEFJlbW90ZUZpbGVzIERl
    bW8xHjAcBgNVBAMMFVJlbW90ZUZpbGVzIERlbW8gUm9vdDAqMAUGAytlcAMhACij
    ecll5nZQNc3eZ6RPXuf120N+U8T8HEwMlde87JVaoyMwITAPBgNVHRMBAf8EBTAD
    AQH/MA4GA1UdDwEB/wQEAwIBBjAFBgMrZXADQQCVzllVAhBQ6hlKbva6k+tw59id
    xWXa31v0j1PVrUNWZxNzjCO0BHtuAtkup/Ix1C9BS7iSBCBSeuTG3GEuNAkBMAww
    CgYIKwYBBQUHAwE=
    -----END TRUSTED CERTIFICATE-----
    """
    static let requestDER = Data(base64Encoded: "MIICxjCCAa4CAQAwOjEZMBcGA1UECgwQUmVtb3RlRmlsZXMgRGVtbzEdMBsGA1UEAwwUcmVxdWVzdC5leGFtcGxlLnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQChaccQkedZ60DIb83tOCjp0d3/I/WMq1ZAa4+zfF15LWFfCsddmgwIaMxE9BZEQlvdJhfbTFg42y5he7djPIiC/88r1CHvP4B5IS/fah+vRJ3QGDPJrgZe7ImAr/Oh5jIhc/nBvde8MHWPdjKDZ7fdwToI/Tk68SnDNWFz1slxWSaUfkBhxSNOvkK9zeYiLkAdrvLlkGwh+BzLalZcyNzmsAfEWdcnlmpEKZ5zY9yLEtXpsvR6rUtaSveF4tH92txu9ZG/fwhudh/gMr7pbilv4QAJlZkmaChlmnSmIAlUNrmwfHvqZ+XO30jVaQtBSSQnxZoMO7fg7aOvAvlB8t4FAgMBAAGgRzBFBgkqhkiG9w0BCQ4xODA2MB8GA1UdEQQYMBaCFHJlcXVlc3QuZXhhbXBsZS50ZXN0MBMGA1UdJQQMMAoGCCsGAQUFBwMBMA0GCSqGSIb3DQEBCwUAA4IBAQCdldO4K/xE9iLgnmdHV77dHO21hgTyoqOIiFxZUiGiEHNUSjiBuqo9zEa/N+rmjAbh++mng8hkfm/EOq4CZSKnfwLbbBAcgaiU492vlqHe6EC5+Ii5flaN0SFcbWyK8rs+nFjlb7g98WCzWkGm96mfux4ZKiTTdcGJsifUmQKHud3cNIMWcfdn8fhygdKeUSyGe6vrdRSS69lbQOD2GTh9SfG4afuxcX7UsiphN58BIDi8Zj5+nlfGm0rgWoXXQIp/s/OyvbZxSzIQlI1iyJs5xQBkhq3O3g/wi3O5Z/ORqZdYbmPGD7JRyD5/7YifDGGS8UNooC9/9V8JJ3oTNWuj")!
    static let bundleDER = Data(base64Encoded: "MIIFDQYJKoZIhvcNAQcCoIIE/jCCBPoCAQExADALBgkqhkiG9w0BBwGgggTiMIIDQDCCAuWgAwIBAgIJAMD/7gEjRWeJMAoGCCqGSM49BAMDMFgxGTAXBgNVBAoMEFJlbW90ZUZpbGVzIERlbW8xFTATBgNVBAsMDENlcnRpZmljYXRlczEkMCIGA1UEAwwbUmVtb3RlRmlsZXMgRGVtbyBJc3N1aW5nIENBMB4XDTI2MDEwMTAwMDAwMFoXDTQ2MDEwMTAwMDAwMFowaDELMAkGA1UEBhMCR0IxDzANBgNVBAgMBkFudHJpbTEQMA4GA1UEBwwHQmVsZmFzdDEZMBcGA1UECgwQUmVtb3RlRmlsZXMgRGVtbzEbMBkGA1UEAwwSZmlsZXMuZXhhbXBsZS50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoWnHEJHnWetAyG/N7Tgo6dHd/yP1jKtWQGuPs3xdeS1hXwrHXZoMCGjMRPQWREJb3SYX20xYONsuYXu3YzyIgv/PK9Qh7z+AeSEv32ofr0Sd0Bgzya4GXuyJgK/zoeYyIXP5wb3XvDB1j3Yyg2e33cE6CP05OvEpwzVhc9bJcVkmlH5AYcUjTr5Cvc3mIi5AHa7y5ZBsIfgcy2pWXMjc5rAHxFnXJ5ZqRCmec2PcixLV6bL0eq1LWkr3heLR/drcbvWRv38IbnYf4DK+6W4pb+EACZWZJmgoZZp0piAJVDa5sHx76mflzt9I1WkLQUkkJ8WaDDu34O2jrwL5QfLeBQIDAQABo4G8MIG5MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMB0GA1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcDAjB6BgNVHREEczBxghJmaWxlcy5leGFtcGxlLnRlc3SCFCouZmlsZXMuZXhhbXBsZS50ZXN0hwTAAAIKhxAgAQ24AAAAAAAAAAAAAAAQgRBvcHNAZXhhbXBsZS50ZXN0hhtodHRwczovL2ZpbGVzLmV4YW1wbGUudGVzdC8wCgYIKoZIzj0EAwMDSQAwRgIhAI0dnVlPxeM1+1pRXiyKPbRckB4J2KgXEsyB9+vhKv9QAiEAoRBKLf8timEMxkVR7FWxagQUhPNvC6c7Ts7ONdSBL6cwggGaMIIBTKADAgECAgISNDAFBgMrZXAwOzEZMBcGA1UECgwQUmVtb3RlRmlsZXMgRGVtbzEeMBwGA1UEAwwVUmVtb3RlRmlsZXMgRGVtbyBSb290MCAXDTI2MDEwMTAwMDAwMFoYDzIwNTEwMTAxMDAwMDAwWjBYMRkwFwYDVQQKDBBSZW1vdGVGaWxlcyBEZW1vMRUwEwYDVQQLDAxDZXJ0aWZpY2F0ZXMxJDAiBgNVBAMMG1JlbW90ZUZpbGVzIERlbW8gSXNzdWluZyBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBhQbh0XbCFpTO5xEOnUj5DlNQZXmEVk8bQ4TSxM1IkYlb/5UimmnmAPYVxDSPECsqSDBa+ikXKqxK6Fx19xf1ujJjAkMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMAUGAytlcANBAAcvAAFG/aGqj3GJt8LxfBh+LpjXMT7LpGg4QjNE6s0+trIajJa+ScsrXOx8okH41EGGnxQ2ltHL63V30fKDxwkxAA==")!
}

/// Builds DER by hand, so a test can write what no real tool would. Nothing here verifies signatures.
private enum Build {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var length: [UInt8]
        if content.count < 0x80 {
            length = [UInt8(content.count)]
        } else {
            var bytes = withUnsafeBytes(of: UInt32(content.count).bigEndian, Array.init).drop { $0 == 0 }
            bytes.insert(0x80 | UInt8(bytes.count), at: bytes.startIndex)
            length = Array(bytes)
        }
        length.insert(tag, at: 0)
        return length + content
    }
    static func sequence(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    static func oid(_ encoded: [UInt8]) -> [UInt8] { tlv(0x06, encoded) }
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    static func name(tag: UInt8 = 0x0C, _ value: [UInt8], type: [UInt8] = commonName) -> [UInt8] {
        sequence(tlv(0x31, sequence(oid(type), tlv(tag, value))))
    }
    static func text(_ string: String) -> [UInt8] { Array(string.utf8) }
    static let ed25519Key = sequence(sequence(oid([0x2B, 0x65, 0x70])), tlv(0x03, [0] + [UInt8](repeating: 1, count: 32)))
    static let ed25519Signature = sequence(oid([0x2B, 0x65, 0x70]))

    static func certificate(serial: [UInt8] = [0x01], subject: [UInt8] = name(text("example.test")), issuer: [UInt8]? = nil,
                            notBefore: [UInt8] = tlv(0x17, text("260101000000Z")), notAfter: [UInt8] = tlv(0x17, text("460101000000Z")),
                            publicKey: [UInt8] = ed25519Key, extensions: [[UInt8]] = []) -> [UInt8] {
        var fields = tlv(0xA0, tlv(0x02, [2])) + tlv(0x02, serial) + ed25519Signature + (issuer ?? name(text("Test Issuer")))
        fields += sequence(notBefore, notAfter) + subject + publicKey
        if !extensions.isEmpty { fields += tlv(0xA3, tlv(0x30, extensions.flatMap { $0 })) }
        return sequence(tlv(0x30, fields), ed25519Signature, tlv(0x03, [0, 1, 2, 3]))
    }
    static func `extension`(_ type: [UInt8], _ value: [UInt8]) -> [UInt8] { sequence(oid(type), tlv(0x04, value)) }
    static func alternativeNames(_ names: [[UInt8]]) -> [UInt8] { `extension`([0x55, 0x1D, 0x11], tlv(0x30, names.flatMap { $0 })) }
    static func pem(_ der: [UInt8], label: String = "CERTIFICATE") -> String {
        let body = Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }
    /// Built up so secret scanners don't flag this file. The body is a marked non-secret.
    static func keyBlock(_ label: String = "PRIVATE" + " KEY", body: String = secretBody) -> String {
        "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n"
    }
    static let secretBody = "U0VOVElORUwtS0VZLUJZVEVTLVNFTlRJTkVMLUtFWS1CWVRFUw=="
}

final class CertificatePreviewTests: XCTestCase {
    private func contents(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> CertificateFileContents {
        guard case .contents(let contents) = CertificatePreview.parse(data) else {
            XCTFail("Expected contents, got \(CertificatePreview.parse(data))", file: file, line: line)
            throw RemoteFileError.unsupportedFile
        }
        return contents
    }
    private func contents(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> CertificateFileContents {
        try contents(Data(text.utf8), file: file, line: line)
    }
    private func only(_ der: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws -> CertificateSummary {
        try XCTUnwrap(try contents(Data(der), file: file, line: line).certificates.first, file: file, line: line)
    }
    private func date(_ year: Int, _ month: Int = 1, _ day: Int = 1) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: Fields, against OpenSSL's report

    func testLeafFieldsMatchWhatOpenSSLReports() throws {
        let file = try contents(DemoCertificates.leaf)
        XCTAssertEqual(file.certificates.count, 1)
        XCTAssertEqual(file.privateKeys, 0)
        let leaf = try XCTUnwrap(file.certificates.first)
        XCTAssertEqual(leaf.title, "files.example.test")
        XCTAssertEqual(leaf.subject.attributes, [.init(name: "Country", value: "GB"), .init(name: "State or Province", value: "Antrim"),
                                                 .init(name: "Locality", value: "Belfast"), .init(name: "Organization", value: "RemoteFiles Demo"),
                                                 .init(name: "Common Name", value: "files.example.test")])
        XCTAssertEqual(leaf.issuer?.attributes, [.init(name: "Organization", value: "RemoteFiles Demo"),
                                                 .init(name: "Organizational Unit", value: "Certificates"),
                                                 .init(name: "Common Name", value: "RemoteFiles Demo Issuing CA")])
        XCTAssertEqual(leaf.version, 3)
        XCTAssertEqual(leaf.serialNumber, "C0:FF:EE:01:23:45:67:89", "OpenSSL shows the serial without its sign byte")
        XCTAssertEqual(leaf.notBefore, date(2026)); XCTAssertEqual(leaf.notAfter, date(2046))
        XCTAssertEqual(leaf.publicKey, .init(algorithm: "RSA", bits: 2048))
        XCTAssertEqual(leaf.signatureAlgorithm, "ECDSA with SHA-384")
        XCTAssertEqual(leaf.basicConstraints, .init(isCA: false, pathLength: nil))
        XCTAssertEqual(leaf.keyUsage, ["Digital Signature", "Key Encipherment"])
        XCTAssertEqual(leaf.extendedKeyUsage, ["TLS Server Authentication", "TLS Client Authentication"])
        XCTAssertFalse(leaf.isSelfSigned)
        XCTAssertEqual(leaf.alternativeNames, [.init(kind: .dns, value: "files.example.test"), .init(kind: .dns, value: "*.files.example.test"),
                                               .init(kind: .ipAddress, value: "192.0.2.10"), .init(kind: .ipAddress, value: "2001:db8::10"),
                                               .init(kind: .email, value: "ops@example.test"), .init(kind: .uri, value: "https://files.example.test/")])
        XCTAssertEqual(leaf.sha256Fingerprint, "07:32:31:3B:E8:74:28:4D:E2:3B:41:E1:56:4F:8F:EF:36:09:20:5D:FF:B0:EB:6C:51:59:7A:13:1E:C0:62:6D")
        XCTAssertEqual(leaf.sha1Fingerprint, "CE:66:17:C9:CD:A9:45:D6:FA:FF:F6:50:55:D4:46:AA:FB:9C:23:97")
        XCTAssertEqual(leaf.unreadableExtensions, 0)
    }

    func testAChainKeepsFileOrderWithTheLeafFirst() throws {
        let chain = try contents([DemoCertificates.leaf, DemoCertificates.issuer, DemoCertificates.root].joined(separator: "\n"))
        XCTAssertEqual(chain.certificates.map(\.title), ["files.example.test", "RemoteFiles Demo Issuing CA", "RemoteFiles Demo Root"])
        XCTAssertEqual(chain.certificates.map(\.id), [0, 1, 2])
        let issuer = chain.certificates[1], root = chain.certificates[2]
        XCTAssertEqual(issuer.basicConstraints, .init(isCA: true, pathLength: 0))
        XCTAssertEqual(issuer.publicKey, .init(algorithm: "Elliptic Curve (P-256)", bits: 256))
        XCTAssertEqual(issuer.keyUsage, ["Certificate Signing", "CRL Signing"])
        XCTAssertEqual(issuer.serialNumber, "12:34")
        XCTAssertEqual(issuer.sha1Fingerprint, "DC:22:B9:F5:87:0D:A1:B7:0A:11:FA:5F:25:46:1A:21:FA:AC:28:73")
        XCTAssertTrue(root.isSelfSigned)
        XCTAssertEqual(root.basicConstraints, .init(isCA: true, pathLength: nil))
        XCTAssertEqual(root.publicKey, .init(algorithm: "Ed25519", bits: 256))
        XCTAssertEqual(root.signatureAlgorithm, "Ed25519")
        XCTAssertEqual(root.sha256Fingerprint, "B6:8D:8D:46:40:C3:78:0C:41:30:6D:DB:AD:CA:4B:73:E6:0D:DB:51:3B:82:18:98:A1:48:1B:0D:54:02:65:1B")
    }

    func testDERIsRecognizedByContentAndAgreesWithItsPEMForm() throws {
        let der = try XCTUnwrap(DemoCertificates.contents(of: "Expired server.cer"))
        XCTAssertEqual(der.first, 0x30)
        let summary = try XCTUnwrap(try contents(der).certificates.first)
        XCTAssertEqual(summary.title, "expired.example.test")
        XCTAssertEqual(summary.publicKey, .init(algorithm: "Elliptic Curve (P-384)", bits: 384))
        XCTAssertEqual(summary.signatureAlgorithm, "ECDSA with SHA-384")
        XCTAssertTrue(summary.isSelfSigned)
        XCTAssertEqual(summary.sha256Fingerprint, "32:F0:C9:45:AF:D1:B7:68:5C:B4:D6:90:FC:F1:F1:D3:87:CF:93:12:79:34:47:3D:87:84:BA:E8:57:89:41:44")
        // The same bytes in PEM, whatever the file happens to be named.
        let asPEM = try contents(Build.pem(Array(der))).certificates.first
        XCTAssertEqual(asPEM?.sha256Fingerprint, summary.sha256Fingerprint)
    }

    func testAlgorithmsOutsideTheCommonFewStillShow() throws {
        let ed448 = try XCTUnwrap(try contents(Fixtures.ed448PEM).certificates.first)
        XCTAssertEqual(ed448.publicKey, .init(algorithm: "Ed448", bits: 456))
        XCTAssertEqual(ed448.signatureAlgorithm, "Ed448")
        let dsa = try XCTUnwrap(try contents(Fixtures.dsaPEM).certificates.first)
        XCTAssertEqual(dsa.publicKey, .init(algorithm: "DSA", bits: 2048))
        XCTAssertEqual(dsa.signatureAlgorithm, "DSA with SHA-256")
        XCTAssertEqual(dsa.sha256Fingerprint, "DE:BC:B9:DA:70:BC:84:DE:3E:77:95:5C:63:41:AD:15:7F:F5:FD:22:C7:96:40:70:84:E9:02:A6:95:04:BB:03")
        // RSA below today's minimum is what someone inspecting an old certificate needs to see.
        let modulus = Build.tlv(0x02, [0x00, 0x80] + [UInt8](repeating: 1, count: 127))
        let rsaKey = Build.sequence(Build.sequence(Build.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), Build.tlv(0x05, [])),
                                    Build.tlv(0x03, [0] + Build.sequence(modulus, Build.tlv(0x02, [1, 0, 1]))))
        XCTAssertEqual(try only(Build.certificate(publicKey: rsaKey)).publicKey, .init(algorithm: "RSA", bits: 1024))
        let unknownKey = Build.sequence(Build.sequence(Build.oid([0x2A, 0x03, 0x04])), Build.tlv(0x03, [0, 9, 9]))
        let unknown = try only(Build.certificate(publicKey: unknownKey))
        XCTAssertEqual(unknown.publicKey, .init(algorithm: "1.2.3.4", bits: nil), "Not knowing an algorithm doesn't fail the certificate")
    }

    func testSigningRequestsAndBundlesAreReadByStructure() throws {
        for request in [try contents(Fixtures.requestPEM), try contents(Fixtures.requestDER)] {
            let summary = try XCTUnwrap(request.certificates.first)
            XCTAssertEqual(summary.role, .signingRequest)
            XCTAssertEqual(summary.title, "request.example.test")
            XCTAssertEqual(summary.alternativeNames, [.init(kind: .dns, value: "request.example.test")])
            XCTAssertEqual(summary.extendedKeyUsage, ["TLS Server Authentication"])
            XCTAssertEqual(summary.publicKey, .init(algorithm: "RSA", bits: 2048))
            XCTAssertEqual(summary.signatureAlgorithm, "SHA-256 with RSA")
            XCTAssertNil(summary.issuer); XCTAssertNil(summary.sha256Fingerprint)
            XCTAssertEqual(summary.validity(at: .now), .unknown)
        }
        for bundle in [try contents(Fixtures.bundlePEM), try contents(Fixtures.bundleDER)] {
            XCTAssertEqual(bundle.certificates.map(\.title), ["files.example.test", "RemoteFiles Demo Issuing CA"])
            XCTAssertEqual(bundle.certificates.first?.sha1Fingerprint, "CE:66:17:C9:CD:A9:45:D6:FA:FF:F6:50:55:D4:46:AA:FB:9C:23:97")
        }
    }

    func testBundleWithIndefiniteLengthsIsRead() throws {
        // ContentInfo and SignedData written with BER's indefinite lengths, as some tools do.
        let certificate = Build.certificate()
        let certificates = [0xA0, 0x80] + certificate + [0, 0]
        let signedData = [0x30, 0x80] + Build.tlv(0x02, [1]) + Build.tlv(0x31, [])
            + Build.sequence(Build.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])) + certificates + [0, 0]
        let bundle = [0x30, 0x80] + Build.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]) + [0xA0, 0x80] + signedData + [0, 0, 0, 0]
        XCTAssertEqual(try contents(Data(bundle)).certificates.map(\.title), ["example.test"])
    }

    func testTrustedCertificateIgnoresTheSettingsAfterIt() throws {
        let trusted = try XCTUnwrap(try contents(Fixtures.trustedPEM).certificates.first)
        XCTAssertEqual(trusted.sha256Fingerprint, "B6:8D:8D:46:40:C3:78:0C:41:30:6D:DB:AD:CA:4B:73:E6:0D:DB:51:3B:82:18:98:A1:48:1B:0D:54:02:65:1B",
                       "OpenSSL's fingerprint covers the certificate only")
    }

    func testUnreadableExtensionIsCountedAndTheRestStillShow() throws {
        let broken = Build.extension([0x55, 0x1D, 0x13], [0x30, 0x7F])
        let notSequence = Build.extension([0x55, 0x1D, 0x25], Build.tlv(0x02, [1]))
        let good = Build.alternativeNames([Build.tlv(0x82, Build.text("example.test"))])
        let summary = try only(Build.certificate(extensions: [broken, notSequence, good]))
        XCTAssertEqual(summary.unreadableExtensions, 2)
        XCTAssertNil(summary.basicConstraints)
        XCTAssertEqual(summary.alternativeNames, [.init(kind: .dns, value: "example.test")])
    }

    // MARK: Dates

    func testValidityIsAFactAboutTheDatesAtEachBoundary() throws {
        let summary = try only(Build.certificate(notBefore: Build.tlv(0x17, Build.text("260101000000Z")), notAfter: Build.tlv(0x17, Build.text("270101000000Z"))))
        XCTAssertEqual(summary.validity(at: date(2025)), .notYetValid(startsAt: date(2026)))
        XCTAssertEqual(summary.validity(at: date(2026)), .withinDates(endsAt: date(2027)))
        XCTAssertEqual(summary.validity(at: date(2027)), .withinDates(endsAt: date(2027)))
        XCTAssertEqual(summary.validity(at: date(2027).addingTimeInterval(1)), .expired(endedAt: date(2027)))
    }

    func testDatesFollowTheTwoDigitYearRuleAndRejectImpossibleValues() throws {
        func notAfter(_ tag: UInt8, _ text: String) throws -> Date? {
            try only(Build.certificate(notAfter: Build.tlv(tag, Build.text(text)))).notAfter
        }
        XCTAssertEqual(try notAfter(0x17, "491231235959Z"), date(2049, 12, 31).addingTimeInterval(86_399))
        XCTAssertEqual(try notAfter(0x17, "500101000000Z"), date(1950))
        XCTAssertEqual(try notAfter(0x18, "99991231235959Z"), date(9999, 12, 31).addingTimeInterval(86_399))
        XCTAssertEqual(try notAfter(0x18, "20240229000000Z"), date(2024, 2, 29))
        for (tag, text) in [(UInt8(0x18), "20230229000000Z"), (0x17, "261301000000Z"), (0x17, "260132000000Z"), (0x17, "260101250000Z"),
                            (0x17, "260101000000"), (0x17, "2601010000Z"), (0x18, "260101000000Z"), (0x17, "2601010000+0100"), (0x17, "")] {
            XCTAssertNil(try notAfter(tag, text), text)
        }
        let undated = try only(Build.certificate(notAfter: Build.tlv(0x17, Build.text("garbage"))))
        XCTAssertEqual(undated.validity(at: .now), .unknown, "An unreadable date is never reported as in date")
    }

    // MARK: Bytes around and within PEM

    func testAnyLineEndingOrSurroundingEncodingStillFindsBlocks() throws {
        let pem = DemoCertificates.issuer
        let fingerprint = "DC:22:B9:F5:87:0D:A1:B7:0A:11:FA:5F:25:46:1A:21:FA:AC:28:73"
        var forms: [String: Data] = [
            "CRLF": Data(pem.replacingOccurrences(of: "\n", with: "\r\n").utf8),
            "CR": Data(pem.replacingOccurrences(of: "\n", with: "\r").utf8),
            "One line": Data(pem.replacingOccurrences(of: "\n", with: "").utf8),
            "Trailing spaces and tabs": Data(pem.replacingOccurrences(of: "\n", with: " \t\n").utf8),
            "UTF-8 byte order mark": Data([0xEF, 0xBB, 0xBF]) + Data(pem.utf8),
            "Latin-1 and NUL before": Data([0xE9, 0xFF, 0x00, 0x0A]) + Data(pem.utf8) + Data([0xFF, 0x00]),
            "Human-readable text before": Data("Bag Attributes\n    friendlyName: caf\u{E9}\nsubject=/CN=x\n".utf8) + Data(pem.utf8)
        ]
        forms["UTF-16 little-endian"] = pem.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        forms["UTF-16 big-endian"] = pem.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        for (name, data) in forms {
            let found = try contents(data)
            XCTAssertEqual(found.certificates.first?.sha1Fingerprint, fingerprint, name)
            XCTAssertEqual(found.unreadableBlocks, 0, name)
        }
    }

    func testDamagedBlocksAreCountedBesideTheOnesThatRead() throws {
        let good = DemoCertificates.issuer
        let invalidBase64 = "-----BEGIN CERTIFICATE-----\n!!!not base64!!!\n-----END CERTIFICATE-----\n"
        let notCertificate = Build.pem([0x30, 0x03, 0x02, 0x01, 0x01])
        let unterminated = "-----BEGIN CERTIFICATE-----\nMIIB"
        let file = try contents(invalidBase64 + good + notCertificate + unterminated)
        XCTAssertEqual(file.certificates.count, 1)
        XCTAssertEqual(file.unreadableBlocks, 3)
        let other = try contents("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n" + good)
        XCTAssertEqual(other.otherBlocks, 1); XCTAssertEqual(other.certificates.count, 1)
    }

    // MARK: Private keys

    func testPrivateKeyIsReportedAndItsBytesAreNeverKept() throws {
        let sentinel = "SENTINEL-KEY-BYTES"
        for label in ["PRIVATE" + " KEY", "RSA PRIVATE" + " KEY", "EC PRIVATE" + " KEY", "DSA PRIVATE" + " KEY",
                      "ENCRYPTED PRIVATE" + " KEY", "OPENSSH PRIVATE" + " KEY", "ANY PRIVATE" + " KEY", "private" + " key"] {
            let file = try contents(DemoCertificates.leaf + "\n" + Build.keyBlock(label))
            XCTAssertEqual(file.privateKeys, 1, label)
            XCTAssertEqual(file.certificates.count, 1, "The certificate beside the key is still summarized: \(label)")
            XCTAssertEqual(file.unreadableBlocks, 0, label)
            let everything = String(reflecting: file)
            XCTAssertFalse(everything.contains(sentinel), label)
            XCTAssertFalse(everything.contains(Build.secretBody), label)
        }
    }

    func testKeyWithNoCertificateAndUnusualShapesAreStillSaidPlainly() throws {
        XCTAssertEqual(try contents(Build.keyBlock()).privateKeys, 1)
        XCTAssertEqual(try contents(Build.keyBlock()).certificates, [])
        // No END marker, a block on one line, CR line endings, UTF-16, and not valid base64 at all.
        let begin = "-----BEGIN PRIVATE" + " KEY-----"
        for (name, text) in [("Unterminated", begin + "\nAAAA"), ("One line", Build.keyBlock().replacingOccurrences(of: "\n", with: "")),
                             ("CR", Build.keyBlock().replacingOccurrences(of: "\n", with: "\r")),
                             ("Not base64", Build.keyBlock(body: "\u{E9}\u{0} @@@ not base64"))] {
            XCTAssertEqual(try contents(text).privateKeys, 1, name)
        }
        let wide = try XCTUnwrap(Build.keyBlock().data(using: .utf16LittleEndian))
        XCTAssertEqual(try contents(Data([0xFF, 0xFE]) + wide).privateKeys, 1)
        // A key after a block that never ended still counts, as does each of several.
        XCTAssertEqual(try contents("-----BEGIN CERTIFICATE-----\nMIIB\n" + Build.keyBlock() + Build.keyBlock()).privateKeys, 2)
    }

    func testKeyAfterTheCertificateLimitIsStillReported() throws {
        let many = String(repeating: Build.pem(Build.certificate()), count: CertificatePreview.maximumCertificates + 5)
        let file = try contents(many + Build.keyBlock())
        XCTAssertEqual(file.certificates.count, CertificatePreview.maximumCertificates)
        XCTAssertEqual(file.omittedCertificates, 5)
        XCTAssertEqual(file.privateKeys, 1)
    }

    func testBinaryPrivateKeysAreRecognizedAndNotReadAsCertificates() throws {
        let integer = Build.tlv(0x02, [1])
        let pkcs8 = Build.sequence(Build.tlv(0x02, [0]), Build.sequence(Build.oid([0x2B, 0x65, 0x70])), Build.tlv(0x04, [UInt8](repeating: 7, count: 34)))
        let sec1 = Build.sequence(integer, Build.tlv(0x04, [UInt8](repeating: 7, count: 32)))
        let rsa = Build.sequence(Array(repeating: integer, count: 9).flatMap { $0 })
        let encrypted = Build.sequence(Build.sequence(Build.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D])), Build.tlv(0x04, [7, 7]))
        for (name, der) in [("PKCS #8", pkcs8), ("SEC 1", sec1), ("PKCS #1", rsa), ("Encrypted PKCS #8", encrypted)] {
            let file = try contents(Data(der))
            XCTAssertEqual(file.privateKeys, 1, name); XCTAssertEqual(file.certificates, [], name)
        }
    }

    // MARK: Hostile input

    func testEmptyGarbageAndWrongTypesGiveACalmResult() {
        XCTAssertEqual(CertificatePreview.parse(Data()), .empty)
        for (name, data) in [("Text", Data("hello, world\n".utf8)), ("Whitespace", Data(" \n\t".utf8)), ("One byte", Data([0x30])),
                             ("Random", Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })), ("NULs", Data(count: 1_024)),
                             ("Empty sequence", Data([0x30, 0x00])), ("Length past the end", Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])),
                             ("Only a public key", Data("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n".utf8)),
                             ("Only a damaged certificate", Data("-----BEGIN CERTIFICATE-----\nMII\n-----END CERTIFICATE-----\n".utf8)),
                             ("Marker with no label", Data("-----BEGIN -----\n".utf8))] {
            XCTAssertEqual(CertificatePreview.parse(data), .unrecognized, name)
        }
    }

    func testEveryTruncationAndManyCorruptionsNeverCrash() throws {
        let der = [UInt8](try XCTUnwrap(DemoCertificates.contents(of: "Expired server.cer")))
        for length in 0..<der.count {
            _ = CertificatePreview.parse(Data(der[..<length]))
            _ = CertificatePreview.parse(Data(Build.pem(Array(der[..<length])).utf8))
        }
        // A small, repeatable generator, so a failure here reproduces.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(bound))
        }
        let leaf = [UInt8](try XCTUnwrap(Data(base64Encoded: DemoCertificates.leaf.split(separator: "\n").dropFirst().dropLast().joined())))
        for round in 0..<3_000 {
            var bytes = round % 2 == 0 ? der : leaf
            for _ in 0...next(4) { bytes[next(bytes.count)] = UInt8(next(256)) }
            _ = CertificatePreview.parse(Data(bytes))
        }
    }

    func testDeepNestingAndLengthTricksAreRefused() {
        var deep = Build.tlv(0x02, [1])
        for _ in 0..<200 { deep = Build.tlv(0x30, deep) }
        XCTAssertEqual(CertificatePreview.parse(Data(deep)), .unrecognized)
        XCTAssertEqual(CertificatePreview.parse(Data(Build.pem(deep).utf8)), .unrecognized)
        // A marker repeated with no end must stay linear rather than rescanning for each one.
        let markers = Data(String(repeating: "-----BEGIN ", count: 150_000).utf8)
        XCTAssertLessThanOrEqual(markers.count, CertificatePreview.maximumFileBytes)
        XCTAssertEqual(CertificatePreview.parse(markers), .unrecognized)
    }

    func testOversizedInputsAreRefusedBeforeParsing() throws {
        XCTAssertEqual(CertificatePreview.parse(Data(count: CertificatePreview.maximumFileBytes + 1)), .tooLarge)
        XCTAssertEqual(CertificatePreview.parse(Data([0x30]) + Data(count: CertificatePreview.maximumContainerBytes)), .tooLarge)
        XCTAssertEqual(CertificatePreview.parse(Data(count: CertificatePreview.maximumContainerBytes + 1)), .unrecognized, "Not DER, so not parsed as DER")
        let large = Build.certificate(subject: Build.name(Build.text(String(repeating: "x", count: CertificatePreview.maximumCertificateBytes))))
        let file = try contents(Build.pem(large) + DemoCertificates.issuer)
        XCTAssertEqual(file.unreadableBlocks, 1, "One certificate over the limit leaves the rest readable")
        XCTAssertEqual(file.certificates.count, 1)
    }

    func testManyCertificatesStopAtTheLimitWithACount() throws {
        let extra = 37
        let pem = try contents(String(repeating: Build.pem(Build.certificate()), count: CertificatePreview.maximumCertificates + extra))
        XCTAssertEqual(pem.certificates.count, CertificatePreview.maximumCertificates)
        XCTAssertEqual(pem.omittedCertificates, extra)
        XCTAssertEqual(pem.certificates.last?.id, CertificatePreview.maximumCertificates - 1)
        let one = Build.certificate()
        let certificates = Build.tlv(0xA0, Array(repeating: one, count: CertificatePreview.maximumCertificates + extra).flatMap { $0 })
        let signedData = Build.sequence(Build.tlv(0x02, [1]), Build.tlv(0x31, []), Build.sequence(Build.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])), certificates)
        let bundle = Build.sequence(Build.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]), Build.tlv(0xA0, signedData))
        let parsed = try contents(Data(bundle))
        XCTAssertEqual(parsed.certificates.count, CertificatePreview.maximumCertificates)
        XCTAssertEqual(parsed.omittedCertificates, extra)
    }

    func testFieldsAreBoundedInLengthAndCount() throws {
        let long = String(repeating: "é", count: 40_000)
        let summary = try only(Build.certificate(serial: [0x7F] + [UInt8](repeating: 0xAB, count: 500), subject: Build.name(Build.text(long)),
            extensions: [Build.alternativeNames(Array(repeating: Build.tlv(0x82, Build.text(long)), count: 2))]))
        let value = try XCTUnwrap(summary.subject.attributes.first?.value)
        XCTAssertLessThanOrEqual(value.utf8.count, CertificatePreview.maximumFieldBytes + 8)
        XCTAssertTrue(value.hasSuffix("…"))
        XCTAssertLessThanOrEqual(summary.alternativeNames.first?.value.utf8.count ?? .max, CertificatePreview.maximumFieldBytes + 8)
        XCTAssertLessThan(summary.serialNumber?.count ?? .max, CertificatePreview.maximumSerialBytes * 3 + 2)

        // An attribute of an unknown type is named by its identifier, which is as long as its encoding.
        let identifier = [UInt8](repeating: 0x01, count: 60_000)
        let unknown = try only(Build.certificate(subject: Build.name(Build.text("value"), type: [0x2A] + identifier)))
        let name = try XCTUnwrap(unknown.subject.attributes.first?.name)
        XCTAssertTrue(name.hasPrefix("1.2.1.1.1"), name.prefix(20).description)
        XCTAssertLessThanOrEqual(name.utf8.count, CertificatePreview.maximumFieldBytes + 8)
        XCTAssertTrue(name.hasSuffix("…"))

        let names = Array(repeating: Build.tlv(0x82, Build.text("a.example.test")), count: CertificatePreview.maximumAlternativeNames + 44)
        let many = try only(Build.certificate(extensions: [Build.alternativeNames(names)]))
        XCTAssertEqual(many.alternativeNames.count, CertificatePreview.maximumAlternativeNames)
        XCTAssertEqual(many.omittedAlternativeNames, 44)

        let attributes = Array(repeating: Build.tlv(0x31, Build.sequence(Build.oid(Build.commonName), Build.tlv(0x0C, Build.text("n")))),
                               count: CertificatePreview.maximumNameAttributes + 9).flatMap { $0 }
        let crowded = try only(Build.certificate(subject: Build.tlv(0x30, attributes)))
        XCTAssertEqual(crowded.subject.attributes.count, CertificatePreview.maximumNameAttributes)
        XCTAssertEqual(crowded.subject.omittedAttributes, 9)
    }

    func testControlAndBidirectionalCharactersCannotDisguiseAName() throws {
        let nul = try only(Build.certificate(subject: Build.name(Build.text("bank.example\0.evil.example"))))
        XCTAssertEqual(nul.title, "bank.example\u{FFFD}.evil.example")
        let bidi = try only(Build.certificate(subject: Build.name(Build.text("\u{202E}elpmaxe.knab\u{202C}\nFAKE"))))
        XCTAssertEqual(bidi.title, "\u{FFFD}elpmaxe.knab\u{FFFD}\u{FFFD}FAKE")
        let san = try only(Build.certificate(extensions: [Build.alternativeNames([Build.tlv(0x82, Build.text("a\u{0}b\r\nc\u{2066}"))])]))
        XCTAssertEqual(san.alternativeNames.first?.value, "a\u{FFFD}b\u{FFFD}\u{FFFD}c\u{FFFD}")
        XCTAssertEqual(try only(Build.certificate(subject: Build.name(Build.text("東京 ✨ Café")))).title, "東京 ✨ Café", "Ordinary Unicode is left alone")
        XCTAssertEqual(try only(Build.certificate(subject: Build.name(Build.text("x"), type: [0x2A, 0x03]))).subject.attributes,
                       [.init(name: "1.2.3", value: "x")], "An unknown attribute shows its identifier")
    }

    func testOlderStringEncodingsAreDecoded() throws {
        func title(_ tag: UInt8, _ bytes: [UInt8]) throws -> String { try only(Build.certificate(subject: Build.name(tag: tag, bytes))).title }
        XCTAssertEqual(try title(0x13, Build.text("Printable")), "Printable")
        XCTAssertEqual(try title(0x14, [0x43, 0x61, 0x66, 0xE9]), "Café", "T61 is read as Latin-1, as other tools do")
        XCTAssertEqual(try title(0x1E, [0x00, 0x43, 0x65, 0xE5]), "C\u{65E5}", "BMP is UTF-16")
        XCTAssertEqual(try title(0x1E, [0x00, 0x43, 0x65]), "C", "An odd byte is dropped")
        XCTAssertEqual(try title(0x1C, [0, 0, 0, 0x43, 0, 1, 0xF3, 0x0D]), "C🌍", "Universal is UTF-32")
        XCTAssertEqual(try title(0x1C, [0xFF, 0xFF, 0xFF, 0xFF]), "\u{FFFD}")
        XCTAssertEqual(try title(0x0C, [0xC3, 0x28]), "\u{FFFD}(", "Invalid UTF-8 is repaired, not rejected")
        XCTAssertEqual(try title(0x02, [0x01]), "Unreadable value")
    }

    // MARK: Off the caller

    func testSummarizingRunsAwayFromTheCallerAndObeysCancellation() async throws {
        let result = try await CertificatePreview.summarize(Data(DemoCertificates.issuer.utf8))
        guard case .contents(let contents) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(contents.certificates.count, 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CertificatePreview.summarize(Data(DemoCertificates.issuer.utf8))
        }
        do { _ = try await task.value; XCTFail("A cancelled caller gets no result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSavedFileIsReadWithinTheLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let small = directory.appendingPathComponent("chain.pem"), large = directory.appendingPathComponent("large.pem")
        try Data(DemoCertificates.issuer.utf8).write(to: small)
        try Data(count: CertificatePreview.maximumFileBytes + 10).write(to: large)
        guard case .contents(let contents) = try await CertificatePreview.summarize(fileAt: small) else { return XCTFail("Expected contents") }
        XCTAssertEqual(contents.certificates.count, 1)
        let tooLarge = try await CertificatePreview.summarize(fileAt: large)
        XCTAssertEqual(tooLarge, .tooLarge)
        do { _ = try await CertificatePreview.summarize(fileAt: directory.appendingPathComponent("missing.pem")); XCTFail("Expected an error") }
        catch { XCTAssertFalse(error is CancellationError) }
    }
}

final class CertificatePolicyTests: XCTestCase {
    private let extensions = ["pem", "crt", "cer", "der", "p7b", "p7c", "csr"]
    private let protected = ["p12", "pfx"]
    private let keyFile = Data((DemoCertificates.leaf + "\n" + Build.keyBlock()).utf8)

    func testKindsComeFromTheExtensionAndHiddenFilesAreNotText() {
        for ext in extensions {
            XCTAssertEqual(DocumentPolicy.kind(filename: "server.\(ext)"), .certificate, ext)
            XCTAssertEqual(DocumentPolicy.kind(filename: "SERVER.\(ext.uppercased())"), .certificate, ext)
            XCTAssertEqual(DocumentPolicy.kind(filename: ".hidden.\(ext)"), .certificate, "A dotfile is not a text candidate: \(ext)")
            XCTAssertEqual(DocumentPolicy.kind(filename: "/etc/ssl/server.\(ext)"), .certificate, ext)
            XCTAssertEqual(DocumentPolicy.kind(filename: ext), .plainText, "A file only named \(ext) has no extension")
        }
        for ext in protected {
            XCTAssertEqual(DocumentPolicy.kind(filename: "identity.\(ext)"), .protectedCertificate, ext)
            XCTAssertEqual(DocumentPolicy.kind(filename: ".identity.\(ext)"), .protectedCertificate, ext)
        }
        XCTAssertEqual(DocumentPolicy.kind(filename: "server.key"), .unsupported, "Key files stay as they were")
        XCTAssertEqual(DocumentPolicy.kind(filename: "server.pem.bak"), .unsupported)
        XCTAssertTrue(DocumentKind.certificate.isCertificateFile); XCTAssertTrue(DocumentKind.protectedCertificate.isCertificateFile)
        XCTAssertFalse(DocumentKind.plainText.isCertificateFile); XCTAssertFalse(DocumentKind.unsupported.isCertificateFile)
    }

    func testNoTextRouteExistsForTheseFiles() {
        for ext in extensions + protected {
            let name = "server.\(ext)"
            XCTAssertEqual(DocumentPolicy.decode(keyFile, filename: name), .unsupportedFileType, name)
            XCTAssertEqual(DocumentPolicy.decode(keyFile, filename: "." + name), .unsupportedFileType, name)
        }
    }

    func testContentSearchNeverExtractsFromTheseFiles() async throws {
        let everything = SearchExtractionOptions(includePDF: true, includeOCR: true)
        for ext in extensions + protected {
            for name in ["server.\(ext)", ".server.\(ext)"] {
                XCTAssertFalse(SearchDocumentExtractor.supports(filename: name, options: everything), name)
                XCTAssertFalse(SearchDocumentExtractor.supports(filename: name, options: .init()), name)
                do {
                    _ = try await SearchDocumentExtractor.extract(keyFile, filename: name, options: everything, deadline: .now + .seconds(5))
                    XCTFail("Extracted text from \(name)")
                } catch { XCTAssertEqual(error as? SearchExtractionError, .unsupported, name) }
            }
            XCTAssertTrue(DocumentPolicy.searchExcludedExtensions.contains(ext), "The server's helper needs this for a hidden \(ext) file")
            XCTAssertFalse(DocumentPolicy.searchTextExtensions.contains(ext), ext)
        }
    }

    func testDocumentLinksMayOpenTheSummaryButKeyFilesStayRefused() throws {
        let path = try RemoteDocumentLinkPath.resolve("chain.pem", relativeTo: "/root/docs/notes.md", connectionRoot: "/root")
        XCTAssertEqual(path, "/root/docs/chain.pem")
        XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve("../../outside.pem", relativeTo: "/root/docs/notes.md", connectionRoot: "/root"))
        XCTAssertThrowsError(try RemoteDocumentLinkPath.resolve("server.key", relativeTo: "/root/docs/notes.md", connectionRoot: "/root")) {
            XCTAssertEqual($0 as? RemoteDocumentLinkError, .unsupportedFile)
        }
    }

    func testDemoFolderHasEachKindOfSampleAndItsPlaceholderIsNotAKey() async throws {
        let demo = DemoRemoteFileService(delayNanoseconds: 0)
        let profile = ConnectionProfile(name: "Demo", host: "demo", username: "reader", identityID: UUID())
        let root = try await demo.listDirectory(profile: profile, path: "/Projects")
        XCTAssertEqual(root.entries.filter { $0.kind == .directory }.last?.name, "TLS certificates")
        let folder = try await demo.resolveEntry(profile: profile, path: DemoCertificates.folder)
        XCTAssertEqual(folder.kind, .directory)
        let listing = try await demo.listDirectory(profile: profile, path: DemoCertificates.folder)
        XCTAssertEqual(listing.entries.map(\.name), DemoCertificates.names)
        var seen: [String: CertificatePreviewResult] = [:]
        for entry in listing.entries {
            let bytes = try await demo.readFile(profile: profile, path: entry.path, limit: CertificatePreview.maximumFileBytes)
            XCTAssertEqual(entry.size, UInt64(bytes.count), entry.name)
            seen[entry.name] = CertificatePreview.parse(bytes)
        }
        guard case .contents(let chain) = seen["Example chain.pem"], case .contents(let expired) = seen["Expired server.cer"],
              case .contents(let future) = seen["Future server.crt"], case .contents(let keyed) = seen["Server with key.pem"] else {
            return XCTFail("\(seen)")
        }
        XCTAssertEqual(chain.certificates.count, 3)
        XCTAssertEqual(chain.certificates.first?.validity(at: .now), .withinDates(endsAt: chain.certificates[0].notAfter!))
        if case .expired = expired.certificates.first?.validity(at: .now) {} else { XCTFail("The sample should have expired") }
        if case .notYetValid = future.certificates.first?.validity(at: .now) {} else { XCTFail("The sample should be in the future") }
        XCTAssertEqual(keyed.privateKeys, 1); XCTAssertEqual(keyed.certificates.count, 1)
        XCTAssertEqual(Data(base64Encoded: DemoCertificates.placeholderKeyBlock.split(separator: "\n")[1].description),
                       Data("This is not a real private key.".utf8))
    }
}
