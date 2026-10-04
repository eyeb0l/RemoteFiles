import Foundation

/// User-initiated document navigation has a wider boundary than automatic image resources.
/// All inputs except the reference are server-canonical paths. The transport must canonicalize
/// and recheck the resolved target before returning an entry or opening bytes.
public enum RemoteDocumentLinkPath {
    public static func resolve(_ reference: String, relativeTo documentPath: String,
                               connectionRoot: String) throws -> String {
        guard canonicalAbsolute(connectionRoot), canonicalAbsolute(documentPath),
              documentPath != connectionRoot,
              RemoteResourcePath.contains(documentPath, in: connectionRoot) else {
            throw RemoteDocumentLinkError.outsideConnection
        }
        guard let components = URLComponents(string: reference), components.scheme == nil,
              components.host == nil, components.user == nil, components.password == nil,
              !reference.hasPrefix("//"),
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              !decoded.hasPrefix("/"), !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw RemoteDocumentLinkError.invalidReference
        }
        guard components.fragment == nil else { throw RemoteDocumentLinkError.anchorsUnsupported }
        guard components.query == nil else { throw RemoteDocumentLinkError.queryUnsupported }
        guard !decoded.isEmpty, !decoded.hasSuffix("/") else { throw RemoteDocumentLinkError.invalidReference }
        let rootParts = connectionRoot.split(separator: "/")
        var parts = documentPath.split(separator: "/").dropLast().map(String.init)
        for component in decoded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard parts.count > rootParts.count else { throw RemoteDocumentLinkError.outsideConnection }
                parts.removeLast()
            } else { parts.append(String(component)) }
        }
        let target = "/" + parts.joined(separator: "/")
        guard target != connectionRoot, RemoteResourcePath.contains(target, in: connectionRoot) else {
            throw RemoteDocumentLinkError.outsideConnection
        }
        guard DocumentPolicy.kind(filename: RemotePath.name(of: target)) != .unsupported else {
            throw RemoteDocumentLinkError.unsupportedFile
        }
        return target
    }

    private static func canonicalAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        return !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}

public enum RemoteDocumentLinkError: LocalizedError, Equatable, Sendable {
    case outsideConnection, invalidReference, anchorsUnsupported, queryUnsupported, unsupportedFile
    public var errorDescription: String? {
        switch self {
        case .outsideConnection:
            return "This link leaves the connection’s starting folder. Open the file from its folder instead."
        case .invalidReference:
            return "This link isn’t a relative file path. Open the file from its folder instead."
        case .anchorsUnsupported:
            return "Links to headings aren’t supported yet. Open the file using a link without the # heading fragment."
        case .queryUnsupported:
            return "File links with a query aren’t supported. Use a relative file path without the ? query."
        case .unsupportedFile:
            return "This link isn’t a supported document, image, or PDF. Open its folder to inspect the file."
        }
    }
}
