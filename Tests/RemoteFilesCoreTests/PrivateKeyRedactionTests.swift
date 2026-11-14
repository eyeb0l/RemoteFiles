import XCTest
import Foundation
@testable import RemoteFilesCore

/// Synthetic keys for the tests: pseudorandom bytes in a key's clothing, which unlock nothing.
/// Markers are assembled at run time so secret scanners don't flag this file.
enum SyntheticKey {
    static let privateWord = "PRIVATE"

    static func base64(bytes count: Int = 1_190, seed: UInt32 = 7) -> String {
        var state = seed &* 2_654_435_761 | 1
        var output = [UInt8](); output.reserveCapacity(count)
        for _ in 0..<count {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            output.append(UInt8(truncatingIfNeeded: state))
        }
        return Data(output).base64EncodedString()
    }
    static func wrapped(_ text: String, width: Int = 64) -> [String] {
        var lines: [String] = [], rest = text[...]
        while !rest.isEmpty { lines.append(String(rest.prefix(width))); rest = rest.dropFirst(width) }
        return lines
    }
    static func begin(_ label: String) -> String { "-----BEGIN \(label) \(privateWord) KEY-----" }
    static func end(_ label: String) -> String { "-----END \(label) \(privateWord) KEY-----" }

    /// One PEM key. `label` is the words before "PRIVATE KEY".
    static func pem(_ label: String = "RSA", headers: [String] = [], seed: UInt32 = 7, bytes: Int = 1_190) -> String {
        let prefix = label.isEmpty ? "" : label + " "
        let open = "-----BEGIN \(prefix)\(privateWord) KEY-----", close = "-----END \(prefix)\(privateWord) KEY-----"
        let head = headers.isEmpty ? [] : headers + [""]
        return ([open] + head + wrapped(base64(bytes: bytes, seed: seed)) + [close]).joined(separator: "\n") + "\n"
    }
    /// A wide OpenSSH-shaped body, starting as every real one does.
    static func opensshBody(seed: UInt32 = 11) -> String {
        Data("openssh-key-v1\0".utf8).base64EncodedString().dropLast(1) + base64(bytes: 300, seed: seed)
    }
    static func openssh(seed: UInt32 = 11) -> String {
        ([begin("OPENSSH")] + wrapped(opensshBody(seed: seed), width: 70) + [end("OPENSSH")]).joined(separator: "\n") + "\n"
    }
    static func ppk(version: Int = 3) -> String {
        """
        PuTTY-User-Key-File-\(version): ssh-ed25519
        Encryption: none
        Comment: synthetic
        Public-Lines: 2
        \(wrapped(base64(bytes: 80, seed: 21)).joined(separator: "\n"))
        Private-Lines: 2
        \(wrapped(base64(bytes: 80, seed: 22)).joined(separator: "\n"))
        Private-MAC: 0123456789abcdef0123456789abcdef01234567

        """
    }

    /// Fragments of a key's text that must not survive anywhere. Each line is sampled at both ends.
    static func fragments(of key: String) -> [String] {
        var fragments: [String] = []
        for line in key.split(whereSeparator: \.isNewline).map(String.init) where !line.hasPrefix("-") && !line.contains(":") && line.count >= 16 {
            fragments.append(String(line.prefix(16)))
            fragments.append(String(line.suffix(16)))
        }
        return fragments
    }
}

final class PrivateKeyRedactionTests: XCTestCase {
    private func assertHidden(_ text: String, key: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = PrivateKeyRedaction.redact(text)
        XCTAssertGreaterThan(result.hiddenKeys, 0, "Found no key", file: file, line: line)
        // A failure's message says where, never the text, so a real key can't reach a log.
        let survivors = SyntheticKey.fragments(of: key).filter { fragment in
            result.text.contains(fragment) || result.text.contains(fragment.replacingOccurrences(of: "/", with: "\\/"))
        }
        XCTAssertEqual(survivors.count, 0, "\(survivors.count) fragments survived", file: file, line: line)
        XCTAssertEqual(result.text.utf16.count, text.utf16.count, "UTF-16 length", file: file, line: line)
        XCTAssertEqual(lineCount(result.text), lineCount(text), "Lines", file: file, line: line)
    }
    private func lineCount(_ text: String) -> Int { text.reduce(1) { $1.isNewline ? $0 + 1 : $0 } }

    func testEveryPEMLabelIsHiddenWithItsMarkersKept() {
        for label in ["", "RSA", "EC", "DSA", "ENCRYPTED", "OPENSSH", "ANY", "PGP"] {
            let key = SyntheticKey.pem(label)
            assertHidden(key, key: key)
            let result = PrivateKeyRedaction.redact(key)
            XCTAssertEqual(result.hiddenKeys, 1, label)
            XCTAssertTrue(result.isOnlyKeys, label)
            let begin = key.split(separator: "\n").first.map(String.init)!
            XCTAssertTrue(result.text.hasPrefix(begin + "\n•"), label)
        }
    }

