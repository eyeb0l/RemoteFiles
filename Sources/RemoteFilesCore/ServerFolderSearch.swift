import Foundation

/// Returning nil is an explicit capability failure; transport, trust and cancellation errors throw.
protocol ServerFolderSearching: Sendable {
    func searchFolders(query: String, root: String, profile: ConnectionProfile, includeHidden: Bool,
                       limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?) async throws -> RemoteFolderSearch.Update?
}

/// The remote helper only rejects definite ASCII non-matches. Foundation remains the authority for
/// literal/Unicode matching, text validation and snippets. No remote index or helper file is installed.
enum ServerFolderSearch {
    static let outputLimit = 24 * 1_024 * 1_024
    static let candidateLimit = 10_000
    enum Failure: Error { case unsupported, invalidResponse, resourceLimit }

    struct Request: Encodable {
        let root: String
        let query: String
        let rootHandle: String?
        let ownerToken: String?
        let hidden: Bool
        let depth: Int
        let folders: Int
        let seconds: Double
        let files: Int?
        let fileBytes: Int?
        let totalBytes: Int?
        let textExtensions: [String]
        let excludedExtensions: [String]
    }

    static func command(query: String, root: String, includeHidden: Bool, limits: RemoteFolderSearch.Limits,
                        content: RemoteFolderSearch.ContentLimits?, rootHandle: String? = nil, ownerToken: String? = nil) throws -> String {
        guard root.hasPrefix("/"), !root.contains("\0"), root == "/" || !root.hasSuffix("/"),
              !root.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Failure.unsupported }
        // Cap custom limits too: a server cannot cause unbounded allocations or a long-running job.
        guard (0...16).contains(limits.maxDepth), (1...1_000).contains(limits.maxFolders),
              (1...500).contains(limits.maxMatches), limits.timeLimit > .zero,
              limits.timeLimit <= .seconds(30), query.utf8.count <= 4_096 else { throw Failure.unsupported }
        if let content, content.maxFiles > 500 || content.maxFileBytes > 256 * 1_024 || content.maxTotalBytes > 16 * 1_024 * 1_024 {
            throw Failure.unsupported // Keep larger custom budgets on the existing SFTP implementation.
        }
        let parts = limits.timeLimit.components
        let request = Request(root: root, query: query, rootHandle: rootHandle, ownerToken: ownerToken, hidden: includeHidden, depth: limits.maxDepth,
            folders: limits.maxFolders, seconds: Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
            files: content?.maxFiles, fileBytes: content?.maxFileBytes, totalBytes: content?.maxTotalBytes,
            textExtensions: Array(DocumentPolicy.searchTextExtensions), excludedExtensions: Array(DocumentPolicy.searchExcludedExtensions))
        let payload = try JSONEncoder().encode(request).base64EncodedString()
        guard let url = Bundle.module.url(forResource: "ServerSearch", withExtension: "txt") else { throw Failure.unsupported }
        let script = try String(contentsOf: url, encoding: .utf8)
        // Both arguments are shell-quoted. The query and path are encoded data, never shell syntax.
        return "python3 -I -S -B -c " + quote(script) + " " + quote(payload)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    struct Response: Decodable {
        let version: Int
        let root: String
        let candidates: [Candidate]
        let folders: Int
        let unreadableFolders: Int
        let deepFolders: Int
        let files: Int
        let skippedFiles: Int
        let unreadableFiles: Int
        let bytes: Int
        let charged: Int
        let stop: String?
        let error: String?
    }
    struct Candidate: Decodable {
        let path: String
        let kind: String
        let size: UInt64
        let modified: Double
        let data: String?
    }

