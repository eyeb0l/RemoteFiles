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
        public let page: Int?
        public init(entry: RemoteEntry, line: Int, snippet: String, page: Int? = nil) {
            self.entry = entry; self.line = line; self.snippet = snippet; self.page = page
        }
    }

    /// Uses server assistance when available, otherwise reads candidate UTF-8 files one at a time.
    /// Rich-document extraction and custom matching use bounded SFTP reads. Canonical reads stay within root.
    static func contents(matching query: String, below root: String, profile: ConnectionProfile,
                         service: any RemoteFileService, includeHidden: Bool,
                         limits: Limits = Limits(), contentLimits: ContentLimits = ContentLimits(),
                         options: SearchQueryOptions = .init(), extraction: SearchExtractionOptions = .init()) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let walk = Task {
                do {
                    if query.isEmpty {
                        var final = Update(); final.isFinished = true; continuation.yield(final)
                    } else {
                        try await search(query: query, root: root, profile: profile, service: service,
                            includeHidden: includeHidden, limits: limits, content: contentLimits, options: options, extraction: extraction) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in walk.cancel() }
        }
    }
}

/// Starts reading the files a content walk will reach next, because over a distant connection each read
/// takes about four round trips and one at a time is what limits the walk. It only overlaps those round
/// trips: each read makes its own confinement checks, the walk still handles files strictly in order, and
/// what is read ahead counts against the byte budget from the moment it starts, so the limit still holds.
/// Used from the walk's task alone.
final class SearchReadAhead {
    /// Reads started and not yet taken. Results wait here, so this also bounds what is held in memory.
    static let window = 32
    /// Expected bytes those reads may add up to. A read's deadline includes its wait behind the others,
    /// so a window of large files over a slow link must not outlast it. There's always room for one.
    static let bytesInFlight = 2 * 1024 * 1024
    /// How far a file may grow past its listed size and still be read ahead. Beyond this it gets an ordinary read.
    static let growthAllowance = 64 * 1024

    private struct Read { let task: Task<Data, Error>; let reservation: Int; let expected: Int }
    private let service: any RemoteFileService, profile: ConnectionProfile, root: String, limits: RemoteFolderSearch.ContentLimits
    private var waiting: [RemoteEntry] = [], nextWaiting = 0
    private var taken = Set<Data>()
    private var reads: [Data: Read] = [:]
    private(set) var reserved = 0
    private var expected = 0

    init(service: any RemoteFileService, profile: ConnectionProfile, root: String, limits: RemoteFolderSearch.ContentLimits) {
        self.service = service; self.profile = profile; self.root = root; self.limits = limits
    }

    /// Files the walk will read, in the order it will want them. Only those with a listed size are read ahead.
    func offer(_ entries: some Sequence<RemoteEntry>) {
        waiting.append(contentsOf: entries.lazy.filter { $0.size != nil })
    }

    /// Starts what fits, given what the walk has charged and how many files it has counted so far.
    func fill(charged: Int, files: Int) {
        while reads.count < Self.window, nextWaiting < waiting.count, files + reads.count < limits.maxFiles {
            let entry = waiting[nextWaiting], key = Data(entry.path.utf8)
            if taken.contains(key) || reads[key] != nil { nextWaiting += 1; continue }
            let size = Int(clamping: entry.size ?? 0), limit = min(limits.maxFileBytes, size + Self.growthAllowance)
            guard charged + reserved + limit + 1 < limits.maxTotalBytes, reads.isEmpty || expected + size <= Self.bytesInFlight else { return }
            let service = service, profile = profile, root = root, path = entry.path
            reads[key] = Read(task: Task { try await service.readSearchFile(profile: profile, path: path, canonicalRoot: root, limit: limit) }, reservation: limit + 1, expected: size)
            reserved += limit + 1; expected += size
            nextWaiting += 1
        }
        // Don't let a long walk's handled entries pile up.
        if nextWaiting > 4_096 { waiting.removeFirst(nextWaiting); nextWaiting = 0 }
    }

    /// The result of reading this file ahead, or nil if the walk should read it itself: not started, or it
    /// turned out too large for the read ahead or for what the walk can still afford.
    func take(_ entry: RemoteEntry, within limit: Int) async -> Result<Data, Error>? {
        let key = Data(entry.path.utf8)
        taken.insert(key)
        guard let read = reads.removeValue(forKey: key) else { return nil }
        reserved -= read.reservation; expected -= read.expected
        let task = read.task
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        switch result {
        case .failure(RemoteFileError.tooLarge): return nil
        case .success(let data) where data.count > limit: return nil
        default: return result
        }
    }

    func cancelAll() {
        reads.values.forEach { $0.task.cancel() }
        reads.removeAll(); reserved = 0; expected = 0; waiting.removeAll(); nextWaiting = 0
    }
}