    func testFormatsWithTheirOwnStructureAreHidden() {
        let encrypted = SyntheticKey.pem("RSA", headers: ["Proc-Type: 4,ENCRYPTED", "DEK-Info: AES-128-CBC,0123456789ABCDEF0123456789ABCDEF"])
        assertHidden(encrypted, key: encrypted)
        XCTAssertTrue(PrivateKeyRedaction.redact(encrypted).isOnlyKeys)
        let pgp = "-----BEGIN PGP \(SyntheticKey.privateWord) KEY BLOCK-----\nVersion: GnuPG v2\nComment: synthetic\n\n"
            + SyntheticKey.wrapped(SyntheticKey.base64()).joined(separator: "\n") + "\n=abcd\n-----END PGP \(SyntheticKey.privateWord) KEY BLOCK-----\n"
        assertHidden(pgp, key: pgp)
        XCTAssertTrue(PrivateKeyRedaction.redact(pgp).isOnlyKeys)
        let ssh2 = "---- BEGIN SSH2 ENCRYPTED \(SyntheticKey.privateWord) KEY ----\nComment: \"synthetic\"\n"
            + SyntheticKey.wrapped(SyntheticKey.base64()).joined(separator: "\n") + "\n---- END SSH2 ENCRYPTED \(SyntheticKey.privateWord) KEY ----\n"
        assertHidden(ssh2, key: ssh2)
        XCTAssertTrue(PrivateKeyRedaction.redact(ssh2).isOnlyKeys)
        let openssh = SyntheticKey.openssh()
        assertHidden(openssh, key: openssh)
        XCTAssertEqual(PrivateKeyRedaction.redact(openssh).hiddenKeys, 1, "Its body starts like a marker-less key, but is one key")
    }

    func testPuTTYHidesPrivateLinesAndItsCheckButNotThePublicLinesOfALongerDocument() {
        for version in 1...3 {
            let ppk = SyntheticKey.ppk(version: version)
            XCTAssertTrue(PrivateKeyRedaction.redact(ppk).isOnlyKeys)
            let result = PrivateKeyRedaction.redact("Notes on the key:\n\n" + ppk + "\nThat's all.\n")
            XCTAssertEqual(result.hiddenKeys, 1)
            XCTAssertFalse(result.isOnlyKeys)
            XCTAssertFalse(result.text.contains("0123456789abcdef"))
            let lines = ppk.split(separator: "\n").map(String.init)
            let privateStart = lines.firstIndex { $0.hasPrefix("Private-Lines") }!
            for secret in lines[(privateStart + 1)...(privateStart + 2)] { XCTAssertFalse(result.text.contains(secret)) }
            XCTAssertTrue(result.text.contains(lines[4]), "Public lines stay in a longer document")
        }
        // Cut off before its check or partway through its secret, it's still hidden.
        let lines = SyntheticKey.ppk().split(separator: "\n").map(String.init)
        let privateStart = lines.firstIndex { $0.hasPrefix("Private-Lines") }!
        for cut in [privateStart + 2, privateStart + 3] {
            let result = PrivateKeyRedaction.redact(lines[..<cut].joined(separator: "\n") + "\n")
            XCTAssertEqual(result.hiddenKeys, 1)
            XCTAssertFalse(result.text.contains(lines[privateStart + 1]))
            XCTAssertTrue(result.isOnlyKeys)
        }
        // Text after the check is the document's, however close it is.
        let followed = PrivateKeyRedaction.redact(SyntheticKey.ppk() + "Keep this safe.\n")
        XCTAssertFalse(followed.isOnlyKeys)
        XCTAssertTrue(followed.text.hasSuffix("Keep this safe.\n"))
        // A document describing the format has no secret to hide.
        let prose = "PuTTY-User-Key-File-3: is the first line.\nPrivate-Lines: 2\nsays how many lines follow, and\nthose lines hold the secret.\n"
        XCTAssertEqual(PrivateKeyRedaction.redact(prose).hiddenKeys, 0)
    }

