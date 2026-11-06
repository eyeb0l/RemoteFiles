import Foundation

/// Synthetic certificates for Explore Demo and the tests: "RemoteFiles Demo" names no real
/// organization, `example.test` is a reserved domain, and no private key for them was kept.
public enum DemoCertificates {
    public static let folder = "/Projects/TLS certificates"
    static let names = ["Example chain.pem", "Expired server.cer", "Future server.crt", "Server with key.pem", "Client identity.p12"]

    static let leaf = """
    -----BEGIN CERTIFICATE-----
    MIIDQDCCAuWgAwIBAgIJAMD/7gEjRWeJMAoGCCqGSM49BAMDMFgxGTAXBgNVBAoM
    EFJlbW90ZUZpbGVzIERlbW8xFTATBgNVBAsMDENlcnRpZmljYXRlczEkMCIGA1UE
    AwwbUmVtb3RlRmlsZXMgRGVtbyBJc3N1aW5nIENBMB4XDTI2MDEwMTAwMDAwMFoX
    DTQ2MDEwMTAwMDAwMFowaDELMAkGA1UEBhMCR0IxDzANBgNVBAgMBkFudHJpbTEQ
    MA4GA1UEBwwHQmVsZmFzdDEZMBcGA1UECgwQUmVtb3RlRmlsZXMgRGVtbzEbMBkG
    A1UEAwwSZmlsZXMuZXhhbXBsZS50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A
    MIIBCgKCAQEAoWnHEJHnWetAyG/N7Tgo6dHd/yP1jKtWQGuPs3xdeS1hXwrHXZoM
    CGjMRPQWREJb3SYX20xYONsuYXu3YzyIgv/PK9Qh7z+AeSEv32ofr0Sd0Bgzya4G
    XuyJgK/zoeYyIXP5wb3XvDB1j3Yyg2e33cE6CP05OvEpwzVhc9bJcVkmlH5AYcUj
    Tr5Cvc3mIi5AHa7y5ZBsIfgcy2pWXMjc5rAHxFnXJ5ZqRCmec2PcixLV6bL0eq1L
    Wkr3heLR/drcbvWRv38IbnYf4DK+6W4pb+EACZWZJmgoZZp0piAJVDa5sHx76mfl
    zt9I1WkLQUkkJ8WaDDu34O2jrwL5QfLeBQIDAQABo4G8MIG5MAwGA1UdEwEB/wQC
    MAAwDgYDVR0PAQH/BAQDAgWgMB0GA1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcD
    AjB6BgNVHREEczBxghJmaWxlcy5leGFtcGxlLnRlc3SCFCouZmlsZXMuZXhhbXBs
    ZS50ZXN0hwTAAAIKhxAgAQ24AAAAAAAAAAAAAAAQgRBvcHNAZXhhbXBsZS50ZXN0
    hhtodHRwczovL2ZpbGVzLmV4YW1wbGUudGVzdC8wCgYIKoZIzj0EAwMDSQAwRgIh
    AI0dnVlPxeM1+1pRXiyKPbRckB4J2KgXEsyB9+vhKv9QAiEAoRBKLf8timEMxkVR
    7FWxagQUhPNvC6c7Ts7ONdSBL6c=
    -----END CERTIFICATE-----
    """

    static let issuer = """
    -----BEGIN CERTIFICATE-----
    MIIBmjCCAUygAwIBAgICEjQwBQYDK2VwMDsxGTAXBgNVBAoMEFJlbW90ZUZpbGVz
    IERlbW8xHjAcBgNVBAMMFVJlbW90ZUZpbGVzIERlbW8gUm9vdDAgFw0yNjAxMDEw
    MDAwMDBaGA8yMDUxMDEwMTAwMDAwMFowWDEZMBcGA1UECgwQUmVtb3RlRmlsZXMg
    RGVtbzEVMBMGA1UECwwMQ2VydGlmaWNhdGVzMSQwIgYDVQQDDBtSZW1vdGVGaWxl
    cyBEZW1vIElzc3VpbmcgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQYUG4d
    F2whaUzucRDp1I+Q5TUGV5hFZPG0OE0sTNSJGJW/+VIppp5gD2FcQ0jxArKkgwWv
    opFyqsSuhcdfcX9boyYwJDASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQE
    AwIBBjAFBgMrZXADQQAHLwABRv2hqo9xibfC8XwYfi6Y1zE+y6RoOEIzROrNPray
    GoyWvknLK1zsfKJB+NRBhp8UNpbRy+t1d9Hyg8cJ
    -----END CERTIFICATE-----
    """

