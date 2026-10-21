import Foundation

/// Finds names below a folder by listing its subfolders with the ordinary file service, so it
/// needs no shell access and stays read-only. Links are matched by name but never followed, which
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
    public enum Stop: Sendable, Equatable { case folderLimit, matchLimit, timeLimit }

    public struct Update: Sendable {
        /// Matches found since the previous update, sorted by name within each folder.
        public var matches: [RemoteEntry] = []
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
    /// failing ends the stream with its error, as does a failure that ends the connection; a
    /// subfolder that cannot be read, has gone, or times out is counted and skipped. Hidden names
    /// are neither matched nor searched unless `includeHidden`. Ending the consumer cancels the walk.
    public static func names(matching query: String, below root: String, profile: ConnectionProfile,
                             service: any RemoteFileService, includeHidden: Bool,
                             limits: Limits = Limits()) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let walk = Task {
                do {
                    try await search(query: query, root: root, profile: profile, service: service,
                                     includeHidden: includeHidden, limits: limits) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in walk.cancel() }
        }
    }

    private struct Folder: Sendable { let path: String; let depth: Int }

    private static func search(query: String, root: String, profile: ConnectionProfile, service: any RemoteFileService,
                               includeHidden: Bool, limits: Limits, report: (Update) -> Void) async throws {
        let deadline = ContinuousClock.now + limits.timeLimit
        var queue = [Folder(path: root, depth: 0)], next = 0
        var progress = Update(), matched = 0
        try await withThrowingTaskGroup(of: (Folder, Result<DirectorySnapshot, Error>).self) { group in
            var running = 0, listed = 0
            func startListings() {
                while running < limits.concurrentListings, next < queue.count, progress.stop == nil {
                    guard listed < limits.maxFolders else { progress.stop = .folderLimit; return }
                    guard ContinuousClock.now < deadline else { progress.stop = .timeLimit; return }
                    let folder = queue[next]; next += 1
                    running += 1; listed += 1
                    group.addTask {
                        do { return (folder, .success(try await service.listDirectory(profile: profile, path: folder.path))) }
                        catch { return (folder, .failure(error)) }
                    }
                }
            }
            startListings()
            while let (folder, result) = try await group.next() {
                running -= 1
                try Task.checkCancellation()
                var update = Update()
                switch result {
                case .success(let snapshot):
                    progress.foldersSearched += 1
                    let visible = snapshot.entries.filter { includeHidden || !$0.name.hasPrefix(".") }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    for entry in visible where entry.kind == .directory {
                        if folder.depth < limits.maxDepth { queue.append(Folder(path: entry.path, depth: folder.depth + 1)) }
                        else { progress.skippedDeepFolders += 1 }
                    }
                    let found = visible.filter { $0.name.localizedCaseInsensitiveContains(query) }
                    let kept = found.prefix(limits.maxMatches - matched)
                    matched += kept.count
                    update.matches = Array(kept)
                    // At the limit, stop unless this folder was the last one left to list.
                    if matched == limits.maxMatches, kept.count < found.count || next < queue.count || running > 0 {
                        progress.stop = .matchLimit
                    }
                case .failure(let error):
                    if error is CancellationError { throw error }
                    guard folder.depth > 0, isSkippable(error) else { throw error }
                    progress.unreadableFolders += 1
                }
                if progress.stop == .matchLimit { group.cancelAll() } else { startListings() }
                update.foldersSearched = progress.foldersSearched
                update.unreadableFolders = progress.unreadableFolders
                update.skippedDeepFolders = progress.skippedDeepFolders
                update.stop = progress.stop
                report(update)
                if progress.stop == .matchLimit { break }
            }
        }
        try Task.checkCancellation()
        var final = Update()
        final.foldersSearched = progress.foldersSearched
        final.unreadableFolders = progress.unreadableFolders
        final.skippedDeepFolders = progress.skippedDeepFolders
        final.stop = progress.stop
        final.isFinished = true
        report(final)
    }

    /// One folder's failure that leaves the rest of the search meaningful.
    private static func isSkippable(_ error: Error) -> Bool {
        switch error {
        case RemoteFileError.permissionDenied, RemoteFileError.notFound, RemoteFileError.timedOut: return true
        default: return false
        }
    }
}
