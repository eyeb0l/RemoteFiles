import Foundation
import Crypto
import SwiftASN1

/// One certificate's dates against a clock. A fact about the dates, not a verdict on the certificate.
public enum CertificateValidityState: Equatable, Sendable {
    case notYetValid(startsAt: Date)
    case withinDates(endsAt: Date)
    case expired(endedAt: Date)
    case unknown
}

public struct CertificateNameAttribute: Equatable, Sendable {
    public let name: String
    public let value: String
}

public struct CertificateName: Equatable, Sendable {
    public let attributes: [CertificateNameAttribute]
    public let omittedAttributes: Int
    func value(of name: String) -> String? { attributes.first { $0.name == name }?.value }
}

public struct CertificateAlternativeName: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case dns = "DNS", email = "Email", uri = "URI", ipAddress = "IP Address"
        case directory = "Directory", principalName = "Principal Name", other = "Other"
    }
    public let kind: Kind
    public let value: String
}

public struct CertificatePublicKey: Equatable, Sendable {
    public let algorithm: String
    /// Nil when the size can't be told from the certificate, such as for an unknown algorithm.
    public let bits: Int?
}

public struct CertificateBasicConstraints: Equatable, Sendable {
    public let isCA: Bool
    public let pathLength: Int?
}

/// What the preview keeps of a certificate or signing request. Every string is bounded and safe to
/// show, and nothing here is secret: the file's own bytes are not retained.
public struct CertificateSummary: Equatable, Sendable, Identifiable {
    public enum Role: Equatable, Sendable { case certificate, signingRequest }
    /// Its place among the summaries read from the file.
    public let id: Int
    public let role: Role
    public let subject: CertificateName
    public let issuer: CertificateName?
    public let notBefore: Date?
    public let notAfter: Date?
    public let version: Int?
    public let serialNumber: String?
    public let alternativeNames: [CertificateAlternativeName]
    public let omittedAlternativeNames: Int
    public let publicKey: CertificatePublicKey?
    public let signatureAlgorithm: String
    public let basicConstraints: CertificateBasicConstraints?
    public let keyUsage: [String]
    public let extendedKeyUsage: [String]
    public let unreadableExtensions: Int
    /// The issuer and subject names match. The signature itself is not checked.
    public let isSelfSigned: Bool
    public let sha256Fingerprint: String?
    public let sha1Fingerprint: String?

    public var title: String {
        subject.value(of: "Common Name") ?? subject.value(of: "Organization") ?? alternativeNames.first?.value
            ?? subject.attributes.first?.value ?? "Unnamed"
    }

    public func validity(at date: Date) -> CertificateValidityState {
        guard role == .certificate, let notBefore, let notAfter else { return .unknown }
        if date < notBefore { return .notYetValid(startsAt: notBefore) }
        if date > notAfter { return .expired(endedAt: notAfter) }
        return .withinDates(endsAt: notAfter)
    }
}

public struct CertificateFileContents: Equatable, Sendable {
    /// In file order, so a chain's leaf normally comes first.
    public var certificates: [CertificateSummary] = []
    /// Certificates found past `CertificatePreview.maximumCertificates`, which were not read.
    public var omittedCertificates = 0
    /// Certificate blocks too damaged or too large to read.
    public var unreadableBlocks = 0
    /// Only ever a count: a key block's contents are skipped without being decoded.
    public var privateKeys = 0
    /// Blocks that are neither certificates nor keys, such as a public key or parameters.
    public var otherBlocks = 0
}

public enum CertificatePreviewResult: Equatable, Sendable {
    case contents(CertificateFileContents)
    case empty
    case tooLarge
    /// No certificate, signing request or private key could be read.
    case unrecognized
}

/// Reads X.509 certificates, PKCS #10 requests and PKCS #7 certificate bundles from untrusted bytes,
/// recognizing PEM or DER by content rather than by extension. `DER.parse` from swift-asn1 does the
/// tag-length-value parsing, with its own depth limit; this walks the fields a person wants to see,
/// so an algorithm it doesn't know still shows its identifier and never fails the whole file.
/// See docs/CERTIFICATE_PREVIEWS.md for the limits and why swift-certificates isn't used.
public enum CertificatePreview {
    public static let maximumFileBytes = DocumentPolicy.previewByteLimit
    /// Parsing DER costs about 100 bytes of memory per element, so a whole-file or bundle parse is
    /// held below the file limit. The largest public CA bundles are about a fifth of this.
    public static let maximumContainerBytes = 1_048_576
    public static let maximumCertificateBytes = 262_144
    public static let maximumCertificates = 200
    public static let maximumFieldBytes = 1_024
    public static let maximumSerialBytes = 64
    public static let maximumNameAttributes = 32
    public static let maximumAlternativeNames = 256
    public static let maximumUsages = 32
    public static let maximumExtensions = 128

