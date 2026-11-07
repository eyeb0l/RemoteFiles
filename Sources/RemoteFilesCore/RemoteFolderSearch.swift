import Foundation

/// Listings for a walk over many folders, which needs names and kinds and not where links lead.
protocol FolderWalking: Sendable {
    func listDirectoryForWalk(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot
    func resolvingLinks(in entries: [RemoteEntry], profile: ConnectionProfile) async throws -> [RemoteEntry]
}

/// Finds names below a folder with optional read-only server assistance, falling back to the
/// ordinary file service when command access is unavailable. Links are matched by name but never followed, which
/// keeps the walk inside the folder and free of loops. Depth, folders listed, matches and time are
/// all bounded; whatever was found before a limit is kept.
public enum RemoteFolderSearch {
    public struct Limits: Sendable {
        /// Levels below the starting folder; deeper folders are counted but not listed.
        public var maxDepth: Int
        public var maxFolders: Int
        public var maxMatches: Int
        /// No new folder is listed after this; listings already sent finish within their own deadline.
        public var timeLimit: Duration
        /// Folders listed at once to begin with.
        public var concurrentListings: Int
        /// The most folders listed at once while the server keeps answering quickly. Over a distant
        /// connection a folder takes about three round trips whatever the server does, so this is what
        /// decides how long a search takes.
        public var concurrentListingLimit: Int
        public init(maxDepth: Int = 16, maxFolders: Int = 1_000, maxMatches: Int = 500, timeLimit: Duration = .seconds(30),
                    concurrentListings: Int = 8, concurrentListingLimit: Int = 64) {
            self.maxDepth = maxDepth; self.maxFolders = maxFolders; self.maxMatches = maxMatches
            self.timeLimit = timeLimit; self.concurrentListings = max(1, concurrentListings)
            self.concurrentListingLimit = max(self.concurrentListings, concurrentListingLimit)
        }
    }

    /// Why a search ended before every folder was listed.
    public enum Stop: Sendable, Equatable { case folderLimit, matchLimit, timeLimit, fileLimit, byteLimit }

    public struct Update: Sendable {
        /// Matches found since the previous update, sorted by name within each folder.
        public var matches: [RemoteEntry] = []
        public var contentMatches: [ContentMatch] = []
        public var filesSearched = 0
        /// Files an index update kept from the previous snapshot without reading; included in `filesSearched`.
        public var reusedFiles = 0
        public var skippedFiles = 0
        public var unreadableFiles = 0
        public var bytesRead = 0
        /// Upper bound charged for reads, including unsuccessful reads and an EOF sentinel.
        public var chargedBytes = 0
        public var extractedBytes = 0
        public var truncatedFiles = 0
        public var foldersSearched = 0
        /// Folders that could not be listed, for example for lack of permission. The search goes on.
        public var unreadableFolders = 0
        /// Folders below the depth limit, which were not listed.
        public var skippedDeepFolders = 0
        public var isFinished = false
        public var stop: Stop?
        public init() {}
    }

    /// Streams matches for `query` in `root` and its subfolders, breadth first. The starting folder
    /// failing ends the stream with its error. A subfolder that cannot be read, has gone, or times
    /// out is counted and skipped; one whose listing ends with the connection is listed once more,
    /// since another folder's timeout retires the shared channel, and ends the stream if it fails
    /// again. Hidden names
    /// are neither matched nor searched unless `includeHidden`. Ending the consumer cancels the walk.
    public static func names(matching query: String, below root: String, profile: ConnectionProfile,
                             service: any RemoteFileService, includeHidden: Bool,
                             limits: Limits = Limits(), options: SearchQueryOptions = .init()) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let walk = Task {
                do {
                    try await search(query: query, root: root, profile: profile, service: service,
                                     includeHidden: includeHidden, limits: limits, content: nil, options: options) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in walk.cancel() }
        }
    }

    private struct Folder: Sendable { let path: String; let depth: Int }
    // Keep the queue index attached to its result across task-group suspension points.
    // Optimized tuple results can repeat an earlier index and leave descendants unreported.
    private struct Listing: Sendable {
        let index: Int
        let result: Result<DirectorySnapshot, Error>
        let elapsed: Duration
    }

    /// Lists more folders at once while the server answers quickly, and backs off when answers slow:
    /// every listing has to finish within its own deadline, including the time it queues at the server.
    struct ListingPacing {
        static let quick: Duration = .milliseconds(1_000), slow: Duration = .seconds(3)
        private(set) var window: Int
        private let floor: Int, limit: Int
        init(limits: Limits) { window = limits.concurrentListings; floor = limits.concurrentListings; limit = limits.concurrentListingLimit }
        mutating func finished(after elapsed: Duration) {
            if elapsed < Self.quick { window = min(limit, window + 1) }
            else if elapsed > Self.slow { window = max(floor, window / 2) }
        }
    }