    func testRealWorldEncodingsOfAKeyAreHidden() throws {
        for key in [SyntheticKey.pem(), SyntheticKey.openssh(), SyntheticKey.pem("", bytes: 48), SyntheticKey.pem("EC", bytes: 121)] {
            let body = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = body.split(separator: "\n").map(String.init)
            func json(_ value: String) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject: ["type": "service_account", "private_key": value, "email": "a@example.test"]), as: UTF8.self)
            }
            let cut = String(body.prefix(body.count * 2 / 3))
            let cases: [(String, String)] = [
                ("CRLF", key.replacingOccurrences(of: "\n", with: "\r\n")),
                ("CR", key.replacingOccurrences(of: "\n", with: "\r")),
                ("YAML", "key: |\n" + lines.map { "    " + $0 + "\n" }.joined() + "other: 1\n"),
                ("JSON", try json(key)),
                ("JSON in JSON", try json(try json(key))),
                ("Escaped slashes", try json(key).replacingOccurrences(of: "/", with: "\\/")),
                ("Quoted .env", "PRIVATE_KEY=\"" + body + "\"\nOTHER=1\n"),
                ("Escaped .env", "PRIVATE_KEY=\"" + body.replacingOccurrences(of: "\n", with: "\\n") + "\"\nOTHER=1\n"),
                ("Flattened", "KEY=" + body.replacingOccurrences(of: "\n", with: " ") + " trailing words here\n"),
                ("Hash comments", lines.map { "# " + $0 + "\n" }.joined()),
                ("Slash comments", lines.map { "// " + $0 + "\n" }.joined()),
                ("Quoted mail", lines.map { "> " + $0 + "\n" }.joined()),
                ("Python strings", "KEY = (\n" + lines.map { "    \"" + $0 + "\\n\"\n" }.joined() + ")\n"),
                ("Java strings", lines.map { "\"" + $0 + "\\n\" +\n" }.joined() + "\"\";\n"),
                ("Log lines", lines.map { "2026-11-06T10:00:00Z app[12]: " + $0 + "\n" }.joined()),
                ("HTML", "<p>" + body.replacingOccurrences(of: "\n", with: "<br/>") + "</p>\n"),
                ("Markdown fence", "# Notes\n\n```\n" + key + "```\n\nMore prose.\n"),
                ("Prose around it", "Rotate this.\n\n" + key + "\nThanks.\n"),
                ("Cut off at the end", cut),
                ("Cut off, then prose", cut + "\n\nThat was cut off, sorry about that everyone.\n"),
                ("Two keys", key + "\n" + SyntheticKey.pem("EC", seed: 99)),
            ]
            for (name, text) in cases {
                let result = PrivateKeyRedaction.redact(text)
                XCTAssertGreaterThan(result.hiddenKeys, 0, name)
                let isCut = name.hasPrefix("Cut")
                let survivors = SyntheticKey.fragments(of: isCut ? cut : key).filter { fragment in
                    result.text.contains(fragment) || result.text.contains(fragment.replacingOccurrences(of: "/", with: "\\/"))
                }
                XCTAssertEqual(survivors.count, 0, "\(name): \(survivors.count) fragments survived")
                XCTAssertEqual(result.text.utf16.count, text.utf16.count, name)
                XCTAssertEqual(lineCount(result.text), lineCount(text), name)
            }
        }
    }

    /// A line ending of two characters is one line ending, or a key's next line looks like the end.
    func testWindowsLineEndingsDontExposeTheRestOfAKey() throws {
        func windows(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }
        func json(_ text: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["value": text]), as: UTF8.self)
        }
        let ppk = SyntheticKey.ppk()
        let lines = ppk.split(separator: "\n").map(String.init)
        let privateStart = lines.firstIndex { $0.hasPrefix("Private-Lines") }!
        let wrapped = Data(SyntheticKey.pem().utf8).base64EncodedString()
        let folded = SyntheticKey.wrapped(wrapped, width: 76)
        let secret = "kind: Secret\ndata:\n  tls.key: |\n" + folded.map { "    " + $0 + "\n" }.joined() + "  note: kept\n"

        let raw = PrivateKeyRedaction.redact(windows(ppk))
        XCTAssertEqual(raw.hiddenKeys, 1, "A PuTTY file saved on Windows")
        XCTAssertTrue(raw.isOnlyKeys)
        let escaped = PrivateKeyRedaction.redact(try json(windows(ppk)))
        XCTAssertEqual(escaped.hiddenKeys, 1, "The same file inside a JSON string")
        for result in [raw, escaped] {
            for line in lines[(privateStart + 1)...(privateStart + 2)] { XCTAssertFalse(result.text.contains(line)) }
        }

        for (name, text) in [("Folded", windows(secret)), ("Folded in JSON", try json(windows(secret)))] {
            let result = PrivateKeyRedaction.redact(text)
            XCTAssertEqual(result.hiddenKeys, 1, name)
            for line in folded { XCTAssertFalse(result.text.contains(line), name) }
            XCTAssertTrue(result.text.contains("note: kept"), name)
            XCTAssertEqual(result.text.utf16.count, text.utf16.count, name)
        }

        // A real blank line still ends a key, so what follows it stays readable.
        let blank = windows(folded.joined(separator: "\n") + "\n\nAfterwards\n")
        XCTAssertTrue(PrivateKeyRedaction.redact(blank).text.contains("Afterwards"))
    }

    func testAWholeKeyFoldedNarrowerThanTheMinimumIsStillHidden() {
        let wrapped = Data(SyntheticKey.pem().utf8).base64EncodedString()
        let certificate = Data(DemoCertificates.leaf.utf8).base64EncodedString()
        for width in [32, 48, 64, 76] {
            let folded = SyntheticKey.wrapped(wrapped, width: width)
            let text = "data:\n  tls.key: |\n" + folded.map { "    " + $0 + "\n" }.joined() + "  note: kept\n"
            let result = PrivateKeyRedaction.redact(text)
            XCTAssertEqual(result.hiddenKeys, 1, "Folded at \(width)")
            for line in folded { XCTAssertFalse(result.text.contains(line), "Folded at \(width)") }
            XCTAssertTrue(result.text.contains("note: kept"), "Folded at \(width)")
            XCTAssertEqual(result.text.utf16.count, text.utf16.count, "Folded at \(width)")

            // A certificate wrapped the same way isn't secret, however narrow.
            let public_ = SyntheticKey.wrapped(certificate, width: width).joined(separator: "\n") + "\n"
            XCTAssertEqual(PrivateKeyRedaction.redact(public_).hiddenKeys, 0, "Certificate folded at \(width)")
        }
    }

    func testWrappedKeysAreHiddenAndACertificateBesideThemStays() throws {
        let key = SyntheticKey.pem()
        let wrapped = Data(key.utf8).base64EncodedString()
        let certificate = Data(DemoCertificates.leaf.utf8).base64EncodedString()
        let kubeconfig = "users:\n- user:\n    client-key-data: \(wrapped)\n    client-certificate-data: \(certificate)\n    token: short\n"
        let result = PrivateKeyRedaction.redact(kubeconfig)
        XCTAssertEqual(result.hiddenKeys, 1)
        XCTAssertFalse(result.isOnlyKeys)
        XCTAssertFalse(result.text.contains(wrapped.prefix(32)))
        XCTAssertTrue(result.text.contains(certificate), "A certificate isn't secret")
        XCTAssertEqual(result.text.utf16.count, kubeconfig.utf16.count)

        let folded = SyntheticKey.wrapped(wrapped, width: 76)
        let secret = "kind: Secret\ndata:\n  tls.key: |\n" + folded.map { "    " + $0 + "\n" }.joined() + "  note: kept\n"
        let hidden = PrivateKeyRedaction.redact(secret)
        XCTAssertEqual(hidden.hiddenKeys, 1)
        for line in folded { XCTAssertFalse(hidden.text.contains(line)) }
        XCTAssertTrue(hidden.text.contains("  note: kept"))

        let bare = PrivateKeyRedaction.redact(wrapped + "\n")
        XCTAssertTrue(bare.isOnlyKeys)

        let markerless = "OPENSSH_KEY=" + SyntheticKey.opensshBody() + "\nOTHER=1\n"
        let body = PrivateKeyRedaction.redact(markerless)
        XCTAssertEqual(body.hiddenKeys, 1)
        XCTAssertFalse(body.text.contains(SyntheticKey.opensshBody().prefix(32)))
        XCTAssertTrue(body.text.hasSuffix("\nOTHER=1\n"))

        // A certificate on its own, and too little to be a key, stay as they are.
        for text in ["client-certificate-data: \(certificate)\n", "prefix: " + wrapped.prefix(30) + "\n"] {
            XCTAssertEqual(PrivateKeyRedaction.redact(text).hiddenKeys, 0)
        }
    }

    /// The text that a refusal on a bare marker would have made unreadable, including this repository's own.
    func testMentionsOfMarkersHideNothing() {
        let word = SyntheticKey.privateWord
        let begin = "-----BEGIN OPENSSH \(word) KEY-----", end = "-----END OPENSSH \(word) KEY-----"
        let pemBegin = "-----BEGIN \(word) KEY-----", pemEnd = "-----END \(word) KEY-----"
        let cases: [(String, String)] = [
            ("Source constants", "let begin = \"\(begin)\", end = \"\(end)\"\nguard text.hasPrefix(begin) else { return }\n"),
            ("Source concatenation", "return \"\(begin)\\n\" + data.base64EncodedString() + \"\\n\(end)\\n\"\n"),
            ("Source appending", "var string = \"\(begin)\\n\"\nstring += base64\nstring += \"\\n\"\nstring += \"\(end)\\n\"\nreturn string\n"),
            ("Prefix check", "guard key.hasPrefix(\"\(begin)\") else { throw InvalidKey() }\nkey.removeFirst(\"\(begin)\".utf8.count)\n"),
            ("Bad value test", "for value in [\"\", \"not a key\", \"\(begin)\\nabc\\n\(end)\"] { XCTAssertThrowsError(try parse(value)) }\n"),
            ("Ellipsis", "\(pemBegin)\nMIIE...\n...\n\(pemEnd)\n"),
            ("Both ends", "\(pemBegin)\nMIICdg....\n... bhTQ==\n\(pemEnd)\n"),
            ("Placeholder", "\(pemBegin)\n<your key here>\n\(pemEnd)\n"),
            ("Saying so", "\(pemBegin)\nkey omitted for security reasons\n\(pemEnd)\n"),
            ("Crosses", "\"\(pemBegin)\\nXXXX\\nXXXX\\nXXXX\\n\(pemEnd)\"\n"),
            ("Regular expression", "re.compile(r'-----BEGIN [A-Z0-9 ]*\(word) KEY-----.*?(?:-----END [A-Z0-9 ]*\(word) KEY-----|\\Z)')\n"),
            ("Prose", "A key starts with \(pemBegin) and\nends with \(pemEnd), as the manual explains.\n"),
            ("A long identifier follows", "let marker = \"\(pemBegin)\"\nfunc doSomethingVeryLongAndDescriptive(parameterWithLongName: Int) {}\n"),
            ("Between two markers", "let a = \"\(pemBegin)\"\nfunc doSomethingVeryLongAndDescriptive(parameterWithLongName: Int) {}\nlet b = \"\(pemEnd)\"\n"),
            ("Certificate", DemoCertificates.issuer),
            ("Public key", "-----BEGIN PUBLIC KEY-----\n" + SyntheticKey.wrapped(SyntheticKey.base64(bytes: 200)).joined(separator: "\n") + "\n-----END PUBLIC KEY-----\n"),
            ("Words", "Rotate the \(word) KEY often, and PuTTY-User-Key-File-3: explains why.\n"),
        ]
        for (name, text) in cases {
            let result = PrivateKeyRedaction.redact(text)
            XCTAssertEqual(result.hiddenKeys, 0, name)
            XCTAssertEqual(result.text, text, name)
        }
    }

    func testOnlyKeysMeansNothingElseIsInTheFile() {
        let key = SyntheticKey.pem(), other = SyntheticKey.pem("EC", seed: 3)
        for text in [key, "\n\n" + key + "\n", key + other, "\"" + key + "\"", key.replacingOccurrences(of: "\n", with: "\r\n")] {
            XCTAssertTrue(PrivateKeyRedaction.redact(text).isOnlyKeys)
        }
        for text in ["# my key\n" + key, key + "\nsee also the wiki\n", DemoCertificates.leaf + "\n" + key] {
            let result = PrivateKeyRedaction.redact(text)
            XCTAssertEqual(result.hiddenKeys, 1)
            XCTAssertFalse(result.isOnlyKeys)
        }
    }

    func testHidingKeepsEveryOffsetAndLineAndCanBeRepeated() {
        let before = "first line\n日本語 ✨ 𝒳\n\n", after = "\n\nafter 日本語 ✨ needle\nlast line\n"
        let text = before + SyntheticKey.pem() + after
        let result = PrivateKeyRedaction.redact(text)
        XCTAssertEqual(result.hiddenKeys, 1)
        let original = text as NSString, hidden = result.text as NSString
        XCTAssertEqual(hidden.length, original.length)
        XCTAssertEqual(hidden.range(of: "needle"), original.range(of: "needle"))
        XCTAssertEqual(hidden.range(of: "last line"), original.range(of: "last line"))
        XCTAssertTrue(result.text.hasPrefix(before)); XCTAssertTrue(result.text.hasSuffix(after))
        // A saved index can hold text that was hidden before, and is read through this again.
        let again = PrivateKeyRedaction.redact(result.text)
        XCTAssertEqual(again.text, result.text)
        XCTAssertEqual(again.hiddenKeys, 0)
    }

    func testTextWithoutAKeyIsReturnedUntouched() {
        for text in ["", "plain", "• already has dots •", "日本語\r\n", String(repeating: "LS0tLS1CRUdJTi", count: 2)] {
            let result = PrivateKeyRedaction.redact(text)
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.hiddenKeys, 0)
            XCTAssertFalse(result.isOnlyKeys)
        }
    }

    /// A log line can be mostly prefix. The key is at the end of each, and only it is hidden.
    func testAKeyUnderALongLogPrefixIsHiddenAndThePrefixStays() throws {
        let key = SyntheticKey.pem(bytes: 500)
        let prefix = "2026-11-13T10:00:00.000Z gateway-7f9c4d5b6-x2k8q deploy[4821]: info     "
        XCTAssertGreaterThan(prefix.utf8.count, 64, "Longer than the key text beside it")
        let logged = key.split(separator: "\n").map { prefix + $0 }.joined(separator: "\n") + "\n" + prefix + "done\n"
        assertHidden(logged, key: key)
        let result = PrivateKeyRedaction.redact(logged)
        XCTAssertEqual(result.hiddenKeys, 1)
        let hidden = result.text.split(separator: "\n").filter { $0.contains("•••••") }
        XCTAssertEqual(hidden.count, key.split(separator: "\n").count - 2, "Every line of the key's body")
        XCTAssertTrue(hidden.allSatisfy { $0.hasPrefix(prefix) }, "The prefix beside the key is still readable")
        // The last line of a key is short, and is found by where the lines above it began.
        let last = try XCTUnwrap(key.split(separator: "\n").dropLast().last)
        XCTAssertLessThan(last.count, 40)
        XCTAssertFalse(result.text.contains(last))
        XCTAssertTrue(result.text.hasSuffix(prefix + "done\n"))
        // A sentence under the same prefix, between the markers, is not a key.
        let prose = [SyntheticKey.begin("RSA"), "the key was removed from this report on request", SyntheticKey.end("RSA")]
            .map { prefix + $0 }.joined(separator: "\n")
        XCTAssertEqual(PrivateKeyRedaction.redact(prose).hiddenKeys, 0)
    }

    func testPGPSecretKeyBlocksAndLabelsInOtherCasesAreHidden() {
        let body = SyntheticKey.wrapped(SyntheticKey.base64(bytes: 400, seed: 31))
        let pgp = (["-----BEGIN PGP SECRET KEY BLOCK-----", "Version: Synthetic 1", ""] + body
                   + ["=AbCd", "-----END PGP SECRET KEY BLOCK-----"]).joined(separator: "\n") + "\n"
        assertHidden("Backup of the signing key:\n\n" + pgp, key: pgp)
        XCTAssertTrue(PrivateKeyRedaction.redact(pgp).isOnlyKeys)
        XCTAssertEqual(PrivateKeyRedaction.redact("-----BEGIN PGP PUBLIC KEY BLOCK-----\n" + body.joined(separator: "\n")
                                                   + "\n-----END PGP PUBLIC KEY BLOCK-----\n").hiddenKeys, 0)
        for label in ["rsa private key", "Rsa Private Key", "pgp secret key block"] {
            let lower = (["-----BEGIN \(label)-----"] + body + ["-----END \(label)-----"]).joined(separator: "\n") + "\n"
            assertHidden(lower, key: lower)
        }
        XCTAssertEqual(PrivateKeyRedaction.redact("Keep the private key and the secret key in the Keychain.").hiddenKeys, 0)
    }

    /// Each accepted candidate once read to the end of its line, so a megabyte of them on one
    /// line took most of a minute. Only the candidate's own run is read now.
    func testAcceptedCandidatesOnOneLongLineAreEachReadOnce() {
        let candidate = SyntheticKey.opensshBody()
        let unit = candidate + " "
        let text = String(repeating: unit, count: DocumentPolicy.previewByteLimit / unit.utf8.count)
        let started = ContinuousClock.now
        let result = PrivateKeyRedaction.redact(text)
        // Quadratic work took 90 seconds for this much on a Mac; linear work takes a fraction of one.
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(20))
        XCTAssertEqual(result.hiddenKeys, text.utf8.count / unit.utf8.count, "Every candidate is still hidden")
        XCTAssertFalse(result.text.contains(candidate.prefix(24)))
        XCTAssertEqual(result.text.utf16.count, text.utf16.count)
    }

    /// Only a run that ends its line wraps onto the next, however the line ends.
    func testAWrappedKeyStillContinuesOntoItsNextLines() {
        let lines = SyntheticKey.wrapped(SyntheticKey.opensshBody(), width: 70)
        XCTAssertGreaterThan(lines.count, 3)
        for text in [lines.joined(separator: "\n") + "\n", lines.joined(separator: "\r\n") + "\r\n",
                     "key = \"" + lines.joined(separator: "\\n") + "\"\n",
                     lines.map { "  \"" + $0 + "\"," }.joined(separator: "\n") + "\n"] {
            let result = PrivateKeyRedaction.redact(text)
            XCTAssertEqual(result.hiddenKeys, 1)
            for line in lines { XCTAssertFalse(result.text.contains(line.suffix(12)), "A later line of the key survived") }
        }
    }

    func testHostileInputStaysLinearAtThePreviewLimit() {
        let limit = DocumentPolicy.previewByteLimit
        let begin = SyntheticKey.begin("RSA") + "\n", end = SyntheticKey.end("RSA") + "\n"
        func fill(_ unit: String) -> String { String(repeating: unit, count: limit / unit.utf8.count) }
        let hostile = [
            fill(begin),
            fill(begin + end),
            fill("PuTTY-User-Key-File-3: x\n"),
            fill("PuTTY-User-Key-File-3: x\nPrivate-Lines: 1024\n"),
            fill(Data("-----BEGIN ".utf8).base64EncodedString().dropLast(2) + " "),
            // Every candidate is in one run, so each mustn't scan it afresh.
            fill(Data("-----BEGIN ".utf8).base64EncodedString()),
            // Short candidates that each look ahead at their next lines.
            fill(Data("-----BEGIN ".utf8).base64EncodedString() + String(repeating: "A", count: 24) + "\n"),
            fill(Data("-----BEGIN ".utf8).base64EncodedString() + String(repeating: "A", count: 24) + " "),
            fill("---- BEGIN SSH2 "),
            begin + fill("\\"),
            begin + fill(" "),
            begin + String(repeating: "A", count: limit - begin.utf8.count),
        ]
        for text in hostile {
            let started = ContinuousClock.now
            _ = PrivateKeyRedaction.redact(text)
            // A generous bound: quadratic work on 2 MiB would take hours, not seconds.
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(60))
        }
    }
}

