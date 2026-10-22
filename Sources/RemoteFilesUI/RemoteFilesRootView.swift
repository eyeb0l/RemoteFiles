#if os(iOS)
import SwiftUI
import RemoteFilesCore
#if canImport(UIKit)
import UIKit
#endif

public struct RemoteFilesRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var lifecycleTask: Task<Void, Never>?
    public init() {}
    public var body: some View {
        Group {
            if let model { AppNavigation(model: model) }
            else if let startupError {
                ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.folder", description: Text(startupError))
            } else { ProgressView("Opening library…") }
        }
        .task {
            guard model == nil, startupError == nil else { return }
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RemoteFiles", isDirectory: true)
                let loaded = try AppModel(directory: directory)
                await loaded.load()
                if ProcessInfo.processInfo.arguments.contains("--demo") { await loaded.setDemo(true) }
                model = loaded
            } catch { startupError = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                ReaderWarmUp.cancel()
                model?.isForeground = false
                lifecycleTask = Task { await model?.background() }
            }
            if phase == .active {
                Task {
                    await lifecycleTask?.value
                    guard scenePhase == .active else { return }
                    model?.isForeground = true
                    model?.sessionRevision += 1
                }
            }
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model?.clearCaches()
            Task {
                await RemoteImageDecoder.shared.clear()
                await SourceHighlighting.shared.clear()
            }
        }
        #endif
    }
}