    static func search(query: String, root: String, profile: ConnectionProfile, service: any RemoteFileService,
                               includeHidden: Bool, limits: Limits, content: ContentLimits?,
                               options: SearchQueryOptions = .init(), extraction: SearchExtractionOptions = .init(),
                               collect: ((SearchIndexDocument) -> Void)? = nil,
                               reusable: ((RemoteEntry) -> SearchIndexDocument?)? = nil, report: (Update) -> Void) async throws {
        try Task.checkCancellation()
        if options == SearchQueryOptions(), extraction == SearchExtractionOptions(), collect == nil,
           let server = service as? any ServerFolderSearching,
           let update = try await server.searchFolders(query: query, root: root, profile: profile,
                                                       includeHidden: includeHidden, limits: limits, content: content) {
            try Task.checkCancellation()
            report(update)
            return
        }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now + limits.timeLimit
        var queue = [Folder(path: root, depth: 0)]
        // Folders are listed up to the window ahead, but reported strictly in queue order: nearer
        // folders always come first and count first towards the match limit.
        var started = 0, reported = 0, running = 0
        var finished: [Int: Result<DirectorySnapshot, Error>] = [:], retried: Set<Int> = []
        var progress = Update(), matched = 0
        var pacing = ListingPacing(limits: limits)
        let walker = service as? any FolderWalking
        let list: @Sendable (Int, String) async -> Listing = { index, path in
            let started = ContinuousClock.now
            do {
                let snapshot: DirectorySnapshot
                if let walker {
                    snapshot = try await walker.listDirectoryForWalk(profile: profile, path: path)
                } else {
                    snapshot = try await service.listDirectory(profile: profile, path: path)
                }
                return Listing(index: index, result: .success(snapshot), elapsed: started.duration(to: .now))
            } catch {
                return Listing(index: index, result: .failure(error), elapsed: started.duration(to: .now))
            }
        }
        try await withThrowingTaskGroup(of: Listing.self) { group in
            // Refill before polling, including after consuming the last child, and finish only
            // when there are no queued listings to start and no outstanding results to consume.
            while true {
                try Task.checkCancellation()
                while running < pacing.window, started < queue.count, progress.stop == nil {
                    guard started < limits.maxFolders else { progress.stop = .folderLimit; break }
                    guard ContinuousClock.now < deadline else { progress.stop = .timeLimit; break }
                    let index = started, path = queue[index].path
                    group.addTask { await list(index, path) }
                    running += 1; started += 1
                }
                guard running > 0, let listing = try await group.next() else { break }
                let index = listing.index, result = listing.result
                running -= 1
                pacing.finished(after: listing.elapsed)
                try Task.checkCancellation()
                if case .failure(let error) = result, index > 0, endsConnection(error), retried.insert(index).inserted {
                    // A peer's deadline retires the shared SFTP channel and fails the listings on it;
                    // list this folder once more on a fresh channel before giving up.
                    // Recovery starts another listing, so it shares the walk's scheduling deadline.
                    guard ContinuousClock.now < deadline else {
                        progress.stop = .timeLimit
                        group.cancelAll()
                        break
                    }
                    let path = queue[index].path
                    group.addTask { await list(index, path) }
                    running += 1
                    continue
                }
                finished[index] = result
                while let result = finished.removeValue(forKey: reported) {
                    let folder = queue[reported]; reported += 1
                    var update = Update()
                    switch result {
                    case .success(let snapshot):
                        if content != nil, !RemoteResourcePath.contains(snapshot.path, in: root) {
                            progress.unreadableFolders += 1
                            break // A listed folder may have become a link since its parent was read.
                        }
                        progress.foldersSearched += 1
                        let visible = snapshot.entries.filter { includeHidden || !$0.name.hasPrefix(".") }
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        for entry in visible where entry.kind == .directory {
                            if folder.depth < limits.maxDepth { queue.append(Folder(path: entry.path, depth: folder.depth + 1)) }
                            else { progress.skippedDeepFolders += 1 }
                        }
                        if let content {
                            try await scan(visible, query: query, root: root, profile: profile,
                                service: service, limits: content, matchLimit: limits.maxMatches, deadline: deadline,
                                matched: &matched, progress: &progress, options: options, extraction: extraction, collect: collect,
                                reusable: reusable, report: report)
                            if matched >= limits.maxMatches, reported < queue.count { progress.stop = .matchLimit }
                        } else {
                            let found = visible.filter { options.accepts($0) && options.range(in: $0.name, query: query) != nil }
                            let kept = found.prefix(max(0, limits.maxMatches - matched))
                            matched += kept.count
                            update.matches = Array(kept)
                            // A row says where a link leads, and only matches are shown.
                            if let walker, let resolved = try? await walker.resolvingLinks(in: update.matches, profile: profile) {
                                update.matches = resolved
                            }
                            // At the limit, stop unless this was the last folder there is to list.
                            if matched == limits.maxMatches, kept.count < found.count || reported < queue.count {
                                progress.stop = .matchLimit
                            }
                        }
                    case .failure(let error):
                        if error is CancellationError { throw error }
                        guard folder.depth > 0, isSkippable(error) else { throw error }
                        progress.unreadableFolders += 1
                    }
                    update.foldersSearched = progress.foldersSearched
                    update.unreadableFolders = progress.unreadableFolders
                    update.skippedDeepFolders = progress.skippedDeepFolders
                    update.copyContentProgress(from: progress)
                    update.stop = progress.stop
                    report(update)
                    if progress.stop == .matchLimit || (content != nil && stopsReading(progress.stop)) { break }
                }
                if progress.stop == .matchLimit || (content != nil && stopsReading(progress.stop)) { group.cancelAll(); break }
            }
        }
        try Task.checkCancellation()
        var final = Update()
        final.foldersSearched = progress.foldersSearched
        final.unreadableFolders = progress.unreadableFolders
        final.skippedDeepFolders = progress.skippedDeepFolders
        final.copyContentProgress(from: progress)
        final.stop = progress.stop
        final.isFinished = true
        report(final)
    }

    private static func stopsReading(_ stop: Stop?) -> Bool {
        stop == .matchLimit || stop == .fileLimit || stop == .byteLimit || stop == .timeLimit
    }

    private static func endsConnection(_ error: Error) -> Bool {
        if case RemoteFileError.connectionEnded = error { return true }
        return false
    }

    /// One folder's failure that leaves the rest of the search meaningful.
    private static func isSkippable(_ error: Error) -> Bool {
        switch error {
        case RemoteFileError.permissionDenied, RemoteFileError.notFound, RemoteFileError.timedOut: return true
        default: return false
        }
    }
}
