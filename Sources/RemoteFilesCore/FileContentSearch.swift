import Foundation

public extension RemoteFolderSearch {
    struct ContentLimits: Sendable {
        public let maxFiles: Int
        public let maxFileBytes: Int
        public let maxTotalBytes: Int
        public init(maxFiles: Int = 500, maxFileBytes: Int = 256 * 1_024, maxTotalBytes: Int = 16 * 1_024 * 1_024) {
            self.maxFiles = max(0, maxFiles)
            self.maxFileBytes = min(max(0, maxFileBytes), DocumentPolicy.previewByteLimit)
            self.maxTotalBytes = max(0, maxTotalBytes)
        }
    }

    /// The first literal, case-insensitive source match in a file. Text is never rendered or executed.
    struct ContentMatch: Sendable {
        public let entry: RemoteEntry
        public let line: Int
        public let snippet: String
    }

    /// Reads candidate UTF-8 files one at a time, while the existing bounded walk lists folders.
    /// No shell, persistent index or on-disk content cache is used. Canonical reads stay within root.
    static func contents(matching query: String, below root: String, profile: ConnectionProfile,
                         service: any RemoteFileService, includeHidden: Bool,
                         limits: Limits = Limits(), contentLimits: ContentLimits = ContentLimits()) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let walk = Task {
                do {
                    if query.isEmpty {
                        var final = Update(); final.isFinished = true; continuation.yield(final)
                    } else {
                        try await search(query: query, root: root, profile: profile, service: service,
                            includeHidden: includeHidden, limits: limits, content: contentLimits) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in walk.cancel() }
        }
    }
}

extension RemoteFolderSearch {
    static func scan(_ entries: [RemoteEntry], query: String, root: String, profile: ConnectionProfile,
                     service: any RemoteFileService, limits: ContentLimits, matchLimit: Int,
                     deadline: ContinuousClock.Instant, matched: inout Int, progress: inout Update, report: (Update) -> Void) async throws {
        for entry in entries {
            try Task.checkCancellation()
            if entry.kind == .directory { continue }
            guard entry.kind == .file, isText(entry.name), entry.size.map({ $0 <= UInt64(limits.maxFileBytes) }) ?? true else {
                progress.skippedFiles += 1; continue
            }
            guard matched < matchLimit else { progress.stop = .matchLimit; break }
            guard progress.filesSearched < limits.maxFiles else { progress.stop = .fileLimit; break }
            guard ContinuousClock.now < deadline else { progress.stop = .timeLimit; break }
            var retried = false
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { progress.stop = .timeLimit; return }
                // Allow the transport its extra EOF byte even if a file grows after the listing.
                let remaining = limits.maxTotalBytes - progress.chargedBytes
                guard remaining > 1 else { progress.stop = .byteLimit; return }
                let readLimit = min(limits.maxFileBytes, remaining - 1)
                let reservation = readLimit + 1
                if !retried { progress.filesSearched += 1 }
                progress.chargedBytes += reservation
                let data: Data
                do {
                    data = try await service.readSearchFile(profile: profile, path: entry.path, canonicalRoot: root, limit: readLimit)
                    try Task.checkCancellation()
                } catch {
                    try Task.checkCancellation()
                    // Failed operations may already have transferred bytes: never refund their reservation.
                    if case RemoteFileError.connectionEnded = error, !retried { retried = true; continue }
                    switch error {
                    case RemoteFileError.tooLarge:
                        if readLimit < limits.maxFileBytes { progress.stop = .byteLimit; return }
                        progress.skippedFiles += 1
                    case RemoteFileError.notFound, RemoteFileError.permissionDenied, RemoteFileError.timedOut,
                         RemoteDocumentLinkError.outsideConnection:
                        progress.unreadableFiles += 1
                    default: throw error
                    }
                    break
                }
                guard data.count <= readLimit else { throw RemoteFileError.tooLarge(readLimit) }
                progress.chargedBytes -= reservation - data.count
                progress.bytesRead += data.count
                var update = progress
                switch DocumentPolicy.decode(data, filename: entry.name, maxBytes: readLimit) {
                case .text(let text, _):
                    if let match = firstMatch(in: text, query: query, entry: entry) {
                        matched += 1; update.contentMatches = [match]
                    }
                case .empty: break
                default: progress.skippedFiles += 1
                }
                update.copyContentProgress(from: progress)
                report(update)
                break
            }
        }
    }

    private static func isText(_ name: String) -> Bool {
        switch DocumentPolicy.kind(filename: name) {
        case .plainText, .markdown, .html, .svg: return true
        default: return false
        }
    }

    private static func firstMatch(in text: String, query: String, entry: RemoteEntry) -> ContentMatch? {
        guard let range = text.range(of: query, options: [.caseInsensitive]) else { return nil }
        let before = text[..<range.lowerBound]
        let line = before.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        let lineStart = before.lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.lowerBound...].firstIndex(where: \.isNewline) ?? text.endIndex
        // A bounded context around the first match also handles huge single-line files safely.
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: lineStart) ?? lineStart
        let end = text.index(range.lowerBound, offsetBy: 150, limitedBy: lineEnd) ?? lineEnd
        let context = String(text[start..<end]).replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return ContentMatch(entry: entry, line: line, snippet: (start > lineStart ? "…" : "") + context + (end < lineEnd ? "…" : ""))
    }
}

extension RemoteFolderSearch.Update {
    mutating func copyContentProgress(from other: Self) {
        filesSearched = other.filesSearched; skippedFiles = other.skippedFiles
        unreadableFiles = other.unreadableFiles; bytesRead = other.bytesRead; chargedBytes = other.chargedBytes
    }
}
