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

struct FolderRow: Identifiable, Sendable {
    let entry: RemoteEntry
    /// What VoiceOver and search results say about the row.
    let subtitle: String
    let symbol: String
    var id: String { entry.path }
    /// A plain folder's icon already says "Folder", so its row shows only the name.
    var visibleSubtitle: String? { subtitle == "Folder" ? nil : subtitle }

    init(_ entry: RemoteEntry) {
        self.entry = entry
        switch entry.link {
        case .target(let target):
            // A resolved link looks like what it opens, and says it is a link.
            let (symbol, details) = Self.describe(target)
            self.symbol = symbol
            subtitle = target.kind == .directory ? "Link to folder" : (["Link to file"] + details).joined(separator: " · ")
        case .broken:
            symbol = "link"; subtitle = "Broken link"
        case nil:
            let (symbol, details) = Self.describe(entry)
            self.symbol = symbol
            switch entry.kind {
            case .directory: subtitle = "Folder"
            case .symlink: subtitle = "Symbolic link"
            case .file, .other: subtitle = details.isEmpty ? "File" : details.joined(separator: " · ")
            }
        }
    }

    private static func describe(_ entry: RemoteEntry) -> (symbol: String, details: [String]) {
        switch entry.kind {
        case .directory: return ("folder.fill", [])
        case .symlink: return ("link", [])
        case .file, .other:
            let symbol = FileSymbol.name(forFilename: entry.name)
            var details: [String] = []
            if let size = entry.size { details.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)) }
            if let date = entry.modifiedAt { details.append(date.formatted(date: .abbreviated, time: .omitted)) }
            return (symbol, details)
        }
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
        rows = snapshot.entries.sorted { Self.precedes($0, $1, by: .name) }.map(FolderRow.init)
        defaultRows = rows.filter { !$0.entry.name.hasPrefix(".") }
    }
    func visible(query: String, showHidden: Bool, order: FolderSortOrder, options: SearchQueryOptions = .init()) -> [FolderRow] {
        if query.isEmpty && order == .name && options == SearchQueryOptions() { return showHidden ? rows : defaultRows }
        let result = (showHidden ? rows : defaultRows).filter {
            options.accepts($0.entry) && (query.isEmpty || options.range(in: $0.entry.name, query: query) != nil)
        }
        guard order != .name else { return result }
        return result.sorted { Self.precedes($0.entry, $1.entry, by: order) }
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
