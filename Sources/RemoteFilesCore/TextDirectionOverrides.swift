import Foundation

/// The characters that make text display in a different order from the one it is stored in and
/// draw nothing themselves: the embeddings, overrides and isolates. In source code they can make
/// a line read as something other than what a compiler is given ("Trojan Source", CVE-2021-42574).
///
/// The left-to-right, right-to-left and Arabic letter marks are left out. They are ordinary in
/// Arabic and Hebrew text and reorder nothing beyond their own position.
public enum TextDirectionOverrides {
    /// How many embeddings, overrides and isolates `text` opens. The characters that close them
    /// (U+202C and U+2069) aren't counted, so a properly closed pair counts once.
    public static func count(in text: String) -> Int {
        // U+202A, 202B, 202D and 202E are E2 80 AA, AB, AD and AE in UTF-8; U+2066 to 2068 are
        // E2 81 A6 to A8. E2 is only ever a first byte, so three bytes in a row can't be misread.
        var count = 0
        var first: UInt8 = 0, second: UInt8 = 0
        for third in text.utf8 {
            if first == 0xE2 {
                if second == 0x80, third == 0xAA || third == 0xAB || third == 0xAD || third == 0xAE { count += 1 }
                else if second == 0x81, (0xA6...0xA8).contains(third) { count += 1 }
            }
            first = second; second = third
        }
        return count
    }
}