final class PrivateKeyRouteTests: XCTestCase {
    private let key = SyntheticKey.pem()
    private var mixed: String { "Rotate on the first.\n\n" + key + "\nneedle after the key\n" }

    func testKeyFilesThatWereTextCandidatesHaveNoTextRoute() {
        for name in ["id_rsa", "id_ed25519", ".server.key", "server.pem.txt", "dump.log", "key.txt", "notes.md", "page.html", "icon.svg", "config.yaml"] {
            let preview = DocumentPolicy.decode(Data(key.utf8), filename: name)
            XCTAssertEqual(preview, .privateKey, name)
            XCTAssertFalse(preview.allowsKeepingOriginalBytes, name)
        }
        // The names decide nothing: an extensionless text file with no key is still text.
        XCTAssertEqual(DocumentPolicy.decode(Data("plain".utf8), filename: "id_rsa"), .text("plain", markdown: false))
    }

    func testAKeyInADocumentIsHiddenAndTheRestStays() {
        let preview = DocumentPolicy.decode(Data(mixed.utf8), filename: "notes.md")
        guard case .text(let text, let markdown, let hidden) = preview else { return XCTFail("Should stay readable") }
        XCTAssertTrue(markdown); XCTAssertEqual(hidden, 1)
        XCTAssertFalse(preview.allowsKeepingOriginalBytes)
        XCTAssertTrue(text.contains("needle after the key")); XCTAssertTrue(text.contains("Rotate on the first."))
        for fragment in SyntheticKey.fragments(of: key) { XCTAssertFalse(text.contains(fragment)) }
    }