    /// Reads a saved copy's bytes away from the caller, and keeps none of them.
    public static func summarize(fileAt url: URL) async throws -> CertificatePreviewResult {
        let work = Task.detached(priority: .userInitiated) { () throws -> CertificatePreviewResult in
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try Task.checkCancellation()
            return parse(try file.read(upToCount: maximumFileBytes + 1) ?? Data())
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Parses away from the caller, and keeps none of the bytes.
    public static func summarize(_ data: Data) async throws -> CertificatePreviewResult {
        let work = Task.detached(priority: .userInitiated) { parse(data) }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return result
    }

    /// Synchronous, and checks for cancellation between certificates: run it off the main actor.
    public static func parse(_ data: Data) -> CertificatePreviewResult {
        guard data.count <= maximumFileBytes else { return .tooLarge }
        guard !data.isEmpty else { return .empty }
        let bytes = asciiCompatible([UInt8](data))
        var reader = Reader()
        var found = false
        PEMScanner.scan(bytes) { block in
            found = true
            reader.read(block, in: bytes)
        }
        if !found {
            guard bytes.first == 0x30 else { return .unrecognized }
            guard bytes.count <= maximumContainerBytes else { return .tooLarge }
            reader.readDER(bytes[...], fallback: .unrecognized)
        }
        let contents = reader.contents
        return contents.certificates.isEmpty && contents.privateKeys == 0 ? .unrecognized : .contents(contents)
    }

    /// PEM with a UTF-16 byte order mark would otherwise hide its markers, including a key's.
    private static func asciiCompatible(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count >= 2 else { return bytes }
        let littleEndian = bytes[0] == 0xFF && bytes[1] == 0xFE
        guard littleEndian || (bytes[0] == 0xFE && bytes[1] == 0xFF) else { return bytes }
        var narrowed = [UInt8](); narrowed.reserveCapacity(bytes.count / 2)
        var index = 2
        while index + 1 < bytes.count {
            let (low, high) = littleEndian ? (bytes[index], bytes[index + 1]) : (bytes[index + 1], bytes[index])
            narrowed.append(high == 0 ? low : 0x3F)
            index += 2
        }
        return narrowed
    }
}

// MARK: - PEM

/// Finds PEM blocks by their markers alone, in one forward pass, so any line ending, a block on one
/// line, and text in any encoding around the blocks all work, and hostile input stays linear.
enum PEMScanner {
    struct Block {
        let label: String
        let body: Range<Int>
        let isTerminated: Bool
    }
    private static let begin = Array("-----BEGIN ".utf8)
    private static let end = Array("-----END ".utf8)
    private static let dashes = Array("-----".utf8)
    private static let maximumLabelBytes = 64

    static func scan(_ bytes: [UInt8], visit: (Block) -> Void) {
        var open: (label: String, start: Int)?
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x2D else { index += 1; continue }
            if matches(begin, in: bytes, at: index) {
                guard let label = label(in: bytes, from: index + begin.count) else { index += begin.count; continue }
                if let open { visit(Block(label: open.label, body: open.start..<index, isTerminated: false)) }
                index += begin.count + label.utf8.count + dashes.count
                open = (label, index)
            } else if matches(end, in: bytes, at: index) {
                if let open { visit(Block(label: open.label, body: open.start..<index, isTerminated: true)) }
                open = nil
                index += end.count
            } else {
                index += 1
            }
        }
        if let open { visit(Block(label: open.label, body: open.start..<bytes.count, isTerminated: false)) }
    }

    private static func matches(_ marker: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index + marker.count <= bytes.count else { return false }
        for offset in marker.indices where bytes[index + offset] != marker[offset] { return false }
        return true
    }

    private static func label(in bytes: [UInt8], from start: Int) -> String? {
        var index = start
        while index < bytes.count, index - start <= maximumLabelBytes {
            if matches(dashes, in: bytes, at: index) {
                return index > start ? String(decoding: bytes[start..<index], as: UTF8.self).uppercased() : nil
            }
            guard (0x20...0x7E).contains(bytes[index]) else { return nil }
            index += 1
        }
        return nil
    }
}

// MARK: - File contents

private struct Reader {
    enum Fallback { case unreadable, unrecognized }
    var contents = CertificateFileContents()
    private var hasRoom: Bool { contents.certificates.count < CertificatePreview.maximumCertificates }

