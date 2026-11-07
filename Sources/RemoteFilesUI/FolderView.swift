#if os(iOS)
import SwiftUI
import RemoteFilesCore

enum FolderSearchScope: Hashable { case folder, subfolders, contents }

/// A name found by searching subfolders, described with the folder it was found in.
struct FolderSearchRow: Identifiable, Sendable {
    let row: FolderRow
    let subtitle: String
    let snippet: String?
    /// The one-based PDF page of a content match, opened instead of the saved reading position.
    let page: Int?
    var id: String { row.id }
    init(_ entry: RemoteEntry, root: String, snippet: String? = nil, page: Int? = nil) {
        row = FolderRow(entry)
        self.snippet = snippet; self.page = page
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
        var options = SearchQueryOptions()
        var extraction = SearchExtractionOptions()
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
            if progress.skippedFiles > 0 { parts.append("Skipped \(progress.skippedFiles.formatted()) unsupported, oversized or linked files.") }
            if progress.truncatedFiles > 0 { parts.append("\(progress.truncatedFiles) files had extraction limits; matches may be missing.") }
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
        rows += update.contentMatches.map { FolderSearchRow($0.entry, root: key.root, snippet: ($0.page.map { "Page \($0)" } ?? "Line \($0.line)") + " · " + $0.snippet, page: $0.page) }
        progress = update
    }
}

/// Where Up and Down move a folder's keyboard selection.
enum FolderKeyboardSelection {
    /// Moves `delta` rows, stopping at either end. With nothing selected, or a selection no longer
    /// listed, Down starts at the top and Up at the bottom.
    static func moved(_ current: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return delta > 0 ? ids.first : ids.last }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }
}