struct AppNavigation: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Group {
            if sizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad {
                IPadWorkspace(model: model)
            } else {
                NavigationStack(path: $model.routes) {
                    HomeView(model: model)
                        .navigationDestination(for: AppModel.Route.self) { route in
                            RouteDestination(model: model, route: route)
                        }
                }
            }
        }
        .tint(.indigo)
        .disabled(model.isDisconnecting)
        .sheet(item: $model.sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .connection(let id): ConnectionEditor(model: model, existing: id.flatMap(model.profile))
                case .keys: KeyManagerView(model: model)
                case .trust(let endpoint, let key): TrustView(model: model, endpoint: endpoint, key: key)
                case .changed(let endpoint, let previous, let current): ChangedHostView(model: model, endpoint: endpoint, previous: previous, current: current)
                case .unlock(let identity): UnlockKeyView(model: model, identity: identity)
                }
            }
        }
        .alert("RemoteFiles", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

/// Links push on iPhone; in the split workspace they select the appropriate column instead.
private struct WorkspaceNavigationKey: EnvironmentKey {
    static let defaultValue: ((AppModel.Route) -> Void)? = nil
}
extension EnvironmentValues {
    var workspaceNavigation: ((AppModel.Route) -> Void)? {
        get { self[WorkspaceNavigationKey.self] }
        set { self[WorkspaceNavigationKey.self] = newValue }
    }
}
struct WorkspaceLink<Label: View>: View {
    @Environment(\.workspaceNavigation) private var navigate
    let route: AppModel.Route
    @ViewBuilder var label: () -> Label
    var body: some View {
        if let navigate {
            Button { navigate(route) } label: { label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
        } else {
            NavigationLink(value: route, label: label)
        }
    }
}

private struct RouteDestination: View {
    @Bindable var model: AppModel
    let route: AppModel.Route
    @ViewBuilder var body: some View {
        switch route {
        case .folder(let id, let path):
            if let profile = model.profile(id) { FolderView(model: model, profile: profile, requestedPath: path) }
        case .file(let id, let entry):
            if let profile = model.profile(id) { ReaderView(model: model, profile: profile, entry: entry) }
        }
    }
}

private struct IPadWorkspace: View {
    @Bindable var model: AppModel
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            HomeView(model: model)
                .listStyle(.sidebar)
                .environment(\.workspaceNavigation, { model.routes = [$0] })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                .accessibilityIdentifier("workspace-library")
        } content: {
            NavigationStack {
                if let folder = model.workspaceFolder {
                    RouteDestination(model: model, route: folder)
                        .id(folder)
                        .toolbar {
                            if model.canGoBackInWorkspace {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Previous Folder", systemImage: "chevron.left") { model.goBackInWorkspace() }
                                }
                            }
                        }
                } else {
                    ContentUnavailableView("Choose a folder", systemImage: "folder", description: Text("Select a connection or favourite from the library."))
                }
            }
            .environment(\.workspaceNavigation, { model.openInWorkspace($0) })
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            .accessibilityIdentifier("workspace-folder")
        } detail: {
            NavigationStack {
                if let file = model.workspaceFile {
                    RouteDestination(model: model, route: file).id(file)
                } else {
                    ContentUnavailableView("Choose a file", systemImage: "doc.text", description: Text("Open a file to read it alongside its folder."))
                        .navigationTitle("Preview")
                }
            }
            .environment(\.workspaceNavigation, { model.openInWorkspace($0) })
            .accessibilityIdentifier("workspace-reader")
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct HomeView: View {
    @Bindable var model: AppModel
    private var demoIndicator: some View {
        Label("Demo workspace · sample files", systemImage: "sparkles")
            .font(.caption).foregroundStyle(.indigo)
            .textCase(nil)
    }
    var body: some View {
        List {
            if model.metadata.connections.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 44)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Browse your remote files").font(.title2.bold())
                        Text("Add an SFTP connection to browse folders and open files.")
                            .foregroundStyle(.secondary)
                        Button("Add Connection", systemImage: "plus") { model.sheet = .connection(nil) }
                            .buttonStyle(.borderedProminent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            if !model.metadata.favourites.isEmpty {
                Section {
                    ForEach(model.metadata.favourites) { location in
                        WorkspaceLink(route: AppModel.Route.folder(location.connectionID, location.path)) {
                            LocationRow(name: location.name, subtitle: "\(model.profile(location.connectionID)?.name ?? "Server") · \(location.path)", symbol: "folder.fill", color: .indigo)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.demo {
                            demoIndicator
                        }
                        Text("Favourites")
                    }
                }
            }
            Section {
                ForEach(model.metadata.connections) { profile in
                    WorkspaceLink(route: AppModel.Route.folder(profile.id, profile.startingDirectory)) {
                        LocationRow(name: profile.name, subtitle: "\(profile.host) · \(model.connectionStates[profile.id] ?? "Disconnected")", symbol: "server.rack", color: .secondary)
                    }
                    .contextMenu {
                        if !model.demo {
                            Button("Edit Connection", systemImage: "pencil") { model.sheet = .connection(profile.id) }
                            Button("Delete Connection", systemImage: "trash", role: .destructive) { Task { await model.removeConnection(profile) } }
                        }
                        Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnectAndGoHome() } }
                    }
                }
                if !model.metadata.connections.isEmpty && !model.demo {
                    Button("Add Connection", systemImage: "plus") { model.sheet = .connection(nil) }
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    if model.demo && model.metadata.favourites.isEmpty {
                        demoIndicator
                    }
                    Text("Connections")
                }
            }
            if !model.metadata.recents.isEmpty {
                Section("Recently opened") {
                    ForEach(model.metadata.recents) { location in
                        WorkspaceLink(route: AppModel.Route.file(location.connectionID, .init(name: location.name, path: location.path, kind: .file))) {
                            LocationRow(name: location.name, subtitle: model.profile(location.connectionID)?.name ?? "Server", symbol: "doc.text", color: .secondary)
                        }
                        .accessibilityIdentifier("recent-\(location.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Remove from Recents", systemImage: "clock.badge.xmark", role: .destructive) {
                                Task { await model.removeRecent(location) }
                            }
                        }
                        .accessibilityAction(named: Text("Remove from Recents")) {
                            Task { await model.removeRecent(location) }
                        }
                    }
                }
            }
            Section {
                Label("Read-only access over SFTP.", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
        }
        .navigationTitle("RemoteFiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if !model.demo { Button("SSH Keys", systemImage: "key") { model.sheet = .keys } }
                    Button(model.demo ? "Leave Demo" : "Explore Demo", systemImage: "sparkles") { Task { await model.setDemo(!model.demo) } }
                } label: { Label("Settings", systemImage: "ellipsis.circle") }
            }
        }
    }
}

struct LocationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let name: String
    let subtitle: String
    let symbol: String
    var color: Color = .indigo
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
}

struct StatusBanner: View {
    let message: String
    var error = false
    var body: some View {
        Label(message, systemImage: error ? "exclamationmark.circle" : "clock.arrow.circlepath")
            .font(.footnote).foregroundStyle(error ? Color.orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 9)
            .background(.bar)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

#endif
