import Foundation
import RemoteFilesCore

/// One symbol per kind of file, shared by folders, recents and the offline library.
enum FileSymbol {
    private static let code: Set<String> = [
        "swift", "js", "jsx", "ts", "tsx", "py", "rb", "sh", "bash", "zsh", "c", "h", "cc", "cpp", "hpp", "m", "mm",
        "rs", "go", "java", "kt", "kts", "php", "sql", "lua", "dart", "css", "scss", "less", "json", "jsonl", "yaml",
        "yml", "toml", "xml", "diff", "patch", "graphql", "gql", "vue", "svelte",
    ]
    private static let archives: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg"]
    static func name(forFilename filename: String) -> String {
        switch DocumentPolicy.kind(filename: filename) {
        case .markdown, .html, .pdf, .svg: return "doc.richtext"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .certificate: return "person.text.rectangle"
        case .protectedCertificate: return "lock.doc"
        case .plainText, .unsupported:
            let suffix = (filename as NSString).pathExtension.lowercased()
            if code.contains(suffix) { return "chevron.left.forwardslash.chevron.right" }
            if archives.contains(suffix) { return "archivebox" }
            return "doc.text"
        }
    }
}

/// A row of a folder. Its descriptions are worked out when shown: formatting a size alone takes about
/// 4 µs, which over a whole folder was more than half of preparing it.
struct FolderRow: Identifiable, Sendable {
    let entry: RemoteEntry
    var id: String { entry.path }
    /// A plain folder's icon already says "Folder", so its row shows only the name.
    var visibleSubtitle: String? { entry.kind == .directory && entry.link == nil ? nil : subtitle }

    init(_ entry: RemoteEntry) { self.entry = entry }

    var symbol: String {
        switch entry.link {
        case .target(let target): return Self.symbol(of: target)
        case .broken: return "link"
        case nil: return Self.symbol(of: entry)
        }
    }

    /// What VoiceOver and search results say about the row.
    var subtitle: String {
        switch entry.link {
        case .target(let target):
            // A resolved link looks like what it opens, and says it is a link.
            return target.kind == .directory ? "Link to folder" : (["Link to file"] + Self.details(of: target)).joined(separator: " · ")
        case .broken:
            return "Broken link"
        case nil:
            switch entry.kind {
            case .directory: return "Folder"
            case .symlink: return "Symbolic link"
            case .file, .other:
                let details = Self.details(of: entry)
                return details.isEmpty ? "File" : details.joined(separator: " · ")
            }
        }
    }

    private static func symbol(of entry: RemoteEntry) -> String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink: return "link"
        case .file, .other: return FileSymbol.name(forFilename: entry.name)
        }
    }

    private static func details(of entry: RemoteEntry) -> [String] {
        guard entry.kind == .file || entry.kind == .other else { return [] }
        var details: [String] = []
        if let size = entry.size { details.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)) }
        if let date = entry.modifiedAt { details.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return details
    }
}

enum FolderSortOrder: String, CaseIterable, Sendable {
    case name, modified, size, kind
    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

/// Prepared away from the main actor and retained for an immediate return to a folder.
struct FolderListing: Sendable {
    let path: String
    let rows: [FolderRow]
    let defaultRows: [FolderRow]
    init(_ snapshot: DirectorySnapshot) {
        path = snapshot.path
        rows = Self.sortedByName(snapshot.entries).map(FolderRow.init)
        // Without hidden names the two arrays share one buffer.
        defaultRows = rows.contains { $0.entry.name.hasPrefix(".") } ? rows.filter { !$0.entry.name.hasPrefix(".") } : rows
    }
    func visible(query: String, showHidden: Bool, order: FolderSortOrder, options: SearchQueryOptions = .init()) -> [FolderRow] {
        if query.isEmpty && order == .name && options == SearchQueryOptions() { return showHidden ? rows : defaultRows }
        let filter = FolderFilter(query: query, options: options)
        let source = showHidden ? rows : defaultRows
        let result = filter.isEmpty ? source : source.filter { filter.accepts($0.entry) }
        guard order != .name else { return result }
        return Self.sorted(result, by: order)
    }