struct FolderView: View {
    @Environment(\.workspaceNavigation) private var workspaceNavigate
    @Bindable var model: AppModel
    let profile: ConnectionProfile
    let requestedPath: String
    @State private var listing: FolderListing?
    @State private var visible: [FolderRow]
    /// Changes with `visible`, so its list compares in constant time.
    @State private var visibleRevision = 0
    @State private var favouriteToggles = 0
    @State private var pullRefreshing = false
    @State private var error: String?
    /// Starts true without a remembered listing, so the first frame isn't the failure view.
    @State private var loading: Bool
    @State private var showHidden = false
    @State private var filter = ""
    @State private var sortOrder: FolderSortOrder
    /// Set once the user picks a sort here, so a listing that arrives later does not override it.
    @State private var userChoseSort = false
    @State private var appliedFilter = ""
    @State private var appliedShowHidden = false
    @State private var appliedSearchOptions = SearchQueryOptions()
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
    @State private var searchOptions = SearchQueryOptions()
    @State private var extraction = SearchExtractionOptions()
    @State private var showingSearchIndex = false
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    /// The row a hardware keyboard's arrow keys have selected; Return opens it.
    @State private var keyboardSelection: String?
    init(model: AppModel, profile: ConnectionProfile, requestedPath: String) {
        self.model = model
        self.profile = profile
        self.requestedPath = requestedPath
        let cached = model.cachedListing(profile.id, path: requestedPath)
        let order = cached.map { model.folderSortOrder(profile.id, path: $0.path) } ?? .name
        _listing = State(initialValue: cached)
        _loading = State(initialValue: cached == nil)
        // Views are made often, so this stays constant time. Another sort follows away from the main actor.
        _visible = State(initialValue: cached?.defaultRows ?? [])
        _sortOrder = State(initialValue: order)
        _appliedSortOrder = State(initialValue: .name)
        _lastSessionRevision = State(initialValue: model.sessionRevision)
    }
    var path: String { listing?.path ?? requestedPath }
    private var folderEmpty: (title: String, symbol: String, detail: String) {
        filter.isEmpty ? ("This folder is empty", "folder", "Pull down to check for new files.")
            : ("No matching names", "magnifyingglass", "Filtering names in this folder only.")
    }
    var body: some View {
        // One view, not a Group: a Group's lifecycle modifiers would run per branch.
        VStack(spacing: 0) {
            if loading && listing == nil {
                LoadingPlaceholder(label: "Connecting and opening folder…")
            } else if listing == nil {
                ContentUnavailableView {
                    Label("Couldn’t open folder", systemImage: "folder.badge.questionmark")
                } description: { Text(error ?? "Check the connection, then try again.") }
                actions: { Button("Try Again") { refreshID += 1 }.buttonStyle(.bordered) }
            } else if searchingSubfolders {
                subfolderResults
            } else {
                FolderRowList(rows: visible, revision: visibleRevision, selection: keyboardSelection, resolving: resolving,
                              empty: visible.isEmpty ? folderEmpty : nil, refresh: {
                    pullRefreshing = true
                    await reload()
                    pullRefreshing = false
                }) { row in
                    link(for: row, subtitle: row.subtitle, visibleSubtitle: row.visibleSubtitle)
                }
                .equatable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(RemoteFilesStyle.contentFade, value: listing == nil)
        .safeAreaBar(edge: .top, spacing: 0) {
            if searchPresented, searchScope == .contents, searchQuery.isEmpty {
                Text(extraction.includePDF || extraction.includeOCR
                     ? "Searches text, selected PDFs and images on this device. Up to 2 MB per file, 20 PDF pages and 16 MB per search."
                     : "Searches text in this folder and subfolders. Up to 256 KB per file and 16 MB per search.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 6)
            }
        }
        // A failed first load explains itself in place.
        // Pulling to refresh has its own spinner.
        .contentStatus(progress: listing != nil && loading && !pullRefreshing ? "Updating…" : nil,
                       failure: listing == nil ? nil : error.map { "Couldn’t update this folder · \($0)" },
                       retry: { refreshID += 1 })
        .navigationTitle(RemotePath.name(of: path))
        .navigationSubtitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu { ancestorsMenu }
        // iOS 27.2's floating search bar can intercept visible result rows after
        // keyboard dismissal. Keep search in the navigation bar.
        .searchable(text: $filter, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
        .searchFocused($searchFocused)
        .searchScopes($searchScope) {
            Text("This Folder").tag(FolderSearchScope.folder)
            Text("Subfolders").tag(FolderSearchScope.subfolders)
            Text("Contents").tag(FolderSearchScope.contents)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section {
                        Button(model.isFavourite(profile.id, path: path) ? "Remove Favourite" : "Add Favourite", systemImage: model.isFavourite(profile.id, path: path) ? "star.slash" : "star") {
                            favouriteToggles += 1
                            Task { await model.favourite(profile: profile, path: path) }
                        }.disabled(listing == nil)
                        Button("Refresh", systemImage: "arrow.clockwise") { refreshID += 1 }
                    }
                    Section {
                        Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: sortSelection) {
                            ForEach(FolderSortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu)
                        Toggle("Show Hidden Files", systemImage: "eye", isOn: $showHidden)
                    }
                    Section {
                        Menu("Search Options", systemImage: "line.3.horizontal.decrease") {
                            SearchOptionsControls(options: $searchOptions)
                            Toggle("Include PDF Text", isOn: $extraction.includePDF)
                            Toggle("Recognize Text in Images and Scans", isOn: $extraction.includeOCR)
                        }
                        Button("Saved Search Index", systemImage: "doc.text.magnifyingglass") { showingSearchIndex = true }
                            .disabled(listing == nil)
                        if let listing {
                            OfflineFolderPinActions(model: model, profile: profile, path: listing.path, includeHidden: showHidden)
                        }
                    }
                    Section {
                        Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnectAndGoHome() } }
                    }
                } label: { Label("Folder actions", systemImage: "ellipsis") }
            }
        }
        .task(id: ReloadWork(foreground: model.isForeground, session: model.sessionRevision, refresh: refreshID)) { await reloadIfNeeded() }
        .onDisappear { resolveTask?.cancel(); resolveTask = nil }
        .task(id: VisibleWork(filter: filter, showHidden: showHidden, order: sortOrder, options: searchOptions)) { await updateVisible() }
        // A saved index of this folder set to update automatically refreshes once it is old enough,
        // whether the folder was listed again or shown from the cache.
        .task(id: SettledWork(path: listing?.path, loading: loading, failed: error != nil, foreground: model.isForeground, session: model.sessionRevision)) {
            guard let listing, !loading, error == nil else { return }
            if isFrontmost { model.prefetchFolders(in: listing, profile: profile) }
            await model.indexUpdates.updateIfDue(profile, root: listing.path, model: model)
        }
        .sheet(isPresented: $showingSearchIndex) {
            SearchIndexView(model: model, profile: profile, root: path, includeHidden: showHidden).coversKeyboardCommands()
        }
        .task(id: SearchWork(options: searchOptions, extraction: extraction, scope: searchScope, filter: filter, showHidden: showHidden, path: listing?.path, foreground: model.isForeground, session: model.sessionRevision, refresh: lastRefreshID)) {
            await searchSubfolders()
        }
        .task {
            // Let the listing's own first layout finish; a document opened sooner skips warm-up.
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { ReaderWarmUp.start() }
        }
        .focusedSceneValue(\.folderCommands, isFrontmost ? commands : nil)
        .sensoryFeedback(.selection, trigger: favouriteToggles)
        // A search left empty returns to this folder, rather than keeping a wider scope in reserve.
        .onChange(of: searchPresented) { _, presented in
            if !presented, filter.isEmpty { searchScope = .folder }
        }
    }
    private struct ReloadWork: Equatable { let foreground: Bool, session: Int, refresh: Int }
    private struct VisibleWork: Equatable { let filter: String, showHidden: Bool, order: FolderSortOrder, options: SearchQueryOptions }
    private struct SettledWork: Equatable { let path: String?, loading: Bool, failed: Bool, foreground: Bool, session: Int }
    private struct SearchWork: Equatable {
        let options: SearchQueryOptions, extraction: SearchExtractionOptions, scope: FolderSearchScope, filter: String
        let showHidden: Bool, path: String?, foreground: Bool, session: Int, refresh: Int
    }
    /// The workspace always shows its folder column; a stack has only its top route on screen.
    /// A library sheet covers it; sheets it presents itself use `coversKeyboardCommands()`.
    private var isFrontmost: Bool {
        guard model.sheet == nil else { return false }
        return workspaceNavigate != nil || model.routes.last == .folder(profile.id, requestedPath)
    }
    private var commands: FolderCommandActions {
        let parent = RemotePath.parent(of: path)
        return FolderCommandActions(
            context: "\(profile.id)|\(path)", refresh: { refreshID += 1 }, search: { searchPresented = true; searchFocused = true },
            toggleHidden: { showHidden.toggle() }, showsHidden: showHidden,
            enclosingFolder: path == "/" || parent == path ? nil : { model.showFolder(profile.id, path: parent) },
            moveSelection: hasKeyboardRows ? { moveKeyboardSelection($0) } : nil,
            openSelection: keyboardSelectionIsListed ? { openKeyboardSelection() } : nil)
    }
    /// The path's ancestors, nearest first, from the folder's title.
    @ViewBuilder private var ancestorsMenu: some View {
        let components = path.split(separator: "/")
        Section(path) {
            ForEach(Array(components.indices.dropLast().reversed()), id: \.self) { index in
                let ancestor = "/" + components.prefix(index + 1).joined(separator: "/")
                Button(String(components[index]), systemImage: "folder") { model.showFolder(profile.id, path: ancestor) }
            }
            if path != "/" {
                Button("/", systemImage: "externaldrive") { model.showFolder(profile.id, path: "/") }
            }
        }
        Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
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
        followingKeyboardSelection(keyboardSelection) {
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
                            ProgressView().controlSize(.small)
                            Text(searchScope == .contents ? "Searching… \(search.progress.filesSearched.formatted()) files checked"
                                 : search.progress.foldersSearched == 0 ? "Searching subfolders…"
                                 : "Searching… \(search.progress.foldersSearched.formatted()) folders")
                                .contentTransition(.numericText())
                        }
                    } else {
                        Text(search.summary)
                    }
                }
                .font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                ForEach(search.rows) { result in
                    link(for: result.row, subtitle: result.subtitle, snippet: result.snippet, page: result.page).listRowInsets(.vertical, 7)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        }
    }
    /// Every row has one shape on purpose. A condition at the top of a List row, including one inside
    /// a view such as a navigation link that picks its form from the environment, makes SwiftUI build
    /// every row up front to count them: 530 ms of main-thread stall per 20,000 rows on iPhone 17 Pro,
    /// against 25 ms with one shape. See docs/PERFORMANCE.md.
    private func link(for row: FolderRow, subtitle: String, visibleSubtitle: String?? = nil, snippet: String? = nil, page: Int? = nil) -> some View {
        let entry = row.entry, selected = keyboardSelection == row.id
        let destination = destination(of: entry, page: page)
        return Button { open(entry, page: page) } label: {
            HStack(spacing: 8) {
                entryRow(row, subtitle: subtitle, visibleSubtitle: visibleSubtitle, snippet: snippet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if resolving == entry.path {
                    ProgressView()
                } else if destination?.kind == .directory, workspaceNavigate == nil {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(destination == nil && resolving != nil)
        .contextMenu {
            if let destination { OfflinePinActions(model: model, profile: profile, entry: destination, includeHidden: showHidden) }
        }
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAddTraits(workspaceNavigate != nil ? .isLink : [])
    }
    /// What a row opens, or nil for a link that must be resolved first.
    private func destination(of entry: RemoteEntry, page: Int?) -> RemoteEntry? {
        // A link resolved while listing opens its target directly.
        if let target = entry.followingLink() { return target.openingPage(page) }
        return entry.kind == .symlink ? nil : entry.openingPage(page)
    }
    /// Asked on every update, so it costs nothing until a keyboard has selected a row.
    private var keyboardSelectionIsListed: Bool {
        guard let keyboardSelection, listing != nil else { return false }
        return searchingSubfolders ? search.rows.contains { $0.row.id == keyboardSelection } : visible.contains { $0.id == keyboardSelection }
    }
    /// Whether the arrow keys have anything to move through, without building the rows.
    private var hasKeyboardRows: Bool {
        guard listing != nil else { return false }
        return searchingSubfolders ? !search.rows.isEmpty : !visible.isEmpty
    }
    /// The rows on screen, in order, with the PDF page a content match opens.
    private var keyboardRows: [(row: FolderRow, page: Int?)] {
        guard listing != nil else { return [] }
        return searchingSubfolders ? search.rows.map { ($0.row, $0.page) } : visible.map { ($0, nil) }
    }
    private func moveKeyboardSelection(_ delta: Int) {
        keyboardSelection = FolderKeyboardSelection.moved(keyboardSelection, by: delta, in: keyboardRows.map(\.row.id))
    }
    private func openKeyboardSelection() {
        guard let selected = keyboardRows.first(where: { $0.row.id == keyboardSelection }) else { return }
        open(selected.row.entry, page: selected.page)
    }
    private func open(_ entry: RemoteEntry, page: Int?) {
        if let destination = destination(of: entry, page: page) {
            let route = route(destination)
            // A second tap or a held Return while pushing opens the row once.
            if let workspaceNavigate { workspaceNavigate(route) } else if model.routes.last != route { model.routes.append(route) }
        } else if resolving == nil {
            resolve(entry, page: page)
        }
    }
    private func entryRow(_ row: FolderRow, subtitle: String, visibleSubtitle: String??, snippet: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LocationRow(name: row.entry.name, subtitle: subtitle, symbol: row.symbol,
                        color: row.entry.effectiveKind == .directory ? RemoteFilesStyle.accent : .secondary,
                        visibleSubtitle: visibleSubtitle)
            if let snippet {
                Text(snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, RemoteFilesStyle.iconColumn + 12)
            }
        }.accessibilityElement(children: .combine)
    }
    private func route(_ entry: RemoteEntry) -> AppModel.Route {
        entry.kind == .directory ? .folder(profile.id, entry.path) : .file(profile.id, entry)
    }
    private func resolve(_ entry: RemoteEntry, page: Int? = nil) {
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
                                         navigationRoot: target.navigationRoot, exportFilename: entry.name).openingPage(page)
                if let workspaceNavigate { workspaceNavigate(route(routed)) } else { model.routes.append(route(routed)) }
            } catch {
                guard !Task.isCancelled, !model.isDisconnecting, model.sessionRevision == revision else { return }
                model.handle(error, profile: profile)
                // A trust or unlock request has its own sheet; an alert would sit on top of it.
                if model.sheet == nil, model.errorMessage == nil { model.errorMessage = error.localizedDescription }
            }
        }
    }
    private func reloadIfNeeded() async {
        if listing == nil || lastSessionRevision != model.sessionRevision || lastRefreshID != refreshID {
            await reload()
        } else if model.isForeground, !model.isListingFresh(profile.id, path: requestedPath) {
            await revalidateQuietly()
        }
    }
    /// Checks a folder that's already on screen. Nothing shows unless its rows actually changed, and
    /// failing changes nothing; Refresh or the next connection reports what's wrong.
    private func revalidateQuietly() async {
        let token = requestID, revision = model.sessionRevision
        guard !model.isDisconnecting else { return }
        model.noteForegroundConnection(profile.id)
        let generation = model.listingGeneration(profile.id)
        let found: DirectorySnapshot?
        do { found = try await model.quietListing(profile, path: requestedPath) }
        catch { return }
        guard !Task.isCancelled, token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
        // No session to check it over yet, so this is the moment to connect.
        guard let found else { await reload(); return }
        let current = listing
        let prepared = await Task.detached(priority: .utility) { () -> FolderListing? in
            let value = FolderListing(found)
            return value.path == current?.path && value.rows.map(\.entry) == current?.rows.map(\.entry) ? nil : value
        }.value
        guard !Task.isCancelled, token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
        guard model.listingGeneration(profile.id) == generation else { return }
        guard let prepared else {
            if let current { model.cache(current, id: profile.id, requestedPath: requestedPath) }
            return
        }
        let query = filter, hidden = showHidden, order = sortOrder, options = searchOptions
        let rows = await Task.detached(priority: .userInitiated) {
            prepared.visible(query: query, showHidden: hidden, order: order, options: options)
        }.value
        guard !Task.isCancelled, token == requestID, !model.isDisconnecting, model.sessionRevision == revision,
              model.listingGeneration(profile.id) == generation,
              query == filter, hidden == showHidden, order == sortOrder, options == searchOptions else { return }
        sortID = UUID()
        listing = prepared; setVisible(rows)
        appliedFilter = query; appliedShowHidden = hidden; appliedSortOrder = order; appliedSearchOptions = options
        model.cache(prepared, id: profile.id, requestedPath: requestedPath)
    }
    private func reload() async {
        guard !model.isDisconnecting else { loading = false; return }
        // Going to the background isn't a failure of a folder still on screen.
        guard model.isForeground else {
            loading = false
            if listing == nil { error = "Connection paused while the app is in the background." }
            return
        }
        let token = UUID(); requestID = token
        let revision = model.sessionRevision
        let generation = model.listingGeneration(profile.id)
        lastSessionRevision = model.sessionRevision; lastRefreshID = refreshID
        loading = true; error = nil
        model.noteForegroundConnection(profile.id)
        // A check over a live connection isn't connecting again; don't flash the state on Home.
        if model.connectionStates[profile.id] != "Connected" { model.connectionStates[profile.id] = "Connecting…" }
        do {
            let value = try await model.service.listDirectory(profile: profile, path: requestedPath)
            let prepared = await Task.detached(priority: .userInitiated) { FolderListing(value) }.value
            if !userChoseSort { sortOrder = model.folderSortOrder(profile.id, path: prepared.path) }
            let query = filter, hidden = showHidden, order = sortOrder, options = searchOptions
            let rows = await Task.detached(priority: .userInitiated) {
                prepared.visible(query: query, showHidden: hidden, order: order, options: options)
            }.value
            try Task.checkCancellation()
            guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            // This connection failed verification while the listing was on its way.
            guard model.listingGeneration(profile.id) == generation else { loading = false; return }
            sortID = UUID() // Supersede a filter task based on the previous listing.
            listing = prepared; setVisible(rows)
            appliedFilter = query; appliedShowHidden = hidden; appliedSortOrder = order; appliedSearchOptions = options
            model.cache(prepared, id: profile.id, requestedPath: requestedPath)
            model.connectionStates[profile.id] = "Connected"
            if query != filter || hidden != showHidden || order != sortOrder || options != searchOptions { await updateVisible() }
        } catch {
            guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            if !Task.isCancelled && !(error is CancellationError) {
                self.error = error.localizedDescription
                if model.isSecurityError(error) { listing = nil; setVisible([]) }
                model.handle(error, profile: profile)
            } else if model.connectionStates[profile.id] == "Connecting…" {
                // Leaving a folder cancels its connection, so don't keep saying one is under way.
                model.connectionStates[profile.id] = nil
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
                                        sessionRevision: revision, refresh: lastRefreshID, scope: searchScope, options: searchOptions, extraction: extraction)
        guard !search.isFinished(for: key) else { return }
        search = FolderSearchState(key: key)
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        do {
            let updates = searchScope == .contents
                ? RemoteFolderSearch.contents(matching: query, below: root, profile: profile, service: model.searchService, includeHidden: showHidden,
                    contentLimits: .init(maxFileBytes: extraction.includePDF || extraction.includeOCR ? DocumentPolicy.previewByteLimit : 256 * 1_024),
                    options: searchOptions, extraction: extraction)
                : RemoteFolderSearch.names(matching: query, below: root, profile: profile, service: model.searchService, includeHidden: showHidden, options: searchOptions)
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
    private func setVisible(_ rows: [FolderRow]) {
        visible = rows; visibleRevision &+= 1
    }
    private func updateVisible() async {
        guard let listing else { return }
        guard filter != appliedFilter || showHidden != appliedShowHidden || sortOrder != appliedSortOrder || searchOptions != appliedSearchOptions else { return }
        let token = UUID()
        sortID = token
        // Large folders wait for typing to pause, rather than filter on every keystroke.
        if listing.rows.count > 500 {
            do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
        }
        let query = filter, hidden = showHidden, order = sortOrder, options = searchOptions
        let results = await Task.detached(priority: .userInitiated) {
            listing.visible(query: query, showHidden: hidden, order: order, options: options)
        }.value
        guard !Task.isCancelled, token == sortID, query == filter, hidden == showHidden, order == sortOrder, options == searchOptions else { return }
        setVisible(results)
        appliedSearchOptions = options
        appliedFilter = query; appliedShowHidden = hidden; appliedSortOrder = order
    }
}

/// A folder's rows, kept apart from `FolderView` so typing, loading and status updates don't diff
/// every row. It redraws only when its rows, keyboard selection or a link being resolved change.
private struct FolderRowList<Row: View>: View, Equatable {
    let rows: [FolderRow]
    let revision: Int
    let selection: String?
    let resolving: String?
    let empty: (title: String, symbol: String, detail: String)?
    let refresh: () async -> Void
    @ViewBuilder let row: (FolderRow) -> Row
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.selection == rhs.selection && lhs.resolving == rhs.resolving
            && lhs.empty?.title == rhs.empty?.title
    }
    var body: some View {
        followingKeyboardSelection(selection) {
            List {
                if let empty {
                    ContentUnavailableView(empty.title, systemImage: empty.symbol, description: Text(empty.detail))
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { row($0).listRowInsets(.vertical, 7) }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await refresh() }
        }
    }
}

/// Scrolls `list` to keep the keyboard selection in view. The ScrollViewReader is added only once
/// a row is selected, so folders browsed by touch keep their list unchanged. Down and Up start at
/// the first and last row, so the scroll offset this resets doesn't matter.
@MainActor @ViewBuilder private func followingKeyboardSelection(_ selection: String?, @ViewBuilder _ list: () -> some View) -> some View {
    let list = list()
    if selection == nil { list } else {
        ScrollViewReader { proxy in
            list.onChange(of: selection, initial: true) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }
}

#endif