    mutating func read(_ block: PEMScanner.Block, in bytes: [UInt8]) {
        // The private key check comes first, and its body is never looked at.
        if block.label.contains("PRIVATE KEY") {
            contents.privateKeys += 1
            return
        }
        switch block.label {
        case "CERTIFICATE", "X509 CERTIFICATE", "TRUSTED CERTIFICATE", "CERTIFICATE REQUEST", "NEW CERTIFICATE REQUEST":
            guard hasRoom else { contents.omittedCertificates += 1; return }
            guard !Task.isCancelled, block.isTerminated,
                  let der = Self.decodeBase64(bytes[block.body], limit: CertificatePreview.maximumCertificateBytes) else {
                contents.unreadableBlocks += 1
                return
            }
            // A trusted certificate is followed by OpenSSL's own settings, which aren't DER's business.
            let element = block.label == "TRUSTED CERTIFICATE" ? DERReading.firstElement(of: der) : der[...]
            readDER(element, fallback: .unreadable)
        case "PKCS7", "CMS":
            guard hasRoom else { contents.omittedCertificates += 1; return }
            guard !Task.isCancelled, block.isTerminated,
                  let der = Self.decodeBase64(bytes[block.body], limit: CertificatePreview.maximumContainerBytes) else {
                contents.unreadableBlocks += 1
                return
            }
            readDER(der[...], fallback: .unreadable)
        default:
            contents.otherBlocks += 1
        }
    }

    /// Goes by structure, so a `.crt` holding a bundle or a `.der` holding a key is still told apart.
    mutating func readDER(_ der: ArraySlice<UInt8>, fallback: Fallback) {
        func giveUp(_ contents: inout CertificateFileContents) {
            if fallback == .unreadable { contents.unreadableBlocks += 1 }
        }
        guard der.first == 0x30 else { giveUp(&contents); return }
        // Some tools write bundles with BER's indefinite lengths. Certificates inside are still DER.
        guard let root = (try? DER.parse(der)) ?? (try? BER.parse(der)), let parts = root.parts else {
            giveUp(&contents); return
        }
        if DERReading.isSignedData(parts) {
            readBundle(parts, fallback: fallback)
        } else if let summary = X509Reading.summary(of: root, parts: parts, id: contents.certificates.count) {
            if hasRoom { contents.certificates.append(summary) } else { contents.omittedCertificates += 1 }
        } else if DERReading.looksLikePrivateKey(parts) {
            contents.privateKeys += 1
        } else {
            giveUp(&contents)
        }
    }

    private mutating func readBundle(_ parts: [ASN1Node], fallback: Fallback) {
        guard parts.count >= 2, parts[1].identifier.isContext(0), let inner = parts[1].parts?.first?.parts,
              let certificates = inner.first(where: { $0.identifier.isContext(0) })?.children else {
            if fallback == .unreadable { contents.unreadableBlocks += 1 }
            return
        }
        for node in certificates {
            guard hasRoom else { contents.omittedCertificates += 1; continue }
            guard !Task.isCancelled else { return }
            if let parts = node.parts, let summary = X509Reading.summary(of: node, parts: parts, id: contents.certificates.count) {
                contents.certificates.append(summary)
            } else if node.identifier == .sequence {
                contents.unreadableBlocks += 1
            } // Other choices here are attribute certificates, which aren't what this file is opened for.
        }
    }

    private static func decodeBase64(_ body: ArraySlice<UInt8>, limit: Int) -> ArraySlice<UInt8>? {
        var characters = [UInt8](); characters.reserveCapacity(min(body.count, limit / 3 * 4 + 4))
        for byte in body where ![0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains(byte) {
            characters.append(byte)
            if characters.count > limit / 3 * 4 + 4 { return nil }
        }
        guard !characters.isEmpty, let data = Data(base64Encoded: Data(characters)), data.count <= limit else { return nil }
        return [UInt8](data)[...]
    }
}

// MARK: - DER helpers

private extension ASN1Identifier {
    func isContext(_ number: UInt) -> Bool { tagClass == .contextSpecific && tagNumber == number }
}

private extension ASN1Node {
    var children: ASN1NodeCollection? {
        if case .constructed(let children) = content { return children }
        return nil
    }
    var parts: [ASN1Node]? { children.map(Array.init) }
    var bytes: ArraySlice<UInt8>? {
        if case .primitive(let bytes) = content { return bytes }
        return nil
    }
    /// An identifier is as long as its encoding allows, and an unknown one is shown as it is, so
    /// it is bounded like any other field.
    var oid: String? { (try? ASN1ObjectIdentifier(derEncoded: self)).map { CertificateText.safe(String(describing: $0)) } }
}

private enum DERReading {
    static func isSignedData(_ parts: [ASN1Node]) -> Bool { parts.first?.oid == "1.2.840.113549.1.7.2" }

