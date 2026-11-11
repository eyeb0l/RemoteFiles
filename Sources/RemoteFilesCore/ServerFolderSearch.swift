import Foundation

/// Returning nil is an explicit capability failure; transport, trust and cancellation errors throw.
/// `partial` hears what has been found so far, and nil can follow it: the caller must not repeat those matches.
protocol ServerFolderSearching: Sendable {
    func searchFolders(query: String, root: String, profile: ConnectionProfile, includeHidden: Bool,
                       limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?,
                       partial: @escaping @Sendable (RemoteFolderSearch.Update) -> Void) async throws -> RemoteFolderSearch.Update?
}

/// The remote helper only rejects definite ASCII non-matches. Foundation remains the authority for
/// literal/Unicode matching, text validation and snippets. No remote index or helper file is installed.
enum ServerFolderSearch {
    static let outputLimit = 24 * 1_024 * 1_024
    static let candidateLimit = 10_000
    enum Failure: Error { case unsupported, invalidResponse, resourceLimit }

    struct RootIdentity: Encodable, Sendable {
        let inode: UInt64
        let mountID: UInt64
        let namespace: String

        init(fdinfo: String, namespace: String) throws {
            func number(_ key: String) throws -> UInt64 {
                let values = fdinfo.split(separator: "\n").filter { $0.hasPrefix(key + ":") }
                guard values.count == 1, let value = values.first?.split(separator: ":").last,
                      let number = UInt64(value.trimmingCharacters(in: .whitespaces)), number > 0 else { throw Failure.unsupported }
                return number
            }
            guard namespace.range(of: #"\Amnt:\[[0-9]+\]\z"#, options: .regularExpression) != nil else { throw Failure.unsupported }
            inode = try number("ino"); mountID = try number("mnt_id"); self.namespace = namespace
        }
    }

