import XCTest
@testable import RemoteFilesCore

final class TextDirectionOverridesTests: XCTestCase {
    func testOrdinaryTextHasNone() {
        XCTAssertEqual(TextDirectionOverrides.count(in: ""), 0)
        XCTAssertEqual(TextDirectionOverrides.count(in: "let total = price * 2 // é 東京 🙂 — “quoted”"), 0)
    }

    /// The marks are ordinary in right-to-left text and reorder nothing beyond their own position.
    func testRightToLeftTextAndItsMarksAreNotCounted() {
        XCTAssertEqual(TextDirectionOverrides.count(in: "שלום\u{200F} world\u{200E} مرحبا\u{061C}"), 0)
    }

    func testEachEmbeddingOverrideAndIsolateIsCountedOnceAndItsClosingCharacterIsNot() {
        for opening in ["\u{202A}", "\u{202B}", "\u{202D}", "\u{202E}"] {
            XCTAssertEqual(TextDirectionOverrides.count(in: "a\(opening)b\u{202C}c"), 1, "U+\(String(opening.unicodeScalars.first!.value, radix: 16))")
        }
        for opening in ["\u{2066}", "\u{2067}", "\u{2068}"] {
            XCTAssertEqual(TextDirectionOverrides.count(in: "a\(opening)b\u{2069}c"), 1, "U+\(String(opening.unicodeScalars.first!.value, radix: 16))")
        }
        XCTAssertEqual(TextDirectionOverrides.count(in: "\u{202C}\u{2069}"), 0)
    }

    /// The shape of the published attack: a comment that hides an early return.
    func testACommentThatHidesCodeIsCounted() {
        let line = "if isAdmin { /* \u{202E} } \u{2066}begin admins only */ grant() \u{2069} \u{2066}"
        XCTAssertEqual(TextDirectionOverrides.count(in: line), 3)
    }

    /// Characters that share the first two bytes of their encoding, and bytes split across characters.
    func testNeighbouringCharactersAreNotMistakenForThem() {
        XCTAssertEqual(TextDirectionOverrides.count(in: "\u{2028}\u{2029}\u{202F}\u{2060}\u{2065}\u{206A}\u{20AA}\u{2AAA}"), 0)
        XCTAssertEqual(TextDirectionOverrides.count(in: "\u{E2}\u{80}\u{AA}"), 0, "Three Latin-1 letters, not one character")
    }

    func testAtTheEndsOfTheText() {
        XCTAssertEqual(TextDirectionOverrides.count(in: "\u{202E}"), 1)
        XCTAssertEqual(TextDirectionOverrides.count(in: "\u{202E}x\u{2067}"), 2)
    }
}
