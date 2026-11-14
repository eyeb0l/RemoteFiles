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

/// What a walk waits for: results posted by its listings, and reads ahead finishing. Its one task waits for
/// whichever comes first, and takes the results without waiting.
final class SearchWalkEvents<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result] = []
    private var events = 0
    private var waiter: CheckedContinuation<Void, Never>?
    /// How many events there have been; pass it to `wait(after:)` so none that comes after it is missed.
    var count: Int { lock.lock(); defer { lock.unlock() }; return events }
    func post(_ result: Result) { signal { results.append(result) } }
    /// Something finished that left nothing to take.
    func nudge() { signal {} }
    func take() -> [Result] {
        lock.lock(); let taken = results; results = []; lock.unlock()
        return taken
    }
    /// Returns once there has been an event after `count`, or the task is cancelled.
    func wait(after count: Int) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                guard events == count, !Task.isCancelled else { lock.unlock(); continuation.resume(); return }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock(); let waiter = self.waiter; self.waiter = nil; lock.unlock()
            waiter?.resume()
        }
    }
    private func signal(_ change: () -> Void) {
        lock.lock(); change(); events += 1
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

/// Starts reading the files a content walk will reach next, because over a distant connection each read
/// takes about four round trips and one at a time is what limits the walk. It only overlaps those round
/// trips: each read makes its own confinement checks and the walk still handles files strictly in order.
///
/// Files are offered in the walk's order and started in that order, so a read under way is always for a
/// file after the one the walk is on. Each read's limit is charged to the walk as it starts and stays
/// charged even if the read is never used, so the file and byte limits hold for everything sent.
/// Used from the walk's task alone.
final class SearchReadAhead {
    /// Reads started and not yet taken. Results wait here, so this also bounds what is held in memory.
    static let window = 32
    /// Expected bytes those reads may add up to. A read's deadline includes its wait behind the others,
    /// so a window of large files over a slow link must not outlast it. There's always room for one.
    static let bytesInFlight = 2 * 1024 * 1024
    /// How far a file may grow past its listed size and still be read ahead. Beyond this it gets an ordinary read.
    static let growthAllowance = 64 * 1024

    /// A read that was started ahead, with the charge it was given when it started.
    struct Taken { let result: Result<Data, Error>; let reservation: Int }
    private final class Read: @unchecked Sendable {
        let reservation: Int, expected: Int
        var task: Task<Data, Error>?
        private let lock = NSLock()
        private var done = false
        init(reservation: Int, expected: Int) { self.reservation = reservation; self.expected = expected }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return done }
        func finish() { lock.lock(); done = true; lock.unlock() }
    }
    private let service: any RemoteFileService, profile: ConnectionProfile, root: String, limits: RemoteFolderSearch.ContentLimits
    private let events: (any SearchWalkSignal)?
    private var waiting: [RemoteEntry] = [], nextWaiting = 0, offered = 0
    private var taken = Set<Data>()
    private var reads: [Data: Read] = [:]
    private var expected = 0

    /// `events` hears of every read that finishes, so a walk waiting for one can do other work meanwhile.
    init(service: any RemoteFileService, profile: ConnectionProfile, root: String, limits: RemoteFolderSearch.ContentLimits,
         events: (any SearchWalkSignal)? = nil) {
        self.service = service; self.profile = profile; self.root = root; self.limits = limits; self.events = events
    }

    /// Files the walk will read, in the order it will read them. The walk reads no more than the file
    /// limit, so no more than that are kept, however many folders an index lists before it reads.
    func offer(_ entries: some Sequence<RemoteEntry>) {
        let kept = Array(entries.prefix(max(0, limits.maxFiles - offered)))
        offered += kept.count
        waiting.append(contentsOf: kept)
    }

    /// Starts what fits, given what the walk has charged and the files it has counted, including the one it
    /// is on. Returns the bytes it reserved, which the walk must charge at once.
    func fill(charged: Int, files: Int) -> Int {
        // A read starts in a task of its own, which wouldn't inherit a cancellation that has already happened.
        guard !Task.isCancelled else { return 0 }
        var added = 0
        while reads.count < Self.window, nextWaiting < waiting.count, files + reads.count < limits.maxFiles {
            let entry = waiting[nextWaiting], key = Data(entry.path.utf8)
            if taken.contains(key) || reads[key] != nil { nextWaiting += 1; continue }
            // Nothing later may start before this one, so a file without a size, or one that doesn't fit,
            // stops reading ahead until the walk has read it itself.
            guard let listed = entry.size else { break }
            let size = Int(clamping: listed), limit = min(limits.maxFileBytes, size + Self.growthAllowance)
            guard charged + added + limit + 1 < limits.maxTotalBytes, reads.isEmpty || expected + size <= Self.bytesInFlight else { break }
            let read = Read(reservation: limit + 1, expected: size)
            let service = service, profile = profile, root = root, path = entry.path, events = events
            read.task = Task {
                defer { read.finish(); events?.nudge() }
                return try await service.readSearchFile(profile: profile, path: path, canonicalRoot: root, limit: limit)
            }
            reads[key] = read
            added += limit + 1; expected += size
            nextWaiting += 1
        }
        // Don't let a long walk's handled entries pile up.
        if nextWaiting > 4_096 { waiting.removeFirst(nextWaiting); nextWaiting = 0 }
        SearchPipelineMetrics.shared.note(reads: reads.count, expectedBytes: expected,
                                          reservedBytes: reads.values.reduce(0) { $0 + $1.reservation })
        return added
    }

    /// Whether this file's read was started ahead and is still under way.
    func isUnderWay(_ entry: RemoteEntry) -> Bool {
        reads[Data(entry.path.utf8)].map { !$0.isFinished } ?? false
    }

    /// Whether this file's read has already finished, so using it starts no new work.
    func hasFinished(_ entry: RemoteEntry) -> Bool {
        reads[Data(entry.path.utf8)]?.isFinished == true
    }

    /// The file's read, if it was started ahead; nil if the walk must read it itself.
    func take(_ entry: RemoteEntry) async -> Taken? {
        let key = Data(entry.path.utf8)
        taken.insert(key)
        guard let read = reads.removeValue(forKey: key), let task = read.task else { return nil }
        expected -= read.expected
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        return Taken(result: result, reservation: read.reservation)
    }

    /// Reads not taken stay charged: they may already have transferred bytes.
    func cancelAll() {
        reads.values.forEach { $0.task?.cancel() }
        reads.removeAll(); expected = 0; waiting.removeAll(); nextWaiting = 0
    }
}

