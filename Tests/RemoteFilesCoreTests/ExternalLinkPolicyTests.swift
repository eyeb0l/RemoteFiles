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
        // The address shown is bank.example's; the destination appearing in its query does not make it honest.
        XCTAssertTrue(try needs("https://evil.example/", "https://bank.example/redirect?next=https://evil.example/"))
        XCTAssertTrue(try needs("https://evil.example/", "bank.example/go?to=evil.example"))
        XCTAssertTrue(try needs("https://evil.example/", "evil.example and bank.example"), "Every address shown has to be the destination's")
        // An address written with its scheme is read as one, whatever its host looks like.
        for text in ["https://192.168.1.1/admin", "https://bank.xn--p1ai/", "https://[2001:db8::1]/login", "(see https://bank.example)."] {
            XCTAssertTrue(try needs("https://evil.example/", text), text)
        }
        XCTAssertTrue(try needs("https://xn--bnk-7cd.example/", "bank.example"), "A lookalike name is not the name shown")
    }

    func testOrdinaryLinksOpenWithoutAsking() throws {
        for text in ["Documentation", "here", "", "the release notes (2.1)", "README.md", "config.yaml and notes.txt",
                     "example.com", "https://example.com/guide", "www.example.com", "Example.COM/Guide", "mail me@example.com", "v1.2.3"] {
            XCTAssertFalse(try needs("https://example.com/guide", text), text)
        }
        XCTAssertFalse(try needs("https://www.example.com/", "example.com"), "With or without www is the same site to a reader")
        XCTAssertFalse(try needs("https://example.com/guide", "https://example.com/?ref=other.example"), "A host inside the shown address's query is not shown as its host")
        XCTAssertFalse(try needs("https://example.com/guide", "example.com or www.example.com"))
        XCTAssertFalse(try needs("https://192.168.1.1/admin", "https://192.168.1.1/admin"))
        XCTAssertFalse(try needs("https://example.com/guide", "(see https://example.com/guide)."), "Punctuation around an address is the sentence's")
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
        let text = """
        [https://bank.example](https://evil.example/) and [**bank**.example/login](https://evil.example/two)

        [Docs](https://example.com/docs) [example.com](https://example.com/) [Old site](http://example.com/old)

        [Guide](Guide.md) ![image](picture.png) [bank.example](other.md)
        """
        let parts = try DocumentPolicy.remoteMarkdownParts(text)
        let expected = ["http://example.com/old", "https://evil.example/", "https://evil.example/two"]
        XCTAssertEqual(ExternalLinkPolicy.linksNeedingConfirmation(in: parts).map(\.absoluteString).sorted(), expected)
        // The reader takes them from its index, prepared away from the UI actor.
        XCTAssertEqual(try DocumentTextIndex(text: text, markdown: true).linksNeedingConfirmation.map(\.absoluteString).sorted(), expected)
        XCTAssertTrue(try DocumentTextIndex(text: text, markdown: false).linksNeedingConfirmation.isEmpty)
    }
}
