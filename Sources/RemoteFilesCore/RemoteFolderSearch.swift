import Foundation

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
        public var concurrentListings: Int
        public init(maxDepth: Int = 16, maxFolders: Int = 1_000, maxMatches: Int = 500,
                    timeLimit: Duration = .seconds(30), concurrentListings: Int = 4) {
            self.maxDepth = maxDepth; self.maxFolders = maxFolders; self.maxMatches = maxMatches
            self.timeLimit = timeLimit; self.concurrentListings = max(1, concurrentListings)
        }
    }

    /// Why a search ended before every folder was listed.
    public enum Stop: Sendable, Equatable { case folderLimit, matchLimit, timeLimit, fileLimit, byteLimit }

    public struct Update: Sendable {
        /// Matches found since the previous update, sorted by name within each folder.
        public var matches: [RemoteEntry] = []
        public var contentMatches: [ContentMatch] = []
        public var filesSearched = 0
        public var skippedFiles = 0
        public var unreadableFiles = 0
        public var bytesRead = 0
        /// Upper bound charged for reads, including unsuccessful reads and an EOF sentinel.
        public var chargedBytes = 0
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
                             limits: Limits = Limits()) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let walk = Task {
                do {
                    try await search(query: query, root: root, profile: profile, service: service,
                                     includeHidden: includeHidden, limits: limits, content: nil) { continuation.yield($0) }
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
    }

    static func search(query: String, root: String, profile: ConnectionProfile, service: any RemoteFileService,
                               includeHidden: Bool, limits: Limits, content: ContentLimits?, report: (Update) -> Void) async throws {
        try Task.checkCancellation()
        if let server = service as? any ServerFolderSearching,
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
        try await withThrowingTaskGroup(of: Listing.self) { group in
            // Refill before polling, including after consuming the last child, and finish only
            // when there are no queued listings to start and no outstanding results to consume.
            while true {
                try Task.checkCancellation()
                while running < limits.concurrentListings, started < queue.count, progress.stop == nil {
                    guard started < limits.maxFolders else { progress.stop = .folderLimit; break }
                    guard ContinuousClock.now < deadline else { progress.stop = .timeLimit; break }
                    let index = started, path = queue[index].path
                    group.addTask {
                        do { return Listing(index: index, result: .success(try await service.listDirectory(profile: profile, path: path))) }
                        catch { return Listing(index: index, result: .failure(error)) }
                    }
                    running += 1; started += 1
                }
                guard running > 0, let listing = try await group.next() else { break }
                let index = listing.index, result = listing.result
                running -= 1
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
                    group.addTask {
                        do { return Listing(index: index, result: .success(try await service.listDirectory(profile: profile, path: path))) }
                        catch { return Listing(index: index, result: .failure(error)) }
                    }
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
                                matched: &matched, progress: &progress, report: report)
                            if matched >= limits.maxMatches, reported < queue.count { progress.stop = .matchLimit }
                        } else {
                            let found = visible.filter { $0.name.localizedCaseInsensitiveContains(query) }
                            let kept = found.prefix(max(0, limits.maxMatches - matched))
                            matched += kept.count
                            update.matches = Array(kept)
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
