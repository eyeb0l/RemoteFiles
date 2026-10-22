#if os(iOS)
import SwiftUI
import RemoteFilesCore

struct FolderRow: Identifiable, Sendable {
    let entry: RemoteEntry
    let subtitle: String
    let symbol: String
    var id: String { entry.path }

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
            let symbol: String
            switch DocumentPolicy.kind(filename: entry.name) {
            case .markdown, .html, .pdf, .svg: symbol = "doc.richtext"
            case .image: symbol = "photo"
            case .video: symbol = "film"
            case .audio: symbol = "waveform"
            case .plainText, .unsupported: symbol = "doc.text"
            }
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

enum FolderSearchScope: Hashable { case folder, subfolders, contents }

/// A name found by searching subfolders, described with the folder it was found in.
struct FolderSearchRow: Identifiable, Sendable {
    let row: FolderRow
    let subtitle: String
    let snippet: String?
    var id: String { row.id }
    init(_ entry: RemoteEntry, root: String, snippet: String? = nil) {
        row = FolderRow(entry)
        self.snippet = snippet
        let parent = RemotePath.parent(of: entry.path)
        let prefix = root == "/" ? "/" : root + "/"
        let location = parent == root ? "In this folder" : "In " + (parent.hasPrefix(prefix) ? String(parent.dropFirst(prefix.count)) : parent)
        subtitle = location + " · " + row.subtitle
    }
}

/// Results of one subfolder search, replaced whenever the query, scope or folder changes.
struct FolderSearchState {
    /// What a search ran for; a finished search for the same key is kept when the folder reappears.
    struct Key: Equatable {
        let query: String, root: String, includeHidden: Bool, sessionRevision: Int, refresh: Int
        var scope: FolderSearchScope = .subfolders
    }
    var key: Key?
    var rows: [FolderSearchRow] = []
    var progress = RemoteFolderSearch.Update()
    var error: String?

    /// Opening a result cancels the folder's tasks, so returning restarts them; a search that
    /// already finished for the same key is shown again instead of listing every folder again.
    func isFinished(for key: Key) -> Bool { self.key == key && progress.isFinished && error == nil }

    var summary: String {
        let limits = RemoteFolderSearch.Limits()
        let searched = progress.foldersSearched
        var parts = ["Searched \(searched.formatted()) \(searched == 1 ? "folder" : "folders")."]
        if key?.scope == .contents {
            parts.append("Checked \(progress.filesSearched.formatted()) files.")
            if progress.skippedFiles > 0 { parts.append("Skipped \(progress.skippedFiles.formatted()) non-text, oversized or linked files.") }
            if progress.unreadableFiles > 0 { parts.append("\(progress.unreadableFiles.formatted()) files couldn’t be read.") }
        }
        if progress.unreadableFolders > 0 {
            parts.append("\(progress.unreadableFolders.formatted()) couldn’t be read.")
        }
        switch progress.stop {
        case .matchLimit: parts.append("Showing the first \(rows.count.formatted()) matches. Type more to narrow the search.")
        case .folderLimit: parts.append("Stopped after \(limits.maxFolders.formatted()) folders. Search from a subfolder to go further.")
        case .timeLimit: parts.append("Stopped after \(limits.timeLimit.components.seconds) seconds. Search from a subfolder to go further.")
        case .fileLimit: parts.append("Stopped after \(RemoteFolderSearch.ContentLimits().maxFiles.formatted()) files. Search from a subfolder to go further.")
        case .byteLimit: parts.append("Reached the 16 MB read budget. Search from a subfolder to go further.")
        case nil:
            if progress.skippedDeepFolders > 0 { parts.append("Folders more than \(limits.maxDepth) levels down weren’t searched.") }
        }
        return parts.joined(separator: " ")
    }