extension RemoteFolderSearch {
    static func scan(_ entries: [RemoteEntry], query: String, root: String, profile: ConnectionProfile,
                     service: any RemoteFileService, limits: ContentLimits, matchLimit: Int,
                     deadline: ContinuousClock.Instant, matched: inout Int, progress: inout Update, options: SearchQueryOptions, extraction: SearchExtractionOptions,
                     collect: ((SearchIndexDocument) -> Void)?, reusable: ((RemoteEntry) -> SearchIndexDocument?)? = nil,
                     readAhead: SearchReadAhead? = nil, report: (Update) -> Void) async throws {
        for entry in entries {
            try Task.checkCancellation()
            if entry.kind == .directory || !options.accepts(entry) { continue }
            guard scanReads(entry, root: root, limits: limits, options: options, extraction: extraction) else {
                progress.skippedFiles += 1; continue
            }
            guard matched < matchLimit else { progress.stop = .matchLimit; break }
            guard progress.filesSearched < limits.maxFiles else { progress.stop = .fileLimit; break }
            guard ContinuousClock.now < deadline else { progress.stop = .timeLimit; break }
            // An index update keeps the text of a file whose size and modification date are
            // unchanged, without reading it. It still counts towards the file and text limits.
            if let reused = reusable?(entry) {
                let text = reused.segments.reduce(0) { $0 + $1.text.utf8.count }
                if text <= 16 * 1_024 * 1_024 - progress.extractedBytes {
                    progress.filesSearched += 1; progress.reusedFiles += 1; progress.extractedBytes += text
                    var update = progress
                    collect?(SearchIndexDocument(entry: entry, segments: reused.segments, isTruncated: false))
                    for segment in reused.segments {
                        if let match = firstMatch(in: segment.text, query: query, entry: entry, options: options, page: segment.page) {
                            matched += 1; update.contentMatches = [match]; break
                        }
                    }
                    update.copyContentProgress(from: progress)
                    report(update)
                    continue
                }
            }
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
                    readAhead?.fill(charged: progress.chargedBytes, files: progress.filesSearched)
                    if let ahead = await readAhead?.take(entry, within: readLimit) {
                        data = try ahead.get()
                    } else {
                        data = try await service.readSearchFile(profile: profile, path: entry.path, canonicalRoot: root, limit: readLimit)
                    }
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
                do {
                    var boundedExtraction = extraction
                    let remainingText = 16 * 1_024 * 1_024 - progress.extractedBytes
                    guard remainingText > 0 else { progress.stop = .byteLimit; return }
                    boundedExtraction.maxTextBytes = min(extraction.maxTextBytes, remainingText)
                    let extracted = try await SearchDocumentExtractor.extract(data, filename: entry.name,
                        options: boundedExtraction, deadline: deadline)
                    try Task.checkCancellation()
                    progress.extractedBytes += extracted.segments.reduce(0) { $0 + $1.text.utf8.count }
                    if extracted.isTruncated { progress.truncatedFiles += 1 }
                    collect?(SearchIndexDocument(entry: entry, segments: extracted.segments, isTruncated: extracted.isTruncated))
                    for segment in extracted.segments {
                        if let match = firstMatch(in: segment.text, query: query, entry: entry, options: options, page: segment.page) {
                            matched += 1; update.contentMatches = [match]; break
                        }
                    }
                } catch {
                    try Task.checkCancellation()
                    if ContinuousClock.now >= deadline { progress.stop = .timeLimit; return }
                    progress.skippedFiles += 1
                }
                update.copyContentProgress(from: progress)
                report(update)
                break
            }
        }
    }

    /// Whether `scan` would read this entry, leaving aside the limits it applies as it goes.
    static func scanReads(_ entry: RemoteEntry, root: String, limits: ContentLimits, options: SearchQueryOptions, extraction: SearchExtractionOptions) -> Bool {
        entry.kind == .file && options.accepts(entry) && RemoteResourcePath.contains(entry.path, in: root)
            && SearchDocumentExtractor.supports(filename: entry.name, options: extraction)
            && (entry.size.map { $0 <= UInt64(limits.maxFileBytes) } ?? true)
    }

    static func firstMatch(in text: String, query: String, entry: RemoteEntry,
                           options: SearchQueryOptions = .init(), page: Int? = nil) -> ContentMatch? {
        guard let range = options.range(in: text, query: query) else { return nil }
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
        return ContentMatch(entry: entry, line: line, snippet: (start > lineStart ? "…" : "") + context + (end < lineEnd ? "…" : ""), page: page)
    }
}

extension RemoteFolderSearch.Update {
    mutating func copyContentProgress(from other: Self) {
        extractedBytes = other.extractedBytes; truncatedFiles = other.truncatedFiles
        filesSearched = other.filesSearched; skippedFiles = other.skippedFiles
        unreadableFiles = other.unreadableFiles; bytesRead = other.bytesRead; chargedBytes = other.chargedBytes
        reusedFiles = other.reusedFiles
    }
}