    /// Folders first, then by name. Equivalent to sorting with `precedes(_:_:by: .name)`, whose
    /// `localizedStandardCompare` spends most of its time bridging each name again on every
    /// comparison: bridging once made this 60-70% faster on iPhone 17 Pro.
    /// `FolderBrowsingTests` checks that the two orders stay identical.
    static func sortedByName(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        struct Key { let isFolder: Bool; let name: CFString; let length: CFIndex; let index: Int32 }
        let keys = entries.enumerated().map { index, entry -> Key in
            let name = entry.name as NSString as CFString
            return Key(isFolder: entry.effectiveKind == .directory, name: name, length: CFStringGetLength(name), index: Int32(index))
        }
        let locale = Locale.current as CFLocale
        let flags: CFStringCompareFlags = [.compareCaseInsensitive, .compareNonliteral, .compareLocalized, .compareNumerically,
                                           .compareWidthInsensitive, .compareForcedOrdering]
        return keys.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return CFStringCompareWithOptionsAndLocale(lhs.name, rhs.name, CFRange(location: 0, length: lhs.length), flags, locale) == .compareLessThan
        }.map { entries[Int($0.index)] }
    }

    /// Reorders rows already in name order. Each row's key is read once and ties keep their position,
    /// which is name order, so no name is compared again. Equivalent to sorting with
    /// `precedes(_:_:by:)` and 20 times as fast at every size measured; see docs/PERFORMANCE.md.
    static func sorted(_ rows: [FolderRow], by order: FolderSortOrder) -> [FolderRow] {
        func keyed<K: Comparable>(_ value: (Int, RemoteEntry, Bool) -> K) -> [FolderRow] {
            let keys = rows.enumerated().map { index, row -> (isFolder: Bool, value: K, index: Int32) in
                let isFolder = row.entry.effectiveKind == .directory
                return (isFolder, value(index, row.entry, isFolder), Int32(index))
            }
            return keys.sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.index < rhs.index
            }.map { rows[Int($0.index)] }
        }
        switch order {
        case .name:
            return rows
        case .modified:
            return keyed { _, entry, _ in -((entry.linkTarget ?? entry).modifiedAt ?? .distantPast).timeIntervalSinceReferenceDate }
        case .size:
            return keyed { _, entry, isFolder in isFolder ? 0 : -((entry.linkTarget ?? entry).size.map(Int64.init(clamping:)) ?? -1) }
        case .kind:
            // A folder has few distinct extensions, so collation runs only over those.
            let suffixes = rows.map { ($0.entry.name as NSString).pathExtension.lowercased() }
            let ranks = Dictionary(uniqueKeysWithValues: Set(suffixes).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .enumerated().map { ($1, Int32($0)) })
            return keyed { index, _, isFolder in isFolder ? 0 : ranks[suffixes[index]] ?? 0 }
        }
    }

    /// Folders, including links to folders, always come first. Size and date describe what a resolved
    /// link opens; newest and largest come first, and entries without a value sort last. Ties fall
    /// back to the name.
    static func precedes(_ lhs: RemoteEntry, _ rhs: RemoteEntry, by order: FolderSortOrder) -> Bool {
        let lhsFolder = lhs.effectiveKind == .directory, rhsFolder = rhs.effectiveKind == .directory
        if lhsFolder != rhsFolder { return lhsFolder }
        let left = lhs.linkTarget ?? lhs, right = rhs.linkTarget ?? rhs
        switch order {
        case .name: break
        case .modified:
            if left.modifiedAt != right.modifiedAt { return (left.modifiedAt ?? .distantPast) > (right.modifiedAt ?? .distantPast) }
        case .size:
            if !lhsFolder, left.size != right.size { return (left.size.map(Int64.init(clamping:)) ?? -1) > (right.size.map(Int64.init(clamping:)) ?? -1) }
        case .kind:
            let lhsKind = (lhs.name as NSString).pathExtension.lowercased(), rhsKind = (rhs.name as NSString).pathExtension.lowercased()
            if !lhsFolder, lhsKind != rhsKind { return lhsKind.localizedStandardCompare(rhsKind) == .orderedAscending }
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// One filter pass over a folder. What every row would otherwise repeat is worked out once, and a
/// plain-text name can be ruled out by looking at its bytes, which is about four times as fast as
/// asking Foundation. Foundation still decides every name that might match, so results don't change.
struct FolderFilter {
    private let query: String
    private let options: SearchQueryOptions
    private let suffix: String
    /// Lowercase unless the search is case-sensitive. Nil unless the query is printable ASCII.
    private let needle: [UInt8]?

    init(query: String, options: SearchQueryOptions) {
        self.query = query; self.options = options
        suffix = options.normalizedFileExtension
        let bytes = Array(query.utf8)
        needle = !bytes.isEmpty && bytes.allSatisfy(Self.isPrintableASCII)
            ? (options.caseSensitive ? bytes : bytes.map(Self.lowercased)) : nil
    }

    var isEmpty: Bool { query.isEmpty && suffix.isEmpty }

    func accepts(_ entry: RemoteEntry) -> Bool {
        if !suffix.isEmpty {
            guard entry.kind == .file, (entry.name as NSString).pathExtension.lowercased() == suffix else { return false }
        }
        guard !query.isEmpty else { return true }
        if let needle, Self.cannotContain(needle, in: entry.name, caseSensitive: options.caseSensitive) { return false }
        return options.range(in: entry.name, query: query) != nil
    }

    private static func isPrintableASCII(_ byte: UInt8) -> Bool { byte >= 0x20 && byte < 0x7F }
    private static func lowercased(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte }

    /// True only when `name` is wholly printable ASCII and lacks `needle`. Any other byte can match
    /// through Unicode equivalence or folding, so those names are left to Foundation.
    static func cannotContain(_ needle: [UInt8], in name: String, caseSensitive: Bool) -> Bool {
        var name = name
        return name.withUTF8 { bytes in
            let count = bytes.count, length = needle.count
            let first = needle[0]
            let firstUpper = !caseSensitive && first >= 0x61 && first <= 0x7A ? first - 0x20 : first
            var found = false
            for index in 0..<count {
                let byte = bytes[index]
                guard isPrintableASCII(byte) else { return false }
                guard !found, byte == first || byte == firstUpper, index + length <= count else { continue }
                var offset = 1
                while offset < length {
                    let candidate = caseSensitive ? bytes[index + offset] : lowercased(bytes[index + offset])
                    if candidate != needle[offset] { break }
                    offset += 1
                }
                found = offset == length
            }
            return !found
        }
    }
}

/// Decides when rows still arriving are worth showing. A folder that finishes within `delay` of its
/// first rows never shows a partial list; a larger or more distant one shows what it has, and again each
/// time that has grown by half, so re-sorting stays a small part of the work however large the folder is.
final class PartialListingGate: @unchecked Sendable {
    static let delay: Duration = .milliseconds(100)
    private let lock = NSLock()
    private let delay: Duration
    private var firstBatch: ContinuousClock.Instant?
    private var shownCount = 0
    init(delay: Duration = PartialListingGate.delay) { self.delay = delay }
    func shouldShow(count: Int, now: ContinuousClock.Instant = .now) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return false }
        guard let first = firstBatch else { firstBatch = now; return false }
        guard first.duration(to: now) >= delay, count >= shownCount + shownCount / 2 else { return false }
        shownCount = count
        return true
    }
}