    func testAKeyAnywhereInTheBoundedReadIsSeen() {
        let padding = String(repeating: "padding line\n", count: (DocumentPolicy.previewByteLimit - key.utf8.count) / 13)
        for text in [key + padding, padding + key] {
            let bytes = Data(text.utf8)
            XCTAssertLessThanOrEqual(bytes.count, DocumentPolicy.previewByteLimit)
            guard case .text(let shown, _, let hidden) = DocumentPolicy.decode(bytes, filename: "big.log") else { return XCTFail("Should stay readable") }
            XCTAssertEqual(hidden, 1)
            for fragment in SyntheticKey.fragments(of: key) { XCTAssertFalse(shown.contains(fragment)) }
        }
    }

    func testOnlyBytesThatCanBeReopenedSafelyMayBeKept() {
        XCTAssertTrue(DocumentPreview.text("plain", markdown: false).allowsKeepingOriginalBytes)
        XCTAssertTrue(DocumentPreview.empty.allowsKeepingOriginalBytes)
        XCTAssertFalse(DocumentPreview.text("x", markdown: false, hiddenKeys: 1).allowsKeepingOriginalBytes)
        XCTAssertFalse(DocumentPreview.privateKey.allowsKeepingOriginalBytes)
        // UTF-16 or Latin-1 text isn't checked for a key, because it's never decoded.
        XCTAssertFalse(DocumentPolicy.decode(Data(key.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), filename: "id_rsa").allowsKeepingOriginalBytes)
    }

