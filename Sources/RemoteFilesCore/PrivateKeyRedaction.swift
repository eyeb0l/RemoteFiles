import Foundation

/// Hides private keys in decoded text before it reaches a view, the document cache or a search
/// index. Each hidden character becomes one `•`, and line breaks stay, so UTF-16 offsets, line
/// numbers and everything around a key are unchanged. Hiding is by content, because a key can be
/// in any file: an extensionless `id_rsa`, a `.txt` or a log.
///
/// A marker alone hides nothing, since documentation, tests and this repository's source mention
/// them: a key needs base64 after it. Everything is one forward pass, so hostile input stays linear.
/// This recognizes the formats below, and is not a general secret scanner.
/// See docs/PRIVATE_KEYS_IN_TEXT.md for the rule and what it misses.
public enum PrivateKeyRedaction {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let hiddenKeys: Int
        /// There's nothing in the file but keys, so nothing is left worth showing.
        public let isOnlyKeys: Bool
    }

    public static func redact(_ text: String) -> Result {
        let bytes = Array(text.utf8)
        guard needles.contains(where: { first($0, in: bytes, range: bytes.indices) != nil }) else {
            return Result(text: text, hiddenKeys: 0, isOnlyKeys: false)
        }
        var finder = Finder(bytes: bytes)
        finder.findPEMBlocks()
        finder.findSSH2Blocks()
        finder.findPuTTYFiles()
        finder.findWrappedKeys()
        guard finder.keys > 0 else { return Result(text: text, hiddenKeys: 0, isOnlyKeys: false) }
        return Result(text: finder.maskedText(), hiddenKeys: finder.keys, isOnlyKeys: finder.isOnlyKeys())
    }

    // MARK: - Recognizing a key

    private static let privateKey = Array("PRIVATE KEY".utf8)
    /// PGP's older name for the same thing: `-----BEGIN PGP SECRET KEY BLOCK-----`.
    private static let secretKey = Array("SECRET KEY".utf8)
    /// The scanner reads a label in any case, so the first look must not miss these.
    private static let otherCases = ["private key", "Private Key", "secret key", "Secret Key"].map { Array($0.utf8) }
    private static func isKeyLabel(_ label: String) -> Bool { label.contains("PRIVATE KEY") || label.contains("PGP SECRET KEY") }
    private static let puttyMarker = Array("PuTTY-User-Key-File-".utf8)
    private static let ssh2Begin = Array("---- BEGIN SSH2 ".utf8)
    private static let ssh2End = Array("---- END SSH2 ".utf8)
    private static let ssh2Dashes = Array(" ----".utf8)
    private static let pemEnd = Array("-----END ".utf8)
    private static let pemDashes = Array("-----".utf8)
    /// A whole PEM file encoded as base64, as in a kubeconfig's `client-key-data`, and the body of
    /// an OpenSSH key without its markers. Every such text starts with these characters.
    private static let wrappedPEM = base64Prefix(of: "-----BEGIN ", characters: 14)
    private static let wrappedOpenSSH = base64Prefix(of: "openssh-key-v1\0", characters: 19)
    private static let needles = [privateKey, secretKey, puttyMarker, wrappedPEM, wrappedOpenSSH] + otherCases

    /// The longest run of base64 that starts a key line. Real keys wrap at 64 to 76 characters.
    private static let minimumKeyRun = 32
    /// A run that ends a line under a long prefix. Keys wrap at 64 or more; this allows a narrower one.
    private static let minimumTailRun = 40
    /// Shorter than any real key's body. The smallest, an Ed25519 PKCS #8 key, has 64 characters.
    private static let minimumKeyCharacters = 40
    private static let minimumWrappedCharacters = 64
    private static let maximumWrappedLine = 256
    /// How much of a wrapped candidate to decode: enough to find the words `PRIVATE KEY`.
    private static let wrappedHeadCharacters = 160
    /// How far to look for that many characters, allowing for indentation on each line.
    private static let wrappedHeadWindow = 1_024
    /// How far to look for a PuTTY file's fields, in lines. A 16,384-bit public key has about 40.
    private static let puttyHeaderLines = 64
    private static let puttyTrailerLines = 8
    private static let puttyMaximumPrivateLines = 1_024

    private static func base64Prefix(of text: String, characters: Int) -> [UInt8] {
        Array(Data(text.utf8).base64EncodedString().utf8.prefix(characters))
    }

    private static func first(_ needle: [UInt8], in bytes: [UInt8], range: Range<Int>) -> Int? {
        guard needle.count <= range.count else { return nil }
        return bytes.withUnsafeBytes { buffer -> Int? in
            needle.withUnsafeBytes { target -> Int? in
                guard let base = buffer.baseAddress, let found = memmem(base + range.lowerBound, range.count, target.baseAddress!, target.count) else { return nil }
                return UnsafeRawPointer(found) - base
            }
        }
    }

    private static func isBase64(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
            || byte == 0x2B || byte == 0x2F || byte == 0x3D
    }
    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
    }
    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

    /// One line of a block. Lines end at a real line break or at an escaped one, since a key in
    /// JSON or an `.env` file is often on one line with `\n` inside it.
    private struct Line {
        let range: Range<Int>
        /// Runs of base64. A JSON `\/` belongs to its run, since some encoders escape every slash.
        let runs: [Range<Int>]
        let visibleBytes: Int
        let isBlank: Bool
        var longestRun: Int { runs.map(\.count).max() ?? 0 }

        init(_ range: Range<Int>, in bytes: [UInt8]) {
            self.range = range
            var runs: [Range<Int>] = [], start: Int?, visible = 0, hasAlphanumeric = false, index = range.lowerBound
            while index < range.upperBound {
                let byte = bytes[index]
                if !PrivateKeyRedaction.isSpace(byte) { visible += 1 }
                if PrivateKeyRedaction.isAlphanumeric(byte) { hasAlphanumeric = true }
                let escapedSlash = byte == 0x5C && index + 1 < range.upperBound && bytes[index + 1] == 0x2F
                if PrivateKeyRedaction.isBase64(byte) || escapedSlash {
                    if start == nil { start = index }
                    if escapedSlash { index += 1; visible += 1 }
                } else if let open = start {
                    runs.append(open..<index); start = nil
                }
                index += 1
            }
            if let start { runs.append(start..<range.upperBound) }
            self.runs = runs; visibleBytes = visible; isBlank = !hasAlphanumeric
        }

        private func endsLine(_ run: Range<Int>, in bytes: [UInt8]) -> Bool {
            !bytes[run.upperBound..<range.upperBound].contains { !PrivateKeyRedaction.isSpace($0) && $0 != 0x22 && $0 != 0x27 && $0 != 0x2C }
        }

        /// The run that ends the line, when it is long enough to be a key's and nothing follows it
        /// but whitespace or a closing quote. A log line can be mostly prefix (a timestamp, a host,
        /// a process) and still end in a line of the key.
        func keyTail(in bytes: [UInt8]) -> Range<Int>? {
            guard let last = runs.last, last.count >= PrivateKeyRedaction.minimumTailRun,
                  bytes[last].contains(where: { (0x30...0x39).contains($0) || $0 == 0x2B || $0 == 0x2F }),
                  endsLine(last, in: bytes) else { return nil }
            return last
        }

        /// The run that ends the line and starts in the given column: a key's short last line
        /// under the same prefix as the lines before it.
        func tail(startingAt column: Int, in bytes: [UInt8]) -> Range<Int>? {
            guard let last = runs.last, last.lowerBound - range.lowerBound == column, endsLine(last, in: bytes) else { return nil }
            return last
        }

        /// Mostly long base64, with at least one run that an identifier wouldn't be. A prefix, such
        /// as a log's timestamp or a code comment's slashes, doesn't stop a line being one.
        func isKeyLine(in bytes: [UInt8]) -> Bool {
            let long = runs.filter { $0.count >= 16 }
            guard long.contains(where: { run in
                run.count >= PrivateKeyRedaction.minimumKeyRun && bytes[run].contains { (0x30...0x39).contains($0) || $0 == 0x2B || $0 == 0x2F }
            }) else { return false }
            return long.reduce(0) { $0 + $1.count } * 10 >= visibleBytes * 6
        }

        /// A single word of base64, like the short last line of a key.
        func isLoneRun(in bytes: [UInt8]) -> Bool {
            guard runs.count == 1 else { return false }
            var trimmed = range[...]
            while let first = trimmed.first, PrivateKeyRedaction.isSpace(bytes[first]) { trimmed = trimmed.dropFirst() }
            while let last = trimmed.last, PrivateKeyRedaction.isSpace(bytes[last]) { trimmed = trimmed.dropLast() }
            return !trimmed.contains { PrivateKeyRedaction.isSpace(bytes[$0]) }
        }

        /// Nothing else on the line but whitespace and the quotes or comma of a string in a list.
        func isSoleRun(in bytes: [UInt8]) -> Bool {
            guard let run = runs.first else { return false }
            func isPadding(_ byte: UInt8) -> Bool { PrivateKeyRedaction.isSpace(byte) || byte == 0x22 || byte == 0x27 || byte == 0x2C }
            return !bytes[range.lowerBound..<run.lowerBound].contains { !isPadding($0) }
                && !bytes[run.upperBound..<range.upperBound].contains { !isPadding($0) }
        }

        /// `Proc-Type:`, `DEK-Info:`, `Comment:` and other fields that can start a block's body.
        func isHeader(in bytes: [UInt8]) -> Bool {
            var index = range.lowerBound
            while index < range.upperBound, !PrivateKeyRedaction.isAlphanumeric(bytes[index]) { index += 1 }
            guard index < range.upperBound, !(0x30...0x39).contains(bytes[index]) else { return false }
            while index < range.upperBound, PrivateKeyRedaction.isAlphanumeric(bytes[index]) || bytes[index] == 0x2D { index += 1 }
            guard index < range.upperBound, bytes[index] == 0x3A else { return false }
            return index + 1 == range.upperBound || bytes[index + 1] == 0x20
        }
    }

    /// Where the next line starts, if a line ending begins at `index`: a real one, or an escaped
    /// `\n` or `\r\n` behind any number of backslashes.
    private static func lineBreak(in bytes: [UInt8], at index: Int, end: Int) -> Int? {
        guard index < end else { return nil }
        let byte = bytes[index]
        // CRLF is one line ending, raw or escaped. Counted as two it makes an empty line, which
        // the scanners read as the end of a key, leaving the rest of the key's lines showing.
        if byte == 0x0A { return index + 1 }
        if byte == 0x0D { return index + 1 < end && bytes[index + 1] == 0x0A ? index + 2 : index + 1 }
        guard byte == 0x5C else { return nil }
        var after = index
        while after < end, bytes[after] == 0x5C { after += 1 }
        guard after < end, bytes[after] == 0x6E || bytes[after] == 0x72 else { return nil }
        var next = after + 1
        if bytes[after] == 0x72 {
            var pair = after + 1
            while pair < end, bytes[pair] == 0x5C { pair += 1 }
            if pair > after + 1, pair < end, bytes[pair] == 0x6E { next = pair + 1 }
        }
        return next
    }

    /// Calls `body` for each line in `range` until it returns false.
    private static func forEachLine(in bytes: [UInt8], range: Range<Int>, _ body: (Line) -> Bool) {
        var start = range.lowerBound, index = start
        while index < range.upperBound {
            let next = lineBreak(in: bytes, at: index, end: range.upperBound)
            if next == nil, bytes[index] == 0x5C {
                // Backslashes that escape something else belong to the line.
                while index < range.upperBound, bytes[index] == 0x5C { index += 1 }
                continue
            }
            if let next {
                if !body(Line(start..<index, in: bytes)) { return }
                start = next; index = next
            } else {
                index += 1
            }
        }
        if start < range.upperBound { _ = body(Line(start..<range.upperBound, in: bytes)) }
    }

    // MARK: - Finding keys

    private struct Finder {
        let bytes: [UInt8]
        var masks: [Range<Int>] = []
        /// What a key occupies, markers included. What's outside decides if a file is only keys.
        var spans: [Range<Int>] = []
        var keys = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func findPEMBlocks() {
            var found: [PEMScanner.Block] = []
            PEMScanner.scan(bytes) { block in if PrivateKeyRedaction.isKeyLabel(block.label) { found.append(block) } }
            for block in found {
                guard let body = walk(block.body, isTerminated: block.isTerminated) else { continue }
                let beginLength = "-----BEGIN ".utf8.count + block.label.utf8.count + PrivateKeyRedaction.pemDashes.count
                let end = block.isTerminated ? endOfMarker(at: block.body.upperBound) : body.last!.upperBound
                add(body, span: (block.body.lowerBound - beginLength)..<end)
            }
        }

        mutating func findSSH2Blocks() {
            var position = 0
            while let begin = PrivateKeyRedaction.first(PrivateKeyRedaction.ssh2Begin, in: bytes, range: position..<bytes.count) {
                position = begin + PrivateKeyRedaction.ssh2Begin.count
                let labelLimit = min(bytes.count, position + 64)
                guard let closing = PrivateKeyRedaction.first(PrivateKeyRedaction.ssh2Dashes, in: bytes, range: position..<labelLimit),
                      PrivateKeyRedaction.first(PrivateKeyRedaction.privateKey, in: bytes, range: position..<closing) != nil else { continue }
                let start = closing + PrivateKeyRedaction.ssh2Dashes.count
                let end = PrivateKeyRedaction.first(PrivateKeyRedaction.ssh2End, in: bytes, range: start..<bytes.count)
                position = end ?? bytes.count
                guard let body = walk(start..<(end ?? bytes.count), isTerminated: end != nil) else { continue }
                var finish = body.last!.upperBound
                if let end, let closing = PrivateKeyRedaction.first(PrivateKeyRedaction.ssh2Dashes, in: bytes, range: end..<min(bytes.count, end + 80)) {
                    finish = closing + PrivateKeyRedaction.ssh2Dashes.count
                }
                add(body, span: begin..<finish)
            }
        }

        /// A `.ppk` keeps its secret between `Private-Lines:` and `Private-MAC:`, with public lines
        /// before them that stay visible in a longer document.
        mutating func findPuTTYFiles() {
            var position = 0
            while let marker = PrivateKeyRedaction.first(PrivateKeyRedaction.puttyMarker, in: bytes, range: position..<bytes.count) {
                var privateMasks: [Range<Int>] = [], remainingPrivate: Int?, trailer = 0, seen = 0, end = marker
                PrivateKeyRedaction.forEachLine(in: bytes, range: marker..<bytes.count) { line in
                    seen += 1
                    end = line.range.upperBound
                    if let remaining = remainingPrivate, remaining > 0 {
                        guard line.isLoneRun(in: bytes) else { remainingPrivate = 0; return false }
                        privateMasks += line.runs
                        remainingPrivate = remaining - 1
                        return true
                    }
                    if remainingPrivate != nil {
                        trailer += 1
                        if let value = field(in: line, named: "Private-MAC:") ?? field(in: line, named: "Private-Hash:") {
                            privateMasks.append(value)
                            return false
                        }
                        return trailer < PrivateKeyRedaction.puttyTrailerLines
                    }
                    if let value = field(in: line, named: "Private-Lines:") {
                        remainingPrivate = count(in: value)
                        return remainingPrivate != nil
                    }
                    return seen < PrivateKeyRedaction.puttyHeaderLines
                }
                // Markers inside what was just read can't start another file, so this stays linear.
                position = max(end, marker + PrivateKeyRedaction.puttyMarker.count)
                // A file cut short still has a secret in it, and what follows the last field isn't the key's.
                guard let last = privateMasks.last else { continue }
                add(privateMasks, span: marker..<last.upperBound)
            }
        }

        mutating func findWrappedKeys() {
            let taken = spans.sorted { $0.lowerBound < $1.lowerBound }
            for needle in [PrivateKeyRedaction.wrappedPEM, PrivateKeyRedaction.wrappedOpenSSH] {
                // Candidates in one long run share its end, so it's only scanned once.
                var position = 0, takenIndex = 0, runEnd = 0
                while let start = PrivateKeyRedaction.first(needle, in: bytes, range: position..<bytes.count) {
                    position = start + needle.count
                    while takenIndex < taken.count, taken[takenIndex].upperBound <= start { takenIndex += 1 }
                    if takenIndex < taken.count, taken[takenIndex].contains(start) { continue }
                    // Inside a longer run isn't the start of one, though `KEY=` before it is.
                    if start > 0, bytes[start - 1] != 0x3D, PrivateKeyRedaction.isBase64(bytes[start - 1]) { continue }
                    runEnd = max(runEnd, start)
                    while runEnd < bytes.count, PrivateKeyRedaction.isBase64(bytes[runEnd]) { runEnd += 1 }
                    guard runEnd - start >= PrivateKeyRedaction.minimumKeyRun else { continue }
                    // A line this short may be folded, so its next lines say what it is. Reading only
                    // far enough to tell keeps a file of short candidates linear.
                    let head = runEnd - start >= PrivateKeyRedaction.minimumWrappedCharacters
                        ? [start..<runEnd] : wrappedLines(from: start, upTo: PrivateKeyRedaction.wrappedHeadCharacters)
                    guard head.reduce(0, { $0 + $1.count }) >= PrivateKeyRedaction.minimumWrappedCharacters,
                          isWrappedKey(head, needle: needle) else { continue }
                    let body = wrappedBody(from: start)
                    add(body, span: start..<body.last!.upperBound)
                    position = body.last!.upperBound
                }
            }
        }

        private func isWrappedKey(_ runs: [Range<Int>], needle: [UInt8]) -> Bool {
            guard needle == PrivateKeyRedaction.wrappedPEM else { return true }
            // A kubeconfig's certificate is wrapped the same way and stays visible.
            var encoded = [UInt8]()
            for run in runs where encoded.count < PrivateKeyRedaction.wrappedHeadCharacters {
                encoded += bytes[run.lowerBound..<min(run.upperBound, run.lowerBound + PrivateKeyRedaction.wrappedHeadCharacters)]
            }
            let length = min(encoded.count, PrivateKeyRedaction.wrappedHeadCharacters) / 4 * 4
            guard let head = Data(base64Encoded: Data(encoded[..<length])) else { return false }
            return PrivateKeyRedaction.first(PrivateKeyRedaction.privateKey, in: Array(head), range: 0..<head.count) != nil
        }

        /// The whole of an accepted key: its run, and the lines it wraps onto. Only a run that ends
        /// its line wraps. Reading the rest of the line to find out would have every candidate on
        /// one long line read all of it, which made a megabyte of them take most of a minute.
        private func wrappedBody(from start: Int) -> [Range<Int>] {
            var index = start
            while index < bytes.count {
                if PrivateKeyRedaction.isBase64(bytes[index]) { index += 1 }
                else if bytes[index] == 0x5C, index + 1 < bytes.count, bytes[index + 1] == 0x2F { index += 2 }
                else { break }
            }
            let first = start..<index, width = first.count
            guard width <= PrivateKeyRedaction.maximumWrappedLine else { return [first] }
            // A closing quote, a comma or trailing spaces may stand between the run and its line's end.
            var after = index
            while after < bytes.count, after - index < 4,
                  bytes[after] == 0x20 || bytes[after] == 0x09 || bytes[after] == 0x22 || bytes[after] == 0x27 || bytes[after] == 0x2C {
                after += 1
            }
            guard let next = PrivateKeyRedaction.lineBreak(in: bytes, at: after, end: bytes.count) else { return [first] }
            var runs = [first]
            PrivateKeyRedaction.forEachLine(in: bytes, range: next..<bytes.count) { line in
                guard let run = line.runs.first, line.runs.count == 1, run.count <= width, line.isSoleRun(in: bytes) else { return false }
                runs.append(run)
                return run.count == width
            }
            return runs
        }

        /// The start of a candidate, far enough to tell what it is: its run and any lines it wraps
        /// onto. Every line of wrapped base64 has the same length but the last, so a shorter or
        /// longer one ends it, as does any other kind of line.
        private func wrappedLines(from start: Int, upTo limit: Int) -> [Range<Int>] {
            var runs: [Range<Int>] = [], width = 0, total = 0
            // A look ahead stays in a fixed window: one long line of candidates would otherwise have
            // each of them read the whole line.
            let end = min(bytes.count, start + PrivateKeyRedaction.wrappedHeadWindow)
            PrivateKeyRedaction.forEachLine(in: bytes, range: start..<end) { line in
                guard let run = line.runs.first else { return false }
                if runs.isEmpty {
                    runs.append(run); width = run.count; total = run.count
                    return width <= PrivateKeyRedaction.maximumWrappedLine && total < limit
                }
                guard line.runs.count == 1, run.count <= width, line.isSoleRun(in: bytes) else { return false }
                runs.append(run); total += run.count
                return run.count == width && total < limit
            }
            return runs
        }

        /// The ranges to hide in a block's body, or nil when it isn't a key. Unterminated blocks
        /// end at the first line that isn't key text, so a key cut short at the end of a file is
        /// still hidden. A terminated one is judged as a whole, so a stray line doesn't expose
        /// what follows it, and most of it must be key text.
        private func walk(_ range: Range<Int>, isTerminated: Bool) -> [Range<Int>]? {
            var hidden: [Range<Int>] = [], total = 0, seenKey = false, keyBytes = 0, otherBytes = 0
            // Where the key starts on a line that is mostly prefix, so that its short last line is found.
            var tailColumn: Int?
            let bytes = self.bytes
            PrivateKeyRedaction.forEachLine(in: bytes, range: range) { line in
                guard !line.isBlank else { return true }
                let isKeyLine = line.isKeyLine(in: bytes)
                if !seenKey, !isKeyLine, line.isHeader(in: bytes) { return true }
                if !isKeyLine {
                    // Only the key is hidden on such a line, and the prefix stays readable.
                    let tail = line.keyTail(in: bytes) ?? tailColumn.flatMap { line.tail(startingAt: $0, in: bytes) }
                    if let tail {
                        seenKey = true; tailColumn = tail.lowerBound - line.range.lowerBound
                        hidden.append(tail); total += tail.count; keyBytes += line.visibleBytes
                        return true
                    }
                }
                // The line after a key under a prefix is the end marker's own prefix, or other log text.
                let followsTail = tailColumn != nil
                tailColumn = nil
                let isLone = seenKey && line.isLoneRun(in: bytes)
                if !isKeyLine, !isLone {
                    guard isTerminated else { return false }
                    if !seenKey { otherBytes += line.visibleBytes; return true }
                }
                seenKey = true
                for run in line.runs where (run.count >= 4 || isLone) && (isKeyLine || isLone || !followsTail) {
                    hidden.append(run); total += run.count
                }
                if isKeyLine || isLone { keyBytes += line.visibleBytes } else { otherBytes += line.visibleBytes }
                return true
            }
            guard total >= PrivateKeyRedaction.minimumKeyCharacters else { return nil }
            guard !isTerminated || keyBytes >= otherBytes else { return nil }
            return hidden
        }

        private func field(in line: Line, named name: String) -> Range<Int>? {
            guard let found = PrivateKeyRedaction.first(Array(name.utf8), in: bytes, range: line.range) else { return nil }
            var start = found + name.utf8.count
            while start < line.range.upperBound, bytes[start] == 0x20 { start += 1 }
            var end = start
            while end < line.range.upperBound, PrivateKeyRedaction.isBase64(bytes[end]) { end += 1 }
            return end > start ? start..<end : nil
        }

        private func count(in range: Range<Int>) -> Int? {
            guard let value = Int(String(decoding: bytes[range], as: UTF8.self)), value > 0,
                  value <= PrivateKeyRedaction.puttyMaximumPrivateLines else { return nil }
            return value
        }

        private func endOfMarker(at start: Int) -> Int {
            let from = start + PrivateKeyRedaction.pemEnd.count
            guard from < bytes.count else { return bytes.count }
            return PrivateKeyRedaction.first(PrivateKeyRedaction.pemDashes, in: bytes, range: from..<min(bytes.count, from + 80))
                .map { $0 + PrivateKeyRedaction.pemDashes.count } ?? min(bytes.count, from)
        }

        private mutating func add(_ ranges: [Range<Int>], span: Range<Int>) {
            masks += ranges; spans.append(span); keys += 1
        }

        func maskedText() -> String {
            var output = [UInt8](); output.reserveCapacity(bytes.count)
            var position = 0
            for mask in masks.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                guard mask.upperBound > position else { continue }
                let start = max(position, mask.lowerBound)
                output += bytes[position..<start]
                for _ in start..<mask.upperBound { output += [0xE2, 0x80, 0xA2] }
                position = mask.upperBound
            }
            output += bytes[position...]
            return String(decoding: output, as: UTF8.self)
        }

        func isOnlyKeys() -> Bool {
            func isEmpty(_ range: Range<Int>) -> Bool {
                !bytes[range].contains { !PrivateKeyRedaction.isSpace($0) && $0 != 0x22 && $0 != 0x27 }
            }
            var position = 0
            for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if span.lowerBound > position, !isEmpty(position..<span.lowerBound) { return false }
                position = max(position, span.upperBound)
            }
            return position >= bytes.count || isEmpty(position..<bytes.count)
        }
    }
}