/// Gathers a search's reports so the screen refreshes at most ten times a second. The first matches
/// and the last report appear at once, and reports held back appear within the interval even if the
/// search then goes quiet.
@MainActor final class FolderSearchBatcher {
    static let interval: Duration = .milliseconds(100)
    private let interval: Duration
    private let apply: (RemoteFolderSearch.Update) -> Void
    private var pending: RemoteFolderSearch.Update?
    private var lastApplied: ContinuousClock.Instant?
    private var anyMatches = false
    private var waiter: Task<Void, Never>?
    init(interval: Duration = FolderSearchBatcher.interval, apply: @escaping (RemoteFolderSearch.Update) -> Void) {
        self.interval = interval; self.apply = apply
    }
    func add(_ update: RemoteFolderSearch.Update) {
        var merged = update
        if let pending {
            merged.matches = pending.matches + update.matches
            merged.contentMatches = pending.contentMatches + update.contentMatches
        }
        pending = merged
        let firstMatches = !anyMatches && !(merged.matches.isEmpty && merged.contentMatches.isEmpty)
        let due = lastApplied.map { $0.duration(to: .now) >= interval } ?? true
        if firstMatches || due || update.isFinished { flush(); return }
        guard waiter == nil else { return }
        waiter = Task { [interval, weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.waiter = nil
            self?.flush()
        }
    }
    func flush() {
        waiter?.cancel(); waiter = nil
        guard let pending else { return }
        self.pending = nil
        anyMatches = anyMatches || !(pending.matches.isEmpty && pending.contentMatches.isEmpty)
        lastApplied = .now
        apply(pending)
    }
}