    static func decode(_ data: Data, query: String, root: String, includeHidden: Bool,
                       limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?) throws -> RemoteFolderSearch.Update {
        guard data.count <= outputLimit else { throw Failure.invalidResponse }
        let value: Response
        do { value = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw Failure.invalidResponse }
        guard value.version == 1, value.root.utf8.elementsEqual(root.utf8), value.candidates.count <= candidateLimit else {
            throw Failure.invalidResponse
        }
        switch value.error {
        case nil: break
        case "unsupported": throw Failure.unsupported
        case "resourceLimit": throw Failure.resourceLimit
        case "notFound": throw RemoteFileError.notFound
        case "permissionDenied": throw RemoteFileError.permissionDenied
        case "outsideRoot": throw RemoteDocumentLinkError.outsideConnection
        default: throw Failure.invalidResponse
        }
        guard (0...limits.maxFolders).contains(value.folders), (0...1_000).contains(value.unreadableFolders),
              (0...100_000).contains(value.deepFolders), (0...(content?.maxFiles ?? 0)).contains(value.files),
              (0...100_000).contains(value.skippedFiles), (0...500).contains(value.unreadableFiles),
              (0...(content?.maxTotalBytes ?? 0)).contains(value.charged), (0...value.charged).contains(value.bytes) else {
            throw Failure.invalidResponse
        }
        var update = RemoteFolderSearch.Update()
        switch value.stop {
        case nil: break
        case "folderLimit": update.stop = .folderLimit
        case "timeLimit": update.stop = .timeLimit
        case "fileLimit": update.stop = .fileLimit
        case "byteLimit": update.stop = .byteLimit
        default: throw Failure.invalidResponse
        }
        var seen = Set<String>(), transferred = 0, matchCount = 0
        // Re-establish breadth-first, localized natural ordering independently of the server locale.
        let sorted = value.candidates.sorted {
            let a = $0.path.split(separator: "/"), b = $1.path.split(separator: "/")
            if a.count != b.count { return a.count < b.count }
            for (x, y) in zip(a, b) where x != y {
                return String(x).localizedStandardCompare(String(y)) == .orderedAscending
            }
            return false
        }
        for candidate in sorted {
            let path = candidate.path
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path != root, RemoteResourcePath.contains(path, in: root), !path.contains("\0"),
                  !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  seen.insert(path).inserted, let kind = RemoteEntry.Kind(rawValue: candidate.kind), candidate.modified.isFinite else {
                throw Failure.invalidResponse
            }
            let relative = path.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/")
            guard relative.count <= limits.maxDepth + 1,
                  includeHidden || !relative.contains(where: { $0.hasPrefix(".") }) else { throw Failure.invalidResponse }
            let entry = RemoteEntry(name: RemotePath.name(of: path), path: path, kind: kind, size: candidate.size,
                                    modifiedAt: Date(timeIntervalSince1970: candidate.modified))
            if let content {
                guard kind == .file, let encoded = candidate.data, let bytes = Data(base64Encoded: encoded),
                      bytes.count <= content.maxFileBytes else { throw Failure.invalidResponse }
                transferred += bytes.count
                guard transferred <= value.bytes else { throw Failure.invalidResponse }
                if case .text(let text, _) = DocumentPolicy.decode(bytes, filename: entry.name, maxBytes: content.maxFileBytes),
                   let match = RemoteFolderSearch.firstMatch(in: text, query: query, entry: entry) {
                    matchCount += 1
                    if update.contentMatches.count < limits.maxMatches { update.contentMatches.append(match) }
                }
            } else {
                guard candidate.data == nil else { throw Failure.invalidResponse }
                if entry.name.localizedCaseInsensitiveContains(query) {
                    matchCount += 1
                    if update.matches.count < limits.maxMatches { update.matches.append(entry) }
                }
            }
        }
        if matchCount > limits.maxMatches { update.stop = .matchLimit }
        update.foldersSearched = value.folders; update.unreadableFolders = value.unreadableFolders
        update.skippedDeepFolders = value.deepFolders; update.filesSearched = value.files
        update.skippedFiles = value.skippedFiles; update.unreadableFiles = value.unreadableFiles
        update.bytesRead = value.bytes; update.chargedBytes = value.charged
        update.isFinished = true
        return update
    }
}