    struct Request: Encodable {
        let root: String
        let query: String
        let rootHandle: String?
        let identity: RootIdentity?
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
                        content: RemoteFolderSearch.ContentLimits?, rootHandle: String? = nil, identity: RootIdentity? = nil) throws -> String {
        guard RemotePath.isAbsolute(root), !root.utf8.contains(0), root.utf8.elementsEqual("/".utf8) || !RemotePath.endsWithSeparator(root),
              !RemotePath.components(of: root).contains(where: RemotePath.isDotName) else { throw Failure.unsupported }
        // Cap custom limits too: a server cannot cause unbounded allocations or a long-running job.
        guard (0...16).contains(limits.maxDepth), (1...1_000).contains(limits.maxFolders),
              (1...500).contains(limits.maxMatches), limits.timeLimit > .zero,
              limits.timeLimit <= .seconds(30), query.utf8.count <= 4_096 else { throw Failure.unsupported }
        if let content, content.maxFiles > 500 || content.maxFileBytes > 256 * 1_024 || content.maxTotalBytes > 16 * 1_024 * 1_024 {
            throw Failure.unsupported // Keep larger custom budgets on the existing SFTP implementation.
        }
        let parts = limits.timeLimit.components
        let request = Request(root: root, query: query, rootHandle: rootHandle, identity: identity, hidden: includeHidden, depth: limits.maxDepth,
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

    /// One line of the helper's output: what it has found since the line before, with running totals.
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
        let final: Bool
    }
    struct Candidate: Decodable {
        let path: String
        let kind: String
        let size: UInt64
        let modified: Double
        let data: String?
    }

    /// The whole of an output at once, as one update.
    static func decode(_ data: Data, query: String, root: String, includeHidden: Bool,
                       limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?) throws -> RemoteFolderSearch.Update {
        guard data.count <= outputLimit else { throw Failure.invalidResponse }
        var decoder = OutputDecoder(query: query, root: root, includeHidden: includeHidden, limits: limits, content: content)
        var matches: [RemoteEntry] = [], contentMatches: [RemoteFolderSearch.ContentMatch] = []
        for update in try decoder.consume(data) {
            matches += update.matches; contentMatches += update.contentMatches
        }
        var final = try decoder.finish()
        final.matches = matches + final.matches
        final.contentMatches = contentMatches + final.contentMatches
        return final
    }

    /// Reads the helper's lines as they arrive and judges each by itself. A server need not run the helper as
    /// written, so nothing here trusts it: every candidate is checked and matched again, and limits are enforced
    /// across lines. A line can be split anywhere between chunks.
    struct OutputDecoder {
        let query: String, root: String, includeHidden: Bool
        let limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?
        private var unfinished = Data()
        // Bytes, because two spellings of one name in Unicode are two files on the server.
        private var seen = Set<Data>()
        private var candidates = 0, transferred = 0, matched = 0
        private var latest = RemoteFolderSearch.Update()
        private var final: RemoteFolderSearch.Update?
        /// More matches than the search keeps, so there's no need to hear the rest.
        private(set) var isAtMatchLimit = false

        init(query: String, root: String, includeHidden: Bool, limits: RemoteFolderSearch.Limits, content: RemoteFolderSearch.ContentLimits?) {
            self.query = query; self.root = root; self.includeHidden = includeHidden; self.limits = limits; self.content = content
        }

        /// Updates for each line now complete. The final line's update waits for `finish`.
        mutating func consume(_ bytes: some Sequence<UInt8>) throws -> [RemoteFolderSearch.Update] {
            // Look for line ends only in what's new, so that a long line arriving in many chunks stays linear.
            var searchFrom = unfinished.count
            unfinished.append(contentsOf: bytes)
            var updates: [RemoteFolderSearch.Update] = []
            while !isAtMatchLimit, let end = unfinished[(unfinished.startIndex + searchFrom)...].firstIndex(of: UInt8(ascii: "\n")) {
                let update = try decodeLine(Data(unfinished[unfinished.startIndex..<end]))
                unfinished.removeSubrange(unfinished.startIndex...end)
                searchFrom = 0
                if let update { updates.append(update) }
            }
            return updates
        }

        /// What the search ended with: the final line, or where it stopped at the match limit.
        mutating func finish() throws -> RemoteFolderSearch.Update {
            if let final { return final }
            guard isAtMatchLimit else { throw Failure.invalidResponse }
            var last = latest
            last.matches = []; last.contentMatches = []; last.isFinished = true
            return last
        }

        private mutating func decodeLine(_ line: Data) throws -> RemoteFolderSearch.Update? {
            guard final == nil else { throw Failure.invalidResponse } // Nothing may follow the final line.
            let value: Response
            do { value = try JSONDecoder().decode(Response.self, from: line) }
            catch { throw Failure.invalidResponse }
            candidates += value.candidates.count
            guard value.version == 2, value.root.utf8.elementsEqual(root.utf8), candidates <= candidateLimit else {
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
            // Check every candidate before matching any, then order only what matched.
            var matches: [(key: [Substring], entry: RemoteEntry, match: RemoteFolderSearch.ContentMatch?)] = []
            for candidate in value.candidates {
                let path = candidate.path
                let components = RemotePath.components(of: path, omittingEmpty: false)
                guard !path.utf8.elementsEqual(root.utf8), RemoteResourcePath.contains(path, in: root), !path.utf8.contains(0),
                      !components.dropFirst().contains(where: { $0.isEmpty || RemotePath.isDotName($0) }),
                      seen.insert(Data(path.utf8)).inserted, let kind = RemoteEntry.Kind(rawValue: candidate.kind), candidate.modified.isFinite else {
                    throw Failure.invalidResponse
                }
                let relative = RemotePath.components(of: path, under: root)
                guard relative.count <= limits.maxDepth + 1,
                      includeHidden || !relative.contains(where: RemotePath.isHidden) else { throw Failure.invalidResponse }
                let entry = RemoteEntry(name: RemotePath.name(of: path), path: path, kind: kind, size: candidate.size,
                                        modifiedAt: Date(timeIntervalSince1970: candidate.modified))
                let key = Array(components.dropFirst())
                if let content {
                    guard kind == .file, let encoded = candidate.data, let bytes = Data(base64Encoded: encoded),
                          bytes.count <= content.maxFileBytes else { throw Failure.invalidResponse }
                    transferred += bytes.count
                    guard transferred <= value.bytes else { throw Failure.invalidResponse }
                    if case .text(let text, _, _) = DocumentPolicy.decode(bytes, filename: entry.name, maxBytes: content.maxFileBytes),
                       let match = RemoteFolderSearch.firstMatch(in: text, query: query, entry: entry) {
                        matches.append((key, entry, match))
                    }
                } else {
                    guard candidate.data == nil else { throw Failure.invalidResponse }
                    if entry.name.localizedCaseInsensitiveContains(query) { matches.append((key, entry, nil)) }
                }
            }
            // Breadth-first, in localized natural order, independently of the server's locale.
            matches.sort {
                if $0.key.count != $1.key.count { return $0.key.count < $1.key.count }
                for (x, y) in zip($0.key, $1.key) where x != y {
                    return String(x).localizedStandardCompare(String(y)) == .orderedAscending
                }
                return false
            }
            for match in matches {
                matched += 1
                guard matched <= limits.maxMatches else { isAtMatchLimit = true; break }
                if let found = match.match { update.contentMatches.append(found) } else { update.matches.append(match.entry) }
            }
            if isAtMatchLimit { update.stop = .matchLimit }
            update.foldersSearched = value.folders; update.unreadableFolders = value.unreadableFolders
            update.skippedDeepFolders = value.deepFolders; update.filesSearched = value.files
            update.skippedFiles = value.skippedFiles; update.unreadableFiles = value.unreadableFiles
            update.bytesRead = value.bytes; update.chargedBytes = value.charged
            latest = update
            if value.final {
                update.isFinished = true
                final = update
                return nil
            }
            return update
        }
    }
}