/// Benchmarks only: the most a content search has had in flight at once since `reset()`. Searches run one at a
/// time in the benchmark, so one shared record is enough. Costs a lock each time a search starts work.
final class SearchPipelineMetrics: @unchecked Sendable {
    struct Peaks: Sendable {
        /// Reads started ahead and not yet taken, their listed sizes and what they were charged.
        var reads = 0, expectedBytes = 0, reservedBytes = 0
        /// Listings under way, and folders listed or being listed that the walk hasn't reported yet.
        var listings = 0, foldersAhead = 0
    }
    static let shared = SearchPipelineMetrics()
    private let lock = NSLock()
    private var peaks = Peaks()
    var current: Peaks { lock.lock(); defer { lock.unlock() }; return peaks }
    func reset() { lock.lock(); peaks = Peaks(); lock.unlock() }
    func note(reads: Int, expectedBytes: Int, reservedBytes: Int) {
        lock.lock()
        peaks.reads = max(peaks.reads, reads); peaks.expectedBytes = max(peaks.expectedBytes, expectedBytes)
        peaks.reservedBytes = max(peaks.reservedBytes, reservedBytes)
        lock.unlock()
    }
    func note(listings: Int, foldersAhead: Int) {
        lock.lock()
        peaks.listings = max(peaks.listings, listings); peaks.foldersAhead = max(peaks.foldersAhead, foldersAhead)
        lock.unlock()
    }
}

/// Lets a walk wait for anything to finish: a listing, or a read ahead.
protocol SearchWalkSignal: AnyObject, Sendable {
    var count: Int { get }
    func nudge()
    func wait(after count: Int) async
}
extension SearchWalkEvents: SearchWalkSignal {}