    static let root = """
    -----BEGIN CERTIFICATE-----
    MIIBSTCB/KADAgECAgEBMAUGAytlcDA7MRkwFwYDVQQKDBBSZW1vdGVGaWxlcyBE
    ZW1vMR4wHAYDVQQDDBVSZW1vdGVGaWxlcyBEZW1vIFJvb3QwIBcNMjYwMTAxMDAw
    MDAwWhgPMjA1NjAxMDEwMDAwMDBaMDsxGTAXBgNVBAoMEFJlbW90ZUZpbGVzIERl
    bW8xHjAcBgNVBAMMFVJlbW90ZUZpbGVzIERlbW8gUm9vdDAqMAUGAytlcAMhACij
    ecll5nZQNc3eZ6RPXuf120N+U8T8HEwMlde87JVaoyMwITAPBgNVHRMBAf8EBTAD
    AQH/MA4GA1UdDwEB/wQEAwIBBjAFBgMrZXADQQCVzllVAhBQ6hlKbva6k+tw59id
    xWXa31v0j1PVrUNWZxNzjCO0BHtuAtkup/Ix1C9BS7iSBCBSeuTG3GEuNAkB
    -----END CERTIFICATE-----
    """

    static let future = """
    -----BEGIN CERTIFICATE-----
    MIIB6zCCAUygAwIBAgIBKzAKBggqhkjOPQQDBDA5MRkwFwYDVQQKDBBSZW1vdGVG
    aWxlcyBEZW1vMRwwGgYDVQQDDBNmdXR1cmUuZXhhbXBsZS50ZXN0MCIYDzIwNjAw
    MTAxMDAwMDAwWhgPMjA3MDAxMDEwMDAwMDBaMDkxGTAXBgNVBAoMEFJlbW90ZUZp
    bGVzIERlbW8xHDAaBgNVBAMME2Z1dHVyZS5leGFtcGxlLnRlc3QwgZswEAYHKoZI
    zj0CAQYFK4EEACMDgYYABAGjMncn6Hoi/5lJNkwmCqoCspv9BV+ZyFlZRKipY/4e
    7HB6hNRg3kJMPa49pP6UKGAhb/JgfWOHcIKBF1Pjge8UAgF4L8ZG7/5TnitSWI+r
    oWjSyLaojUkQ+vXcNC7qagm8fPn7gd4Opi71htqtZsTQWYnq2p0PM3nIUZYTPKWU
    ASQ8+TAKBggqhkjOPQQDBAOBjAAwgYgCQgGvSOvqYb9bF47etnc+UACz8z2uXNwV
    xL62PRqXUxjW4PWspPgfN23shaU9/+lEubxIYT0En69mX1r4ahSsCZq8dAJCASVI
    +jA2EIjhAxia4aTmwoFMPK1pTPYPFbzl65k3exZkOqr9NGRRf7RouwVL0mf91H+A
    soJh1KC1jb7AVJzWcQUO
    -----END CERTIFICATE-----
    """

    /// The DER bytes of a certificate whose dates ended in 2021, as base64.
    static let expiredBase64 = "MIIBwzCCAUmgAwIBAgIBKjAKBggqhkjOPQQDAzA6MRkwFwYDVQQKDBBSZW1vdGVGaWxlcyBEZW1vMR0wGwYDVQQDDBRleHBpcmVkLmV4YW1wbGUudGVzdDAeFw0yMDAxMDEwMDAwMDBaFw0yMTAxMDEwMDAwMDBaMDoxGTAXBgNVBAoMEFJlbW90ZUZpbGVzIERlbW8xHTAbBgNVBAMMFGV4cGlyZWQuZXhhbXBsZS50ZXN0MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEc5qGfjAnByek1+kb/Xly0w8jlSdlwWkab4MlGmhKwrXbTzJQpTKpVaa61V73CkdMmpvCzUCA82T9sQXGD/4zXGVJbUUQPqhwrobs1FRU+a8/gsm8L2PzAXzHUzZaTXc4oyMwITAfBgNVHREEGDAWghRleHBpcmVkLmV4YW1wbGUudGVzdDAKBggqhkjOPQQDAwNoADBlAjBz5pvo0nqqbQihVmvwehBwB/QLYNswRDiP+EQgsMuWYvFgfPFsH5JIWmEXtnAD+JwCMQDNb+DXBO2ZcPJRtFnhf4moSycF+YJYbxo/zMWTvDPZ0QHfXNYqn9qUvFoWJoT4TMI="

    /// Not a key: its body is the base64 of a sentence. The marker is built up so that secret
    /// scanners don't flag this file, and shows the preview's handling of a real key's block.
    static let placeholderKeyBlock = "-----BEGIN " + "PRIVATE" + " KEY-----\n"
        + Data("This is not a real private key.".utf8).base64EncodedString() + "\n-----END " + "PRIVATE" + " KEY-----\n"

    public static func entry(named name: String) -> RemoteEntry {
        RemoteEntry(name: name, path: folder + "/" + name, kind: .file, size: UInt64(contents(of: name)?.count ?? 0))
    }

    static func contents(of name: String) -> Data? {
        switch name {
        case "Example chain.pem": return Data([leaf, issuer, root].joined(separator: "\n").utf8)
        case "Expired server.cer": return Data(base64Encoded: expiredBase64)
        case "Future server.crt": return Data(future.utf8)
        case "Server with key.pem": return Data((leaf + "\n" + placeholderKeyBlock).utf8)
        // Random-looking bytes standing in for a container nothing here opens.
        case "Client identity.p12": return Data((0..<1_024).map { UInt8(truncatingIfNeeded: $0 &* 197 &+ 13) })
        default: return nil
        }
    }
}