    func testFindAndCopySourceReachOnlyHiddenTextAtOriginalOffsets() throws {
        guard case .text(let text, let markdown, _) = DocumentPolicy.decode(Data(mixed.utf8), filename: "notes.txt") else { return XCTFail("Should stay readable") }
        let index = try DocumentTextIndex(text: text, markdown: markdown)
        let raw = try DocumentTextIndex(text: mixed, markdown: false)
        XCTAssertEqual(index.source, text, "Copy Source and Find use this text")
        for fragment in SyntheticKey.fragments(of: key).prefix(8) {
            XCTAssertEqual(try index.matches(fragment, inSource: true).targets.count, 0)
            XCTAssertEqual(try raw.matches(fragment, inSource: true).targets.count, 1, "The fragment was in the original")
        }
        XCTAssertEqual(try index.matches("needle", inSource: true).targets, try raw.matches("needle", inSource: true).targets)
    }

    func testRenderedMarkdownHoldsOnlyHiddenText() throws {
        guard case .text(let text, true, _) = DocumentPolicy.decode(Data(("# Notes\n\n```\n" + key + "```\n\nneedle\n").utf8), filename: "notes.md") else {
            return XCTFail("Should stay readable")
        }
        let index = try DocumentTextIndex(text: text, markdown: true)
        for fragment in SyntheticKey.fragments(of: key).prefix(8) {
            XCTAssertEqual(try index.matches(fragment, inSource: false).targets.count, 0)
        }
        XCTAssertEqual(try index.matches("needle", inSource: false).targets.count, 1)
    }