extension RemoteFolderSearch {
    static func scan(_ entries: [RemoteEntry], query: String, root: String, profile: ConnectionProfile,
                     service: any RemoteFileService, limits: ContentLimits, matchLimit: Int,
                     deadline: ContinuousClock.Instant, matched: inout Int, progress: inout Update, options: SearchQueryOptions, extraction: SearchExtractionOptions,
                     collect: ((SearchIndexDocument) -> Void)?, reusable: ((RemoteEntry) -> SearchIndexDocument?)? = nil,
                     readAhead: SearchReadAhead? = nil, events: (any SearchWalkSignal)? = nil,
                     between: (inout Update) -> Void = { _ in }, report: (Update) -> Void) async throws {
        for entry in entries {
            try Task.checkCancellation()
            if entry.kind == .directory || !options.accepts(entry) { continue }
            guard scanReads(entry, root: root, limits: limits, options: options, extraction: extraction) else {
                progress.skippedFiles += 1; continue
            }
            guard matched < matchLimit else { progress.stop = .matchLimit; break }
            guard progress.filesSearched < limits.maxFiles else { progress.stop = .fileLimit; break }
            // After the deadline no new read starts, but one already finished is kept.
            guard ContinuousClock.now < deadline || readAhead?.hasFinished(entry) == true else { progress.stop = .timeLimit; break }
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
            var retried = false, counted = false, ahead = readAhead != nil
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline || (ahead && readAhead?.hasFinished(entry) == true) else { progress.stop = .timeLimit; return }
                if !counted { progress.filesSearched += 1; counted = true }
                // The walk accepts listings that finished meanwhile, so their files can be read ahead too.
                between(&progress)
                var outcome: Result<Data, Error>?, readLimit = 0, reservation = 0
                if ahead, let readAhead {
                    ahead = false
                    if ContinuousClock.now < deadline {
                        progress.chargedBytes += readAhead.fill(charged: progress.chargedBytes, files: progress.filesSearched)
                    }
                    // While its read is under way, the walk goes on accepting listings as they finish, so that later
                    // folders' files start reading meanwhile.
                    if let events {
                        while true {
                            let seen = events.count
                            guard readAhead.isUnderWay(entry) else { break }
                            await events.wait(after: seen)
                            try Task.checkCancellation()
                            between(&progress)
                        }
                    }
                    // Its reservation was charged when it started. A file that grew past it gets an ordinary
                    // read, with a charge of its own; the first one stays.
                    if let taken = await readAhead.take(entry) {
                        reservation = taken.reservation; readLimit = reservation - 1
                        if case .failure(RemoteFileError.tooLarge) = taken.result {} else { outcome = taken.result }
                    }
                }
                if outcome == nil {
                    guard ContinuousClock.now < deadline else { progress.stop = .timeLimit; return }
                    // Allow the transport its extra EOF byte even if a file grows after the listing.
                    let remaining = limits.maxTotalBytes - progress.chargedBytes
                    guard remaining > 1 else { progress.stop = .byteLimit; return }
                    readLimit = min(limits.maxFileBytes, remaining - 1)
                    reservation = readLimit + 1
                    progress.chargedBytes += reservation
                    do { outcome = .success(try await service.readSearchFile(profile: profile, path: entry.path, canonicalRoot: root, limit: readLimit)) }
                    catch { outcome = .failure(error) }
                }
                let data: Data
                do {
                    data = try (outcome ?? .failure(CancellationError())).get()
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
        // Characters don't bound bytes: one can carry any number of combining marks. Keep the
        // bytes nearest the match on each side.
        let head = text[start..<range.lowerBound].unicodeScalars, tail = text[range.lowerBound..<end].unicodeScalars
        var leading = head.endIndex, leadingBytes = 0
        while leading > head.startIndex {
            let previous = head.index(before: leading), size = UTF8.width(head[previous])
            guard leadingBytes + size <= snippetLeadingBytes else { break }
            leading = previous; leadingBytes += size
        }
        // Marks cut off from their letter would attach to the ellipsis in front of them.
        if leading > head.startIndex {
            while leading < head.endIndex, [.nonspacingMark, .enclosingMark, .spacingMark].contains(head[leading].properties.generalCategory) {
                leading = head.index(after: leading)
            }
        }
        var trailing = tail.startIndex, trailingBytes = 0
        while trailing < tail.endIndex {
            let size = UTF8.width(tail[trailing])
            guard trailingBytes + size <= snippetTrailingBytes else { break }
            trailing = tail.index(after: trailing); trailingBytes += size
        }
        let context = (String(head[leading...]) + String(tail[..<trailing])).replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let cutBefore = start > lineStart || leading > head.startIndex, cutAfter = end < lineEnd || trailing < tail.endIndex
        return ContentMatch(entry: entry, line: line, snippet: (cutBefore ? "…" : "") + context + (cutAfter ? "…" : ""), page: page)
    }
    /// The most bytes of a line a result row shows on each side of where its match starts.
    static let snippetLeadingBytes = 100, snippetTrailingBytes = 300
}

extension RemoteFolderSearch.Update {
    mutating func copyContentProgress(from other: Self) {
        extractedBytes = other.extractedBytes; truncatedFiles = other.truncatedFiles
        filesSearched = other.filesSearched; skippedFiles = other.skippedFiles
        unreadableFiles = other.unreadableFiles; bytesRead = other.bytesRead; chargedBytes = other.chargedBytes
        reusedFiles = other.reusedFiles
    }
}
