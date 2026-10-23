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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Three columns need room in both directions, whatever the device: a regular iPad window or
    /// an unfolded iPhone Duo. A landscape phone is regular-width but compact-height, so it keeps
    /// the stack. Both layouts share `routes`, so folding or resizing keeps the current folder/file.
    static func usesWorkspace(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        horizontal == .regular && vertical == .regular
    }
    var body: some View {
        Group {
            if Self.usesWorkspace(horizontal: horizontalSizeClass, vertical: verticalSizeClass) {
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
        .safeAreaInset(edge: .bottom) { if model.sheet == nil { OfflinePinProgress(model: model) } }
        .sheet(item: $model.sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .connection(let id): ConnectionEditor(model: model, existing: id.flatMap(model.profile))
                case .keys: KeyManagerView(model: model)
                case .offlineFiles: OfflineFilesView(model: model)
                case .offlineFolder(let profile, let path, let hidden): OfflineFolderSetupView(model: model, profile: profile, path: path, includeHidden: hidden)
                case .trust(let endpoint, let key): TrustView(model: model, endpoint: endpoint, key: key)
                case .changed(let endpoint, let previous, let current): ChangedHostView(model: model, endpoint: endpoint, previous: previous, current: current)
                case .unlock(let identity): UnlockKeyView(model: model, identity: identity)
                }
            }
            .safeAreaInset(edge: .bottom) { OfflinePinProgress(model: model) }
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

/// Where each workspace column was last laid out. A plain class so layout updates don't redraw.
private final class WorkspaceColumnFrames {
    var library = CGRect.zero, folder = CGRect.zero, reader = CGRect.zero
    /// Side-by-side columns only touch; an overlaid column covers the one beneath it.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool { a.intersection(b).width > 1 }
}

private struct IPadWorkspace: View {
    @Bindable var model: AppModel
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var frames = WorkspaceColumnFrames()
    @State private var collapsedAfterSelection = false
    @State private var libraryRevealAttempts = 0
    @State private var libraryRevealRequest = 0
    private struct LibraryReveal: Equatable { let visibility: NavigationSplitViewVisibility; let request: Int }
    /// A window too narrow for three columns, such as an unfolded iPhone Duo, slides the library
    /// and folder over the reader. Close those overlays once they've done their job. Only the
    /// selecting column's frame is current, since a hidden column keeps its last frame.
    private func openFromLibrary(_ route: AppModel.Route) {
        model.routes = [route]
        if case .file = route, WorkspaceColumnFrames.overlaps(frames.library, frames.reader) {
            collapse(to: .detailOnly)
        } else if WorkspaceColumnFrames.overlaps(frames.library, frames.folder) || WorkspaceColumnFrames.overlaps(frames.library, frames.reader) {
            collapse(to: .doubleColumn)
        }
    }
    private func openFromFolder(_ route: AppModel.Route) {
        model.openInWorkspace(route)
        if case .file = route, WorkspaceColumnFrames.overlaps(frames.folder, frames.reader) { collapse(to: .detailOnly) }
    }
    private func collapse(to columns: NavigationSplitViewVisibility) {
        collapsedAfterSelection = true
        visibility = columns
    }
    private func revealLibrary() {
        guard model.workspaceFolder == nil else { return }
        libraryRevealAttempts = 3
        libraryRevealRequest += 1
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            HomeView(model: model)
                .listStyle(.sidebar)
                .environment(\.workspaceNavigation, openFromLibrary)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                .accessibilityIdentifier("workspace-library")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.library = $0 }
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
            .environment(\.workspaceNavigation, openFromFolder)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            .accessibilityIdentifier("workspace-folder")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.folder = $0 }
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.reader = $0 }
        }
        .navigationSplitViewStyle(.balanced)
        // A narrow window collapses the library at launch, leaving only empty placeholders.
        // While there's no folder, open it once the system has settled on its columns; that
        // can take two requests, since a reader-only window first opens just the folder.
        // Each launch, resize or cleared folder reveals it once, so closing it again sticks.
        .task(id: LibraryReveal(visibility: visibility, request: libraryRevealRequest)) {
            guard libraryRevealAttempts > 0, model.workspaceFolder == nil else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, model.workspaceFolder == nil else { return }
            if visibility == .all { libraryRevealAttempts = 0 } else { libraryRevealAttempts -= 1; visibility = .all }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { old, width in
            // Narrowing already collapses columns; a wider window may now fit what we closed.
            if collapsedAfterSelection, width > old { collapsedAfterSelection = false; visibility = .all }
            revealLibrary()
        }
        .onChange(of: model.workspaceFolder == nil) { _, noFolder in if noFolder { revealLibrary() } }
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
            Section {
                Button { model.sheet = .offlineFiles } label: {
                    LocationRow(name: "Offline Files", subtitle: "\(model.offlinePins.count) files · \(model.offlineFolders.count) folders saved", symbol: "pin.fill", color: .indigo)
                }
                .accessibilityIdentifier("offline-library")
            }
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
