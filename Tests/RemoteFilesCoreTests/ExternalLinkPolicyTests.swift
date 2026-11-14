import XCTest
import Foundation
@testable import RemoteFilesCore

final class ExternalLinkPolicyTests: XCTestCase {
    private func needs(_ destination: String, _ text: String?) throws -> Bool {
        ExternalLinkPolicy.needsConfirmation(try XCTUnwrap(URL(string: destination)), visibleText: text)
    }

    func testALinkWhoseTextShowsAnotherHostIsConfirmed() throws {
        for text in ["https://bank.example", "https://bank.example/login", "Sign in at bank.example today", "www.bank.example",
                     "BANK.EXAMPLE", "bank.example.evil.example.org", "b\u{430}nk.example", "evil.example.attacker.test"] {
            XCTAssertTrue(try needs("https://evil.example/login", text), text)
        }
        XCTAssertTrue(try needs("https://example.com/", "sub.example.com"), "A different host of the same site is still a different host")
        XCTAssertTrue(try needs("https://xn--bnk-7cd.example/", "bank.example"), "A lookalike name is not the name shown")
    }

    func testOrdinaryLinksOpenWithoutAsking() throws {
        for text in ["Documentation", "here", "", "the release notes (2.1)", "README.md", "config.yaml and notes.txt",
                     "example.com", "https://example.com/guide", "www.example.com", "Example.COM/Guide", "mail me@example.com", "v1.2.3"] {
            XCTAssertFalse(try needs("https://example.com/guide", text), text)
        }
        XCTAssertFalse(try needs("https://www.example.com/", "example.com"), "With or without www is the same site to a reader")
        XCTAssertFalse(try needs("https://example.com/", nil), "No text to compare, as for a link around an image")
    }

    func testPlainHTTPIsAlwaysConfirmed() throws {
        XCTAssertTrue(try needs("http://example.com/", "example.com"))
        XCTAssertTrue(try needs("http://example.com/", nil))
        XCTAssertTrue(try needs("HTTP://192.168.1.10/admin", "router"))
        let destination = ExternalLinkPolicy.destination(of: try XCTUnwrap(URL(string: "http://example.com/" + String(repeating: "a", count: 500))))
        XCTAssertEqual(destination.host, "example.com")
        XCTAssertTrue(destination.isUnencrypted)
        XCTAssertEqual(destination.address.count, 301, "Clipped for the dialog")
        XCTAssertFalse(ExternalLinkPolicy.destination(of: try XCTUnwrap(URL(string: "https://example.com/"))).isUnencrypted)
    }

    func testMarkdownLinksAreJudgedByTheTextTheyAreShownWith() throws {
        let parts = try DocumentPolicy.remoteMarkdownParts("""
        [https://bank.example](https://evil.example/) and [**bank**.example/login](https://evil.example/two)

        [Docs](https://example.com/docs) [example.com](https://example.com/) [Old site](http://example.com/old)

        [Guide](Guide.md) ![image](picture.png) [bank.example](other.md)
        """)
        XCTAssertEqual(ExternalLinkPolicy.linksNeedingConfirmation(in: parts).map(\.absoluteString).sorted(),
                       ["http://example.com/old", "https://evil.example/", "https://evil.example/two"])
    }
}