    /// The first element of something a longer, otherwise unused encoding follows.
    static func firstElement(of der: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard der.count >= 2, let lengthByte = der.dropFirst().first else { return der }
        let start = der.startIndex
        var total: Int
        if lengthByte < 0x80 {
            total = 2 + Int(lengthByte)
        } else {
            let count = Int(lengthByte & 0x7F)
            guard (1...4).contains(count), der.count >= 2 + count else { return der }
            total = 0
            for byte in der[(start + 2)..<(start + 2 + count)] { total = total << 8 | Int(byte) }
            total += 2 + count
        }
        return total <= der.count ? der.prefix(total) : der
    }

    /// PKCS #8 (plain or encrypted), PKCS #1, SEC 1 and DSA private keys in binary form.
    static func looksLikePrivateKey(_ parts: [ASN1Node]) -> Bool {
        guard parts.count >= 2 else { return false }
        if parts[0].identifier == .integer {
            if parts[1].identifier == .sequence, parts.count >= 3, parts[2].identifier == .octetString { return true }
            if parts[1].identifier == .octetString { return true }
            return parts.count >= 6 && parts.allSatisfy { $0.identifier == .integer }
        }
        if parts.count == 2, parts[0].identifier == .sequence, parts[1].identifier == .octetString,
           let algorithm = parts[0].parts?.first?.oid {
            return algorithm.hasPrefix("1.2.840.113549.1.5.") || algorithm.hasPrefix("1.2.840.113549.1.12.")
        }
        return false
    }

    static func integerBitLength(_ bytes: ArraySlice<UInt8>) -> Int? {
        let value = bytes.drop { $0 == 0 }
        guard let first = value.first else { return nil }
        return (value.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    static func smallInteger(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard let first = bytes.first, first < 0x80 else { return nil }
        let value = bytes.drop { $0 == 0 }
        guard value.count <= 4 else { return nil }
        return value.reduce(0) { $0 << 8 | Int($1) }
    }

    static func colonHex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { byte in
            let hex = String(byte, radix: 16, uppercase: true)
            return hex.count == 1 ? "0" + hex : hex
        }.joined(separator: ":")
    }

    /// Dates are read by hand because `Calendar` silently rolls over impossible ones.
    static func date(_ node: ASN1Node) -> Date? {
        guard let bytes = node.bytes, bytes.last == 0x5A else { return nil }
        let digits = bytes.dropLast().map { Int($0) - 0x30 }
        guard digits.allSatisfy({ (0...9).contains($0) }) else { return nil }
        func number(_ range: Range<Int>) -> Int { digits[range].reduce(0) { $0 * 10 + $1 } }
        let year: Int, rest: Int
        switch (node.identifier, digits.count) {
        case (.utcTime, 12):
            // RFC 5280: two-digit years 50 and above are in the 1900s.
            let short = number(0..<2)
            year = short >= 50 ? 1900 + short : 2000 + short
            rest = 2
        case (.generalizedTime, 14):
            year = number(0..<4)
            rest = 4
        default: return nil
        }
        let month = number(rest..<(rest + 2)), day = number((rest + 2)..<(rest + 4))
        let hour = number((rest + 4)..<(rest + 6)), minute = number((rest + 6)..<(rest + 8)), second = number((rest + 8)..<(rest + 10))
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...lengths[month - 1]).contains(day),
              hour <= 23, minute <= 59, second <= 60 else { return nil }
        // Days from the civil calendar, as Howard Hinnant's `days_from_civil`.
        let shifted = month <= 2 ? year - 1 : year
        let era = shifted / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hour * 3_600 + minute * 60 + second))
    }
}