    func testReadingPositionsDontDependOnAKeyOrChangeForOtherFiles() {
        func decoded(_ text: String) -> String? {
            if case .text(let value, _, _) = DocumentPolicy.decode(Data(text.utf8), filename: "notes.txt") { return value }
            return nil
        }
        // A file with no key keeps its revision, and so the place a reader saved in it.
        let plain = "A long document\nwith no key in it.\n"
        XCTAssertEqual(SavedReadingPosition.revision(for: decoded(plain)!), SavedReadingPosition.revision(for: plain))
        // The hash on disk no longer covers a key, so replacing a key with another keeps the layout's place.
        let first = "before\n" + SyntheticKey.pem(seed: 1) + "after\n", second = "before\n" + SyntheticKey.pem(seed: 2) + "after\n"
        XCTAssertNotEqual(SavedReadingPosition.revision(for: first), SavedReadingPosition.revision(for: second))
        XCTAssertEqual(SavedReadingPosition.revision(for: decoded(first)!), SavedReadingPosition.revision(for: decoded(second)!))
    }

    func testExtractorHidesAKeyBeforeClippingToItsBudgetAndKeyFilesAreEmptyNotFailures() async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        // The clip lands inside the key, where hiding afterwards would see half a block.
        let padding = String(repeating: "p", count: 200)
        let clipped = try await SearchDocumentExtractor.extract(Data((padding + "\n" + key + "needle\n").utf8), filename: "a.log",
            options: .init(maxTextBytes: 800), deadline: deadline)
        XCTAssertEqual(clipped.isTruncated, true)
        let text = try XCTUnwrap(clipped.segments.first?.text)
        for fragment in SyntheticKey.fragments(of: key) { XCTAssertFalse(text.contains(fragment)) }

        for name in ["id_rsa", ".server.key", "server.pem.txt"] {
            let extracted = try await SearchDocumentExtractor.extract(Data(key.utf8), filename: name, options: .init(), deadline: deadline)
            XCTAssertEqual(extracted.segments, [], name)
            XCTAssertFalse(extracted.isTruncated, name)
        }
    }

    func testDemoSamplesShowBothBehaviours() async throws {
        let demo = DemoRemoteFileService(delayNanoseconds: 0)
        let profile = ConnectionProfile(name: "Demo", host: "demo", username: "reader", identityID: UUID())
        let notes = try await demo.readFile(profile: profile, path: DemoCertificates.folder + "/Deploy notes.txt", limit: 4_096)
        guard case .text(let text, _, 1) = DocumentPolicy.decode(notes, filename: "Deploy notes.txt") else { return XCTFail("Should stay readable") }
        XCTAssertTrue(text.contains("stays readable")); XCTAssertTrue(text.contains("•"))
        let key = try await demo.readFile(profile: profile, path: DemoCertificates.folder + "/id_demo", limit: 4_096)
        XCTAssertEqual(DocumentPolicy.decode(key, filename: "id_demo"), .privateKey)
    }
}
