#if os(iOS)
import SwiftUI
import RemoteFilesCore

struct FolderView: View {
    @Bindable var model: AppModel
    let profile: ConnectionProfile
    let requestedPath: String
    @State private var snapshot: DirectorySnapshot?
    @State private var visible: [RemoteEntry] = []
    @State private var error: String?
    @State private var loading = false
    @State private var showHidden = false
    @State private var filter = ""
    @State private var dateSort = false
    @State private var refreshID = 0
    @State private var requestID = UUID()
    @State private var sortID = UUID()
    @State private var resolving: String?
    @State private var resolveTask: Task<Void, Never>?
    var path: String { snapshot?.path ?? requestedPath }
    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if let error { StatusBanner(message: snapshot == nil ? error : "Previously loaded folder · \(error)", error: true) }
            else if loading && snapshot != nil { StatusBanner(message: "Showing cached folder · refreshing…") }
            if loading && snapshot == nil {
                ProgressView("Connecting and opening folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot == nil {
                ContentUnavailableView {
                    Label("Couldn’t open folder", systemImage: "folder.badge.questionmark")
                } description: { Text("Check the connection, then try again.") }
                actions: { Button("Try Again") { refreshID += 1 }.buttonStyle(.bordered) }
            } else {
                List {
                    if visible.isEmpty {
                        ContentUnavailableView(filter.isEmpty ? "This folder is empty" : "No matching names", systemImage: filter.isEmpty ? "folder" : "magnifyingglass", description: Text(filter.isEmpty ? "Pull down to check for new files." : "Filtering names in this folder only."))
                    }
                    ForEach(visible) { entry in
                        if entry.kind == .symlink {
                            Button { resolve(entry) } label: {
                                entryRow(entry).overlay(alignment: .trailing) { if resolving == entry.path { ProgressView() } }
                            }.disabled(resolving != nil)
                        } else {
                            NavigationLink(value: route(entry)) { entryRow(entry) }
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
                    Button(model.isFavourite(profile.id, path: path) ? "Remove Favourite" : "Add Favourite", systemImage: model.isFavourite(profile.id, path: path) ? "star.slash" : "star") { Task { await model.favourite(profile: profile, path: path) } }.disabled(snapshot == nil)
                    Button("Refresh", systemImage: "arrow.clockwise") { refreshID += 1 }
                    Toggle("Show Hidden Files", isOn: $showHidden)
                    Toggle("Newest First", isOn: $dateSort)
                    Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnect(); error = "Disconnected. Refresh to reconnect." } }
                } label: { Label("Folder actions", systemImage: "ellipsis.circle") }
            }
        }
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)") { await reload() }
        .onDisappear { resolveTask?.cancel(); resolveTask = nil }
        .task(id: "\(filter)-\(showHidden)-\(dateSort)-\(snapshot?.entries.count ?? -1)") { await updateVisible() }
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
    private func entryRow(_ entry: RemoteEntry) -> some View {
        LocationRow(name: entry.name, subtitle: metadata(entry), symbol: entry.kind == .directory ? "folder.fill" : entry.kind == .symlink ? "link" : fileSymbol(entry.name), color: entry.kind == .directory ? .indigo : .secondary)
    }
    private func fileSymbol(_ name: String) -> String {
        switch DocumentPolicy.kind(filename: name) {
        case .markdown, .pdf: "doc.richtext"
        case .image: "photo"
        case .plainText, .unsupported: "doc.text"
        }
    }
    private func metadata(_ entry: RemoteEntry) -> String {
        if entry.kind == .directory { return "Folder" }
        if entry.kind == .symlink { return "Symbolic link" }
        var pieces: [String] = []
        if let size = entry.size { pieces.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)) }
        if let date = entry.modifiedAt { pieces.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return pieces.isEmpty ? "File" : pieces.joined(separator: " · ")
    }
    private func route(_ entry: RemoteEntry) -> AppModel.Route {
        entry.kind == .directory ? .folder(profile.id, entry.path) : .file(profile.id, entry)
    }
    private func resolve(_ entry: RemoteEntry) {
        resolving = entry.path
        resolveTask = Task {
            defer { resolving = nil }
            do {
                let target = try await model.service.resolveEntry(profile: profile, path: entry.path)
                try Task.checkCancellation()
                model.routes.append(route(target))
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; model.handle(error, profile: profile) } }
        }
    }
    private func reload() async {
        guard model.isForeground else { loading = false; error = "Connection paused while the app is in the background."; return }
        let token = UUID(); requestID = token
        if snapshot == nil { snapshot = model.cachedDirectory(profile.id, path: requestedPath); await updateVisible() }
        loading = true; error = nil
        model.connectionStates[profile.id] = "Connecting…"
        do {
            let value = try await model.service.listDirectory(profile: profile, path: requestedPath)
            try Task.checkCancellation()
            guard token == requestID else { return }
            snapshot = value; model.cache(value, id: profile.id, requestedPath: requestedPath)
            model.connectionStates[profile.id] = "Connected"
            await updateVisible()
        } catch {
            guard token == requestID else { return }
            if !Task.isCancelled && !(error is CancellationError) {
                self.error = error.localizedDescription
                if model.isSecurityError(error) { snapshot = nil; visible = [] }
                model.handle(error, profile: profile)
            }
        }
        if token == requestID { loading = false }
    }
    private func updateVisible() async {
        let token = UUID()
        sortID = token
        let entries = snapshot?.entries ?? [], query = filter, hidden = showHidden, byDate = dateSort
        let results = await Task.detached(priority: .userInitiated) {
            entries.filter { (hidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }.sorted {
                if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
                if byDate && $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
        guard !Task.isCancelled, token == sortID, query == filter, hidden == showHidden, byDate == dateSort else { return }
        visible = results
    }
}

#endif