/// Everything shown comes from a hostile file, so it goes through here: a bounded length, and every
/// control or formatting character made visible. Those include line breaks, the NUL of a classic
/// `bank.example\0.evil.example` name, and the bidirectional overrides that reorder a name on screen.
enum CertificateText {
    static func safe(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let replaced: Unicode.Scalar
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                replaced = "\u{FFFD}"
            default:
                replaced = scalar
            }
            used += String(replaced).utf8.count
            guard used <= CertificatePreview.maximumFieldBytes else {
                result.append("…")
                break
            }
            result.append(replaced)
        }
        return String(result)
    }

    static func decode(_ node: ASN1Node) -> String? {
        guard let all = node.bytes else { return nil }
        // Enough for the field limit in the widest encoding, whatever the file claims.
        let bytes = all.prefix(CertificatePreview.maximumFieldBytes * 4 + 4)
        let text: String
        switch node.identifier {
        case .utf8String, .printableString, .ia5String, .numericString, .visibleString, .generalString, .graphicString:
            text = String(decoding: bytes, as: UTF8.self)
        case .teletexString, .videotexString:
            // Treated as Latin-1, as other certificate tools do.
            text = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        case .bmpString:
            let units = stride(from: bytes.startIndex, to: bytes.endIndex - 1, by: 2).map {
                UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
            }
            text = String(decoding: units, as: UTF16.self)
        case .universalString:
            var scalars = String.UnicodeScalarView()
            for start in stride(from: bytes.startIndex, to: bytes.endIndex - 3, by: 4) {
                let value = bytes[start..<(start + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            }
            text = String(scalars)
        default:
            return nil
        }
        return safe(text) + (all.count > bytes.count ? "…" : "")
    }
}

// MARK: - X.509

private enum X509Reading {
    /// Nil if this isn't the outline of a certificate or a signing request.
    static func summary(of node: ASN1Node, parts: [ASN1Node], id: Int) -> CertificateSummary? {
        guard parts.count == 3, parts[0].identifier == .sequence, parts[1].identifier == .sequence,
              parts[2].identifier == .bitString, let signed = parts[0].parts,
              let signature = parts[1].parts?.first?.oid else { return nil }
        let algorithm = Names.signature[signature] ?? signature
        if let first = signed.first, first.identifier == .integer, signed.count <= 4 {
            return request(signed, signature: algorithm, id: id)
        }
        return certificate(signed, encoded: node.encodedBytes, signature: algorithm, id: id)
    }

    private static func certificate(_ fields: [ASN1Node], encoded: ArraySlice<UInt8>, signature: String, id: Int) -> CertificateSummary? {
        var index = 0
        var version: Int?
        if let first = fields.first, first.identifier.isContext(0) {
            version = first.parts?.first?.bytes.flatMap(DERReading.smallInteger).flatMap { (0...2).contains($0) ? $0 + 1 : nil }
            index = 1
        } else {
            version = 1 // The default when the field is absent.
        }
        guard fields.count >= index + 6, fields[index].identifier == .integer, let serial = fields[index].bytes,
              let issuerNode = fields.dropFirst(index + 2).first, let issuer = name(issuerNode),
              let validity = fields[index + 3].parts, validity.count == 2,
              let subject = name(fields[index + 4]) else { return nil }
        let extensionNodes = fields.dropFirst(index + 6).first { $0.identifier.isContext(3) }?.parts?.first?.children
        let extensions = ExtensionFields(extensionNodes)
        let matchingNames = !subject.attributes.isEmpty && issuerNode.encodedBytes.elementsEqual(fields[index + 4].encodedBytes)
        return CertificateSummary(
            id: id, role: .certificate, subject: subject, issuer: issuer,
            notBefore: DERReading.date(validity[0]), notAfter: DERReading.date(validity[1]),
            version: version, serialNumber: serialText(serial),
            alternativeNames: extensions.alternativeNames, omittedAlternativeNames: extensions.omittedAlternativeNames,
            publicKey: publicKey(fields[index + 5]), signatureAlgorithm: signature,
            basicConstraints: extensions.basicConstraints, keyUsage: extensions.keyUsage,
            extendedKeyUsage: extensions.extendedKeyUsage, unreadableExtensions: extensions.unreadable,
            isSelfSigned: matchingNames,
            sha256Fingerprint: DERReading.colonHex(SHA256.hash(data: encoded)),
            sha1Fingerprint: DERReading.colonHex(Insecure.SHA1.hash(data: encoded)))
    }

    private static func request(_ fields: [ASN1Node], signature: String, id: Int) -> CertificateSummary? {
        guard fields.count >= 3, let subject = name(fields[1]) else { return nil }
        // The requested extensions, if any, are the one attribute wanted from a signing request.
        var requested: ASN1NodeCollection?
        if fields.count == 4, fields[3].identifier.isContext(0), let attributes = fields[3].children {
            for attribute in attributes {
                guard let parts = attribute.parts, parts.count == 2, parts[0].oid == "1.2.840.113549.1.9.14" else { continue }
                requested = parts[1].parts?.first?.children
                break
            }
        }
        let extensions = ExtensionFields(requested)
        return CertificateSummary(
            id: id, role: .signingRequest, subject: subject, issuer: nil, notBefore: nil, notAfter: nil,
            version: nil, serialNumber: nil,
            alternativeNames: extensions.alternativeNames, omittedAlternativeNames: extensions.omittedAlternativeNames,
            publicKey: publicKey(fields[2]), signatureAlgorithm: signature,
            basicConstraints: extensions.basicConstraints, keyUsage: extensions.keyUsage,
            extendedKeyUsage: extensions.extendedKeyUsage, unreadableExtensions: extensions.unreadable,
            isSelfSigned: false, sha256Fingerprint: nil, sha1Fingerprint: nil)
    }

    private static func serialText(_ bytes: ArraySlice<UInt8>) -> String {
        // A leading zero only keeps a large number from reading as negative.
        let value = bytes.count > 1 && bytes.first == 0 ? bytes.dropFirst() : bytes
        let shown = DERReading.colonHex(value.prefix(CertificatePreview.maximumSerialBytes))
        return value.count > CertificatePreview.maximumSerialBytes ? shown + "…" : shown
    }

    static func name(_ node: ASN1Node) -> CertificateName? {
        guard node.identifier == .sequence, let relative = node.children else { return nil }
        var attributes: [CertificateNameAttribute] = []
        var omitted = 0
        for set in relative {
            guard let members = set.children else { return nil }
            for member in members {
                guard let parts = member.parts, parts.count >= 2, let type = parts[0].oid else { return nil }
                guard attributes.count < CertificatePreview.maximumNameAttributes else { omitted += 1; continue }
                attributes.append(.init(name: Names.attribute[type] ?? type, value: CertificateText.decode(parts[1]) ?? "Unreadable value"))
            }
        }
        return CertificateName(attributes: attributes, omittedAttributes: omitted)
    }

    private static func publicKey(_ node: ASN1Node) -> CertificatePublicKey? {
        guard let parts = node.parts, parts.count == 2, let algorithm = parts[0].parts, let oid = algorithm.first?.oid,
              parts[1].identifier == .bitString, let key = parts[1].bytes?.dropFirst() else { return nil }
        switch oid {
        case "1.2.840.113549.1.1.1", "1.2.840.113549.1.1.10":
            let modulus = (try? DER.parse(key))?.parts?.first?.bytes
            return .init(algorithm: oid.hasSuffix(".1") ? "RSA" : "RSA-PSS", bits: modulus.flatMap(DERReading.integerBitLength))
        case "1.2.840.10045.2.1":
            let curve = algorithm.dropFirst().first?.oid
            let named = curve.flatMap { Names.curve[$0] }
            // A point's two coordinates tell the size of a curve this doesn't name.
            let fromPoint = key.first == 0x04 && key.count > 1 ? (key.count - 1) / 2 * 8 : nil
            let label = named?.name ?? curve ?? "unnamed curve"
            return .init(algorithm: "Elliptic Curve (\(label))", bits: named?.bits ?? fromPoint)
        case "1.2.840.10040.4.1":
            let prime = algorithm.dropFirst().first?.parts?.first?.bytes
            return .init(algorithm: "DSA", bits: prime.flatMap(DERReading.integerBitLength))
        case "1.3.101.110": return .init(algorithm: "X25519", bits: 256)
        case "1.3.101.111": return .init(algorithm: "X448", bits: 448)
        case "1.3.101.112": return .init(algorithm: "Ed25519", bits: 256)
        case "1.3.101.113": return .init(algorithm: "Ed448", bits: 456)
        default:
            return .init(algorithm: Names.signature[oid] ?? oid, bits: nil)
        }
    }
}

/// The extensions the preview shows. One that can't be read is counted, and the rest still appear.
private struct ExtensionFields {
    var alternativeNames: [CertificateAlternativeName] = []
    var omittedAlternativeNames = 0
    var basicConstraints: CertificateBasicConstraints?
    var keyUsage: [String] = []
    var extendedKeyUsage: [String] = []
    var unreadable = 0

    init(_ nodes: ASN1NodeCollection?) {
        guard let nodes else { return }
        var seen = 0
        for node in nodes {
            seen += 1
            guard seen <= CertificatePreview.maximumExtensions else { return }
            guard let parts = node.parts, parts.count >= 2, let oid = parts[0].oid,
                  let value = parts.last?.bytes else { unreadable += 1; continue }
            guard ["2.5.29.17", "2.5.29.19", "2.5.29.15", "2.5.29.37"].contains(oid) else { continue }
            guard let inner = try? DER.parse(value) else { unreadable += 1; continue }
            let wasRead: Bool
            switch oid {
            case "2.5.29.17": wasRead = readAlternativeNames(inner)
            case "2.5.29.19": wasRead = readBasicConstraints(inner)
            case "2.5.29.15": wasRead = readKeyUsage(inner)
            default: wasRead = readExtendedKeyUsage(inner)
            }
            if !wasRead { unreadable += 1 }
        }
    }

    private mutating func readAlternativeNames(_ node: ASN1Node) -> Bool {
        guard node.identifier == .sequence, let names = node.children else { return false }
        for name in names {
            guard alternativeNames.count < CertificatePreview.maximumAlternativeNames else {
                omittedAlternativeNames += 1
                continue
            }
            if let parsed = Self.alternativeName(name) { alternativeNames.append(parsed) }
        }
        return true
    }

    private static func alternativeName(_ node: ASN1Node) -> CertificateAlternativeName? {
        guard node.identifier.tagClass == .contextSpecific else { return nil }
        func text(_ kind: CertificateAlternativeName.Kind) -> CertificateAlternativeName? {
            node.bytes.map { .init(kind: kind, value: CertificateText.safe(String(decoding: $0.prefix(CertificatePreview.maximumFieldBytes + 1), as: UTF8.self))) }
        }
        switch node.identifier.tagNumber {
        case 0:
            guard let parts = node.parts, parts.count == 2, let type = parts[0].oid else { return nil }
            if type == "1.3.6.1.4.1.311.20.2.3", let value = parts[1].parts?.first.flatMap(CertificateText.decode) {
                return .init(kind: .principalName, value: value)
            }
            return .init(kind: .other, value: type)
        case 1: return text(.email)
        case 2: return text(.dns)
        case 4:
            guard let directory = node.parts?.first.flatMap(X509Reading.name) else { return nil }
            let joined = directory.attributes.map { "\($0.name)=\($0.value)" }.joined(separator: ", ")
            return .init(kind: .directory, value: CertificateText.safe(joined))
        case 6: return text(.uri)
        case 7:
            guard let bytes = node.bytes else { return nil }
            return .init(kind: .ipAddress, value: ipAddress(bytes))
        default: return .init(kind: .other, value: "Tag \(node.identifier.tagNumber)")
        }
    }

    private static func ipAddress(_ bytes: ArraySlice<UInt8>) -> String {
        let value = Array(bytes)
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family: Int32
        switch value.count {
        case 4: family = AF_INET
        case 16: family = AF_INET6
        default: return DERReading.colonHex(value.prefix(CertificatePreview.maximumSerialBytes))
        }
        guard inet_ntop(family, value, &text, socklen_t(text.count)) != nil else { return DERReading.colonHex(value) }
        return String(cString: text)
    }

    private mutating func readBasicConstraints(_ node: ASN1Node) -> Bool {
        guard node.identifier == .sequence, let parts = node.parts else { return false }
        var isCA = false
        var pathLength: Int?
        for part in parts {
            if part.identifier == .boolean { isCA = part.bytes?.first.map { $0 != 0 } ?? false }
            if part.identifier == .integer { pathLength = part.bytes.flatMap(DERReading.smallInteger) }
        }
        basicConstraints = .init(isCA: isCA, pathLength: pathLength)
        return true
    }

    private mutating func readKeyUsage(_ node: ASN1Node) -> Bool {
        guard node.identifier == .bitString, let bytes = node.bytes?.dropFirst() else { return false }
        let flags = Array(bytes.prefix(2))
        for (bit, name) in Names.keyUsage.enumerated() where bit / 8 < flags.count {
            if flags[bit / 8] & (0x80 >> UInt8(bit % 8)) != 0 { keyUsage.append(name) }
        }
        return true
    }

    private mutating func readExtendedKeyUsage(_ node: ASN1Node) -> Bool {
        guard node.identifier == .sequence, let purposes = node.children else { return false }
        for purpose in purposes {
            guard extendedKeyUsage.count < CertificatePreview.maximumUsages else { break }
            guard let oid = purpose.oid else { continue }
            extendedKeyUsage.append(Names.extendedKeyUsage[oid] ?? oid)
        }
        return true
    }
}

// MARK: - Names

private enum Names {
    static let attribute: [String: String] = [
        "2.5.4.3": "Common Name", "2.5.4.4": "Surname", "2.5.4.5": "Serial Number", "2.5.4.6": "Country",
        "2.5.4.7": "Locality", "2.5.4.8": "State or Province", "2.5.4.9": "Street", "2.5.4.10": "Organization",
        "2.5.4.11": "Organizational Unit", "2.5.4.12": "Title", "2.5.4.15": "Business Category",
        "2.5.4.17": "Postal Code", "2.5.4.42": "Given Name", "2.5.4.97": "Organization Identifier",
        "0.9.2342.19200300.100.1.1": "User ID", "0.9.2342.19200300.100.1.25": "Domain Component",
        "1.2.840.113549.1.9.1": "Email", "1.3.6.1.4.1.311.60.2.1.3": "Jurisdiction Country",
        "1.3.6.1.4.1.311.60.2.1.2": "Jurisdiction State", "1.3.6.1.4.1.311.60.2.1.1": "Jurisdiction Locality",
    ]
    static let signature: [String: String] = [
        "1.2.840.113549.1.1.2": "MD2 with RSA", "1.2.840.113549.1.1.4": "MD5 with RSA", "1.2.840.113549.1.1.5": "SHA-1 with RSA",
        "1.2.840.113549.1.1.14": "SHA-224 with RSA", "1.2.840.113549.1.1.11": "SHA-256 with RSA",
        "1.2.840.113549.1.1.12": "SHA-384 with RSA", "1.2.840.113549.1.1.13": "SHA-512 with RSA",
        "1.2.840.113549.1.1.10": "RSA-PSS", "1.2.840.10045.4.1": "ECDSA with SHA-1", "1.2.840.10045.4.3.1": "ECDSA with SHA-224",
        "1.2.840.10045.4.3.2": "ECDSA with SHA-256", "1.2.840.10045.4.3.3": "ECDSA with SHA-384",
        "1.2.840.10045.4.3.4": "ECDSA with SHA-512", "1.2.840.10040.4.3": "DSA with SHA-1",
        "2.16.840.1.101.3.4.3.1": "DSA with SHA-224", "2.16.840.1.101.3.4.3.2": "DSA with SHA-256",
        "1.3.101.112": "Ed25519", "1.3.101.113": "Ed448", "2.16.840.1.101.3.4.3.17": "ML-DSA-44",
        "2.16.840.1.101.3.4.3.18": "ML-DSA-65", "2.16.840.1.101.3.4.3.19": "ML-DSA-87",
    ]
    static let curve: [String: (name: String, bits: Int)] = [
        "1.2.840.10045.3.1.1": ("P-192", 192), "1.3.132.0.33": ("P-224", 224), "1.2.840.10045.3.1.7": ("P-256", 256),
        "1.3.132.0.34": ("P-384", 384), "1.3.132.0.35": ("P-521", 521), "1.3.132.0.10": ("secp256k1", 256),
        "1.3.36.3.3.2.8.1.1.7": ("brainpoolP256r1", 256), "1.3.36.3.3.2.8.1.1.11": ("brainpoolP384r1", 384),
        "1.3.36.3.3.2.8.1.1.13": ("brainpoolP512r1", 512),
    ]
    /// In the order of the extension's named bits.
    static let keyUsage = ["Digital Signature", "Content Commitment", "Key Encipherment", "Data Encipherment", "Key Agreement",
                           "Certificate Signing", "CRL Signing", "Encipher Only", "Decipher Only"]
    static let extendedKeyUsage: [String: String] = [
        "2.5.29.37.0": "Any", "1.3.6.1.5.5.7.3.1": "TLS Server Authentication", "1.3.6.1.5.5.7.3.2": "TLS Client Authentication",
        "1.3.6.1.5.5.7.3.3": "Code Signing", "1.3.6.1.5.5.7.3.4": "Email Protection", "1.3.6.1.5.5.7.3.8": "Time Stamping",
        "1.3.6.1.5.5.7.3.9": "OCSP Signing", "1.3.6.1.4.1.311.20.2.2": "Smart Card Logon",
    ]
}
