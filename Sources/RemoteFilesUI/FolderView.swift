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
        switch entry.kind {
        case .directory: symbol = "folder.fill"; subtitle = "Folder"
        case .symlink: symbol = "link"; subtitle = "Symbolic link"
        case .file, .other:
            switch DocumentPolicy.kind(filename: entry.name) {
            case .markdown, .pdf: symbol = "doc.richtext"
            case .image: symbol = "photo"
            case .plainText, .unsupported: symbol = "doc.text"
            }
            var pieces: [String] = []
            if let size = entry.size { pieces.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)) }
            if let date = entry.modifiedAt { pieces.append(date.formatted(date: .abbreviated, time: .omitted)) }
            subtitle = pieces.isEmpty ? "File" : pieces.joined(separator: " · ")
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
        rows = snapshot.entries.sorted { lhs, rhs in
            if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map(FolderRow.init)
        defaultRows = rows.filter { !$0.entry.name.hasPrefix(".") }
    }
    func visible(query: String, showHidden: Bool, newestFirst: Bool) -> [FolderRow] {
        if query.isEmpty && !newestFirst { return showHidden ? rows : defaultRows }
        let result = rows.filter {
            (showHidden || !$0.entry.name.hasPrefix(".")) &&
            (query.isEmpty || $0.entry.name.localizedCaseInsensitiveContains(query))
        }
        guard newestFirst else { return result }
        return result.sorted {
            if ($0.entry.kind == .directory) != ($1.entry.kind == .directory) { return $0.entry.kind == .directory }
            if $0.entry.modifiedAt != $1.entry.modifiedAt { return ($0.entry.modifiedAt ?? .distantPast) > ($1.entry.modifiedAt ?? .distantPast) }
            return $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending
        }
    }
}

struct FolderView: View {
    @Bindable var model: AppModel
    let profile: ConnectionProfile
    let requestedPath: String
    @State private var listing: FolderListing?
    @State private var visible: [FolderRow]
    @State private var error: String?
    @State private var loading = false
    @State private var showHidden = false
    @State private var filter = ""
    @State private var dateSort = false
    @State private var appliedFilter = ""
    @State private var appliedShowHidden = false
    @State private var appliedDateSort = false
    @State private var refreshID = 0
    @State private var requestID = UUID()
    @State private var sortID = UUID()
    @State private var lastSessionRevision: Int
    @State private var lastRefreshID = 0
    @State private var resolving: String?
    @State private var resolveTask: Task<Void, Never>?
    init(model: AppModel, profile: ConnectionProfile, requestedPath: String) {
        self.model = model
        self.profile = profile
        self.requestedPath = requestedPath
        let cached = model.cachedListing(profile.id, path: requestedPath)
        _listing = State(initialValue: cached)
        _visible = State(initialValue: cached?.visible(query: "", showHidden: false, newestFirst: false) ?? [])
        _lastSessionRevision = State(initialValue: model.sessionRevision)
    }
    var path: String { listing?.path ?? requestedPath }
    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if let error { StatusBanner(message: listing == nil ? error : "Previously loaded folder · \(error)", error: true) }
            else if loading && listing != nil { StatusBanner(message: "Showing cached folder · refreshing…") }
            if loading && listing == nil {
                ProgressView("Connecting and opening folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listing == nil {
                ContentUnavailableView {
                    Label("Couldn’t open folder", systemImage: "folder.badge.questionmark")
                } description: { Text("Check the connection, then try again.") }
                actions: { Button("Try Again") { refreshID += 1 }.buttonStyle(.bordered) }
            } else {
                List {
                    if visible.isEmpty {
                        ContentUnavailableView(filter.isEmpty ? "This folder is empty" : "No matching names", systemImage: filter.isEmpty ? "folder" : "magnifyingglass", description: Text(filter.isEmpty ? "Pull down to check for new files." : "Filtering names in this folder only."))
                    }
                    ForEach(visible) { row in
                        let entry = row.entry
                        if entry.kind == .symlink {
                            Button { resolve(entry) } label: {
                                entryRow(row).overlay(alignment: .trailing) { if resolving == entry.path { ProgressView() } }
                            }.disabled(resolving != nil)
                        } else {
                            NavigationLink(value: route(entry)) { entryRow(row) }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await reload() }
            }
        }
        .navigationTitle(RemotePath.name(of: path))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Filter this folder")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(model.isFavourite(profile.id, path: path) ? "Remove Favourite" : "Add Favourite", systemImage: model.isFavourite(profile.id, path: path) ? "star.slash" : "star") { Task { await model.favourite(profile: profile, path: path) } }.disabled(listing == nil)
                    Button("Refresh", systemImage: "arrow.clockwise") { refreshID += 1 }
                    Toggle("Show Hidden Files", isOn: $showHidden)
                    Toggle("Newest First", isOn: $dateSort)
                    Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnectAndGoHome() } }
                } label: { Label("Folder actions", systemImage: "ellipsis.circle") }
            }
        }
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)") { await reloadIfNeeded() }
        .onDisappear { resolveTask?.cancel(); resolveTask = nil }
        .task(id: "\(filter)-\(showHidden)-\(dateSort)") { await updateVisible() }
    }
    private var pathBar: some View {
        HStack {
            Menu {
                let components = path.split(separator: "/")
                Button("/", systemImage: "externaldrive") { model.routes.append(.folder(profile.id, "/")) }
                ForEach(0..<components.count, id: \.self) { index in
                    let ancestor = "/" + components.prefix(index + 1).joined(separator: "/")
                    Button(ancestor) { model.routes.append(.folder(profile.id, ancestor)) }
                }
            } label: {
                Label(path, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
            }.accessibilityLabel("Remote path \(path). Browse ancestors")
            Text(profile.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.horizontal).background(.bar)
    }
    private func entryRow(_ row: FolderRow) -> some View {
        LocationRow(name: row.entry.name, subtitle: row.subtitle, symbol: row.symbol,
                    color: row.entry.kind == .directory ? .indigo : .secondary)
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
                model.routes.append(route(routed))
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
            let query = filter, hidden = showHidden, byDate = dateSort
            let rows = await Task.detached(priority: .userInitiated) {
                prepared.visible(query: query, showHidden: hidden, newestFirst: byDate)
            }.value
            try Task.checkCancellation()
            guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            sortID = UUID() // Supersede a filter task based on the previous listing.
            listing = prepared; visible = rows
            appliedFilter = query; appliedShowHidden = hidden; appliedDateSort = byDate
            model.cache(prepared, id: profile.id, requestedPath: requestedPath)
            model.connectionStates[profile.id] = "Connected"
            if query != filter || hidden != showHidden || byDate != dateSort { await updateVisible() }
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
    private func updateVisible() async {
        guard let listing else { return }
        guard filter != appliedFilter || showHidden != appliedShowHidden || dateSort != appliedDateSort else { return }
        let token = UUID()
        sortID = token
        let query = filter, hidden = showHidden, byDate = dateSort
        let results = await Task.detached(priority: .userInitiated) {
            listing.visible(query: query, showHidden: hidden, newestFirst: byDate)
        }.value
        guard !Task.isCancelled, token == sortID, query == filter, hidden == showHidden, byDate == dateSort else { return }
        visible = results
        appliedFilter = query; appliedShowHidden = hidden; appliedDateSort = byDate
    }
}

#endif