    mutating func apply(_ update: RemoteFolderSearch.Update, for key: Key) {
        guard self.key == key else { return }
        rows += update.matches.map { FolderSearchRow($0, root: key.root) }
        rows += update.contentMatches.map { FolderSearchRow($0.entry, root: key.root, snippet: "Line \($0.line) · \($0.snippet)") }
        progress = update
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
    func visible(query: String, showHidden: Bool, order: FolderSortOrder) -> [FolderRow] {
        if query.isEmpty && order == .name { return showHidden ? rows : defaultRows }
        let result = (showHidden ? rows : defaultRows).filter {
            query.isEmpty || $0.entry.name.localizedCaseInsensitiveContains(query)
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

struct FolderView: View {
    @Environment(\.workspaceNavigation) private var workspaceNavigate
    @Bindable var model: AppModel
    let profile: ConnectionProfile
    let requestedPath: String
    @State private var listing: FolderListing?
    @State private var visible: [FolderRow]
    @State private var error: String?
    @State private var loading = false
    @State private var showHidden = false
    @State private var filter = ""
    @State private var sortOrder: FolderSortOrder
    /// Set once the user picks a sort here, so a listing that arrives later does not override it.
    @State private var userChoseSort = false
    @State private var appliedFilter = ""
    @State private var appliedShowHidden = false
    @State private var appliedSortOrder: FolderSortOrder
    @State private var refreshID = 0
    @State private var requestID = UUID()
    @State private var sortID = UUID()
    @State private var lastSessionRevision: Int
    @State private var lastRefreshID = 0
    @State private var resolving: String?
    @State private var resolveTask: Task<Void, Never>?
    @State private var searchScope = FolderSearchScope.folder
    @State private var search = FolderSearchState()
    init(model: AppModel, profile: ConnectionProfile, requestedPath: String) {
        self.model = model
        self.profile = profile
        self.requestedPath = requestedPath
        let cached = model.cachedListing(profile.id, path: requestedPath)
        let order = cached.map { model.folderSortOrder(profile.id, path: $0.path) } ?? .name
        _listing = State(initialValue: cached)
        _visible = State(initialValue: cached?.visible(query: "", showHidden: false, order: order) ?? [])
        _sortOrder = State(initialValue: order)
        _appliedSortOrder = State(initialValue: order)
        _lastSessionRevision = State(initialValue: model.sessionRevision)
    }
    var path: String { listing?.path ?? requestedPath }
    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if searchScope == .contents {
                Text("Search text in this folder and subfolders. Up to 256 KB per file and 16 MB per search.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 6)
            }
            if let error { StatusBanner(message: listing == nil ? error : "Previously loaded folder · \(error)", error: true) }
            else if loading && listing != nil { StatusBanner(message: "Showing cached folder · refreshing…") }
            if loading && listing == nil {
                ProgressView("Connecting and opening folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listing == nil {
                ContentUnavailableView {
                    Label("Couldn’t open folder", systemImage: "folder.badge.questionmark")
                } description: { Text("Check the connection, then try again.") }
                actions: { Button("Try Again") { refreshID += 1 }.buttonStyle(.bordered) }
            } else if searchingSubfolders {
                subfolderResults
            } else {
                List {
                    if visible.isEmpty {
                        ContentUnavailableView(filter.isEmpty ? "This folder is empty" : "No matching names", systemImage: filter.isEmpty ? "folder" : "magnifyingglass", description: Text(filter.isEmpty ? "Pull down to check for new files." : "Filtering names in this folder only."))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(visible) { row in link(for: row, subtitle: row.subtitle) }
                }
                .listStyle(.plain)
                .refreshable { await reload() }
            }
        }
        .navigationTitle(RemotePath.name(of: path))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: searchPrompt)
        .searchScopes($searchScope) {
            Text("This Folder").tag(FolderSearchScope.folder)
            Text("Subfolders").tag(FolderSearchScope.subfolders)
            Text("Contents").tag(FolderSearchScope.contents)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(model.isFavourite(profile.id, path: path) ? "Remove Favourite" : "Add Favourite", systemImage: model.isFavourite(profile.id, path: path) ? "star.slash" : "star") { Task { await model.favourite(profile: profile, path: path) } }.disabled(listing == nil)
                    Button("Refresh", systemImage: "arrow.clockwise") { refreshID += 1 }
                    Toggle("Show Hidden Files", isOn: $showHidden)
                    Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: sortSelection) {
                        ForEach(FolderSortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu)
                    Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnectAndGoHome() } }
                } label: { Label("Folder actions", systemImage: "ellipsis.circle") }
            }
        }
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)") { await reloadIfNeeded() }
        .onDisappear { resolveTask?.cancel(); resolveTask = nil }
        .task(id: "\(filter)-\(showHidden)-\(sortOrder)") { await updateVisible() }
        .task(id: "\(searchScope)-\(filter)-\(showHidden)-\(listing?.path ?? "")-\(model.isForeground)-\(model.sessionRevision)-\(lastRefreshID)") {
            await searchSubfolders()
        }
        .task {
            // Let the listing's own first layout finish; a document opened sooner skips warm-up.
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { ReaderWarmUp.start() }
        }
    }
    private var pathBar: some View {
        HStack {
            Menu {
                let components = path.split(separator: "/")
                Button("/", systemImage: "externaldrive") { model.showFolder(profile.id, path: "/") }
                ForEach(0..<components.count, id: \.self) { index in
                    let ancestor = "/" + components.prefix(index + 1).joined(separator: "/")
                    Button(ancestor) { model.showFolder(profile.id, path: ancestor) }
                }
            } label: {
                Label(path, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
            }.accessibilityLabel("Remote path \(path). Browse ancestors")
            Text(profile.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.horizontal).background(.bar)
    }
    /// A user's choice is remembered for this folder once its canonical path is known.
    private var sortSelection: Binding<FolderSortOrder> {
        Binding(get: { sortOrder }, set: { order in
            sortOrder = order; userChoseSort = true
            if let listing { model.setFolderSortOrder(order, id: profile.id, path: listing.path) }
        })
    }
    private var searchQuery: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchPrompt: String {
        switch searchScope {
        case .folder: return "Filter this folder"
        case .subfolders: return "Search names in subfolders"
        case .contents: return "Search text in files"
        }
    }
    private var searchingSubfolders: Bool { searchScope != .folder && !searchQuery.isEmpty }
    private var subfolderResults: some View {
        List {
            if search.rows.isEmpty, search.progress.isFinished, search.error == nil {
                ContentUnavailableView(searchScope == .contents ? "No matching contents" : "No matching names", systemImage: "magnifyingglass", description: Text(search.summary))
                    .listRowSeparator(.hidden)
            } else {
                // Above the results, so it stays visible over the keyboard while typing.
                Group {
                    if let error = search.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else if !search.progress.isFinished {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(searchScope == .contents ? "Searching… \(search.progress.filesSearched.formatted()) files checked"
                                 : search.progress.foldersSearched == 0 ? "Searching subfolders…"
                                 : "Searching… \(search.progress.foldersSearched.formatted()) folders")
                        }
                    } else {
                        Text(search.summary)
                    }
                }
                .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                ForEach(search.rows) { result in link(for: result.row, subtitle: result.subtitle, snippet: result.snippet) }
            }
        }
        .listStyle(.plain)
    }
    @ViewBuilder private func link(for row: FolderRow, subtitle: String, snippet: String? = nil) -> some View {
        let entry = row.entry
        if let destination = entry.followingLink() {
            // Resolved while listing: open the target directly.
            WorkspaceLink(route: route(destination)) { entryRow(row, subtitle: subtitle, snippet: snippet) }
                .contextMenu { OfflinePinActions(model: model, profile: profile, entry: destination) }
        } else if entry.kind == .symlink {
            Button { resolve(entry) } label: {
                entryRow(row, subtitle: subtitle, snippet: snippet).overlay(alignment: .trailing) { if resolving == entry.path { ProgressView() } }
            }.disabled(resolving != nil)
        } else {
            WorkspaceLink(route: route(entry)) { entryRow(row, subtitle: subtitle, snippet: snippet) }
                .contextMenu { OfflinePinActions(model: model, profile: profile, entry: entry) }
        }
    }
    private func entryRow(_ row: FolderRow, subtitle: String, snippet: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LocationRow(name: row.entry.name, subtitle: subtitle, symbol: row.symbol,
                        color: row.entry.effectiveKind == .directory ? .indigo : .secondary)
            if let snippet { Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        }.accessibilityElement(children: .combine)
    }
    private func route(_ entry: RemoteEntry) -> AppModel.Route {
        entry.kind == .directory ? .folder(profile.id, entry.path) : .file(profile.id, entry)
    }
    private func resolve(_ entry: RemoteEntry) {
        guard !model.isDisconnecting else { return }
        let revision = model.sessionRevision
        resolving = entry.path
        resolveTask = Task {
            defer { resolving = nil }
            do {
                let target = try await model.service.resolveEntry(profile: profile, path: entry.path)
                try Task.checkCancellation()
                guard !model.isDisconnecting, model.sessionRevision == revision else { return }
                let routed = RemoteEntry(name: target.name, path: target.path, kind: target.kind,
                                         size: target.size, modifiedAt: target.modifiedAt,
                                         navigationRoot: target.navigationRoot, exportFilename: entry.name)
                if let workspaceNavigate { workspaceNavigate(route(routed)) } else { model.routes.append(route(routed)) }
            } catch { if !Task.isCancelled, !model.isDisconnecting, model.sessionRevision == revision { self.error = error.localizedDescription; model.handle(error, profile: profile) } }
        }
    }
    private func reloadIfNeeded() async {
        guard listing == nil || lastSessionRevision != model.sessionRevision || lastRefreshID != refreshID else { return }
        await reload()
    }
    private func reload() async {
        guard !model.isDisconnecting else { return }
        guard model.isForeground else { loading = false; error = "Connection paused while the app is in the background."; return }
        let token = UUID(); requestID = token
        let revision = model.sessionRevision
        lastSessionRevision = model.sessionRevision; lastRefreshID = refreshID
        loading = true; error = nil
        model.connectionStates[profile.id] = "Connecting…"
        do {
            let value = try await model.service.listDirectory(profile: profile, path: requestedPath)
            let prepared = await Task.detached(priority: .userInitiated) { FolderListing(value) }.value
            if !userChoseSort { sortOrder = model.folderSortOrder(profile.id, path: prepared.path) }
            let query = filter, hidden = showHidden, order = sortOrder
            let rows = await Task.detached(priority: .userInitiated) {
                prepared.visible(query: query, showHidden: hidden, order: order)
            }.value
            try Task.checkCancellation()
            guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            sortID = UUID() // Supersede a filter task based on the previous listing.
            listing = prepared; visible = rows
            appliedFilter = query; appliedShowHidden = hidden; appliedSortOrder = order
            model.cache(prepared, id: profile.id, requestedPath: requestedPath)
            model.connectionStates[profile.id] = "Connected"
            if query != filter || hidden != showHidden || order != sortOrder { await updateVisible() }
        } catch {
            guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            if !Task.isCancelled && !(error is CancellationError) {
                self.error = error.localizedDescription
                if model.isSecurityError(error) { listing = nil; visible = [] }
                model.handle(error, profile: profile)
            }
        }
        if token == requestID { loading = false }
    }
    /// Lists subfolders of the canonical folder once typing pauses; a new query, scope, refresh,
    /// disconnect or backgrounding cancels the walk.
    private func searchSubfolders() async {
        let query = searchQuery
        guard searchScope != .folder, !query.isEmpty, let root = listing?.path,
              model.isForeground, !model.isDisconnecting else { search = FolderSearchState(); return }
        let revision = model.sessionRevision
        let key = FolderSearchState.Key(query: query, root: root, includeHidden: showHidden,
                                        sessionRevision: revision, refresh: lastRefreshID, scope: searchScope)
        guard !search.isFinished(for: key) else { return }
        search = FolderSearchState(key: key)
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        do {
            let updates = searchScope == .contents
                ? RemoteFolderSearch.contents(matching: query, below: root, profile: profile, service: model.searchService, includeHidden: showHidden)
                : RemoteFolderSearch.names(matching: query, below: root, profile: profile, service: model.searchService, includeHidden: showHidden)
            for try await update in updates {
                guard !Task.isCancelled, model.sessionRevision == revision else { return }
                search.apply(update, for: key)
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), !model.isDisconnecting,
                  model.sessionRevision == revision, search.key == key else { return }
            search.error = error.localizedDescription
            model.handle(error, profile: profile)
        }
    }
    private func updateVisible() async {
        guard let listing else { return }
        guard filter != appliedFilter || showHidden != appliedShowHidden || sortOrder != appliedSortOrder else { return }
        let token = UUID()
        sortID = token
        let query = filter, hidden = showHidden, order = sortOrder
        let results = await Task.detached(priority: .userInitiated) {
            listing.visible(query: query, showHidden: hidden, order: order)
        }.value
        guard !Task.isCancelled, token == sortID, query == filter, hidden == showHidden, order == sortOrder else { return }
        visible = results
        appliedFilter = query; appliedShowHidden = hidden; appliedSortOrder = order
    }
}

#endif
