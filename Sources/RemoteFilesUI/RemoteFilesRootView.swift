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
            } else { LoadingPlaceholder(label: "Opening library…") }
        }
        .privacySensitive()
        .task {
            guard model == nil, startupError == nil else { return }
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("RemoteFiles", isDirectory: true)
                let loaded = try AppModel(directory: directory)
                await loaded.load()
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--demo") {
                    await loaded.setDemo(true)
                    // Demo-only, for acceptance: let saved indexes update automatically without waiting.
                    if let flag = arguments.firstIndex(of: "--index-update-interval"), flag + 1 < arguments.count,
                       let seconds = TimeInterval(arguments[flag + 1]), seconds >= 0 {
                        loaded.indexUpdates.interval = seconds
                    }
                }
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
                    model?.sceneBecameActive()
                }
            }
        }
        #if canImport(UIKit)
        .background(RootWindowPrivacyInstaller(isVisible: scenePhase != .active))
        #endif
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

#if canImport(UIKit)
/// SwiftUI overlays live beneath a presented sheet. This zero-sized bridge also
/// installs the same shield directly on the window, above every presentation,
/// so connection editors and readers cannot leak through an app-switcher snapshot.
struct RootWindowPrivacyInstaller: UIViewRepresentable {
    let isVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(anchor: view, isVisible: isVisible)
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor final class Coordinator {
        private weak var window: UIWindow?
        private var desiredVisibility = false
        private var revision = 0
        private let shield: UIView = {
            let shield = UIView(frame: .zero)
            shield.backgroundColor = .systemBackground
            shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shield.isAccessibilityElement = true
            shield.accessibilityLabel = "RemoteFiles is hidden while inactive"
            shield.accessibilityIdentifier = "privacy-cover"
            shield.accessibilityViewIsModal = true

            let image = UIImageView(image: UIImage(systemName: "lock.fill"))
            image.tintColor = .tertiaryLabel
            image.contentMode = .scaleAspectFit
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            let label = UILabel()
            label.text = "RemoteFiles Locked"
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            let stack = UIStackView(arrangedSubviews: [image, label])
            stack.axis = .vertical; stack.alignment = .center; stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            shield.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
            ])
            return shield
        }()

        func update(anchor: UIView, isVisible: Bool) {
            desiredVisibility = isVisible
            revision &+= 1
            let scheduledRevision = revision
            guard isVisible else { removeShield(); return }
            guard let target = anchor.window else {
                DispatchQueue.main.async { [weak self, weak anchor] in
                    guard let self, let anchor else { return }
                    guard self.desiredVisibility, self.revision == scheduledRevision,
                          let target = anchor.window else { return }
                    self.install(in: target)
                }
                return
            }
            install(in: target)
        }

        private func install(in target: UIWindow) {
            if window !== target || shield.superview !== target {
                shield.removeFromSuperview()
                window = target
                shield.frame = target.bounds
                target.addSubview(shield)
            } else {
                target.bringSubviewToFront(shield)
            }
        }

        func dismantle() {
            desiredVisibility = false
            revision &+= 1
            removeShield()
        }

        private func removeShield() {
            shield.removeFromSuperview()
            window = nil
        }
    }
}
#endif

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
                        .listStyle(.plain)
                        .navigationDestination(for: AppModel.Route.self) { route in
                            RouteDestination(model: model, route: route)
                        }
                }
            }
        }
        .tint(RemoteFilesStyle.accent)
        .disabled(model.isDisconnecting)
        // A sheet publishes its own navigation, if it has any.
        .focusedSceneValue(\.navigationCommands, model.sheet == nil && !model.isDisconnecting ? navigationCommands : nil)
        .safeAreaInset(edge: .bottom) { if model.sheet == nil { OfflinePinProgress(model: model) } }
        .sheet(item: $model.sheet) { sheet in
            Group {
                if case .offlineFiles = sheet { OfflineFilesView(model: model) }
                else {
                    NavigationStack {
                        switch sheet {
                        case .connection(let id): ConnectionEditor(model: model, existing: id.flatMap(model.profile))
                        case .keys: KeyManagerView(model: model)
                        case .offlineFiles: EmptyView()
                        case .downloads: DownloadsView(model: model)
                        case .offlineFolder(let profile, let path, let hidden): OfflineFolderSetupView(model: model, profile: profile, path: path, includeHidden: hidden)
                        case .trust(let endpoint, let key): TrustView(model: model, endpoint: endpoint, key: key)
                        case .changed(let endpoint, let previous, let current): ChangedHostView(model: model, endpoint: endpoint, previous: previous, current: current)
                        case .unlock(let identity): UnlockKeyView(model: model, identity: identity)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { OfflinePinProgress(model: model) }
            .tint(RemoteFilesStyle.accent)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    /// Back matches the workspace's Previous Folder button, or pops the stack.
    private var navigationCommands: NavigationCommandActions {
        let back: (() -> Void)?
        let workspace = Self.usesWorkspace(horizontal: horizontalSizeClass, vertical: verticalSizeClass)
        if workspace {
            back = model.canGoBackInWorkspace ? { model.goBackInWorkspace() } : nil
        } else {
            back = model.routes.isEmpty ? nil : { model.routes.removeLast() }
        }
        return NavigationCommandActions(context: workspace ? "workspace" : "stack", back: back, downloads: { model.sheet = .downloads }, offlineFiles: { model.sheet = .offlineFiles })
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
    /// and folder over the reader. Close those overlays once they've done their job. A hidden
    /// library or folder keeps its last frame, so each check reads only columns on screen: the
    /// selecting one, the folder whenever the library shows, and the reader, which as the detail
    /// column is never hidden and so follows every resize.
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
                    ContentUnavailableView("Choose a folder", systemImage: "folder", description: Text("Pick a connection or favourite."))
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
                    ContentUnavailableView("Choose a file", systemImage: "doc.text", description: Text("It opens here, beside its folder."))
                        .navigationTitle("")
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

/// Kept small and apart from Home, so a download's progress redraws only this.
private struct DownloadsBarButton: View {
    let model: AppModel
    private var active: Int {
        model.downloads?.items.filter { $0.state == .queued || $0.state == .downloading }.count ?? 0
    }
    var body: some View {
        Button { model.sheet = .downloads } label: {
            BarLabel(title: active > 0 ? "Downloads · \(active)" : "Downloads", symbol: "arrow.down.circle")
        }
        .accessibilityLabel(active > 0 ? "Downloads, \(active) in progress" : "Downloads")
        .accessibilityIdentifier("download-manager")
    }
}

struct HomeView: View {
    @Bindable var model: AppModel
    /// Connection names only help tell servers apart when there's more than one.
    private var showsConnectionNames: Bool { model.metadata.connections.count > 1 }
    private func state(_ profile: ConnectionProfile) -> (label: String, color: Color?) {
        switch model.connectionStates[profile.id] {
        case "Connected": return ("Connected", .green)
        case "Connecting…": return ("Connecting…", .orange)
        default: return ("Disconnected", nil)
        }
    }
    var body: some View {
        List {
            if model.metadata.connections.isEmpty {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(spacing: 6) {
                            Text("Browse your remote files").font(.title3.weight(.semibold))
                            Text("Connect to a server you control. Read-only over SFTP.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button("Add Connection", systemImage: "plus") { model.sheet = .connection(nil) }
                            .buttonStyle(.borderedProminent)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            if !model.metadata.favourites.isEmpty {
                Section("Favourites") {
                    ForEach(model.metadata.favourites) { location in
                        let server = model.profile(location.connectionID)?.name ?? "Server"
                        WorkspaceLink(route: AppModel.Route.folder(location.connectionID, location.path)) {
                            LocationRow(name: location.name, subtitle: "\(server) · \(location.path)", symbol: "folder.fill",
                                        color: RemoteFilesStyle.accent,
                                        visibleSubtitle: showsConnectionNames ? "\(server) · \(location.path)" : location.path)
                        }
                    }
                }
            }
            if !model.metadata.connections.isEmpty {
                Section("Connections") {
                    ForEach(model.metadata.connections) { profile in
                        let state = state(profile)
                        WorkspaceLink(route: AppModel.Route.folder(profile.id, profile.startingDirectory)) {
                            LocationRow(name: profile.name, subtitle: "\(profile.host) · \(state.label)", symbol: "server.rack",
                                        visibleSubtitle: state.color == nil ? profile.host : "\(profile.host) · \(state.label)",
                                        statusColor: state.color)
                        }
                        .contextMenu {
                            if !model.demo {
                                Button("Edit Connection", systemImage: "pencil") { model.sheet = .connection(profile.id) }
                                Button("Delete Connection", systemImage: "trash", role: .destructive) { Task { await model.removeConnection(profile) } }
                            }
                            Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnectAndGoHome() } }
                        }
                    }
                }
            }
            if !model.metadata.recents.isEmpty {
                Section("Recently opened") {
                    ForEach(model.metadata.recents) { location in
                        let server = model.profile(location.connectionID)?.name ?? "Server"
                        WorkspaceLink(route: AppModel.Route.file(location.connectionID, .init(name: location.name, path: location.path, kind: .file))) {
                            LocationRow(name: location.name, subtitle: server, symbol: FileSymbol.name(forFilename: location.name),
                                        visibleSubtitle: showsConnectionNames ? server : .some(nil))
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
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
        }
        // First navigation resolves many types at once; do what can be done ahead, away from
        // the main thread, as soon as the library has had its own first layout.
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { ReaderWarmUp.start() }
        }
        .navigationTitle("RemoteFiles")
        .navigationSubtitle(model.demo ? "Demo workspace · sample files" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.demo && !model.metadata.connections.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Connection", systemImage: "plus") { model.sheet = .connection(nil) }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if !model.demo { Button("SSH Keys", systemImage: "key") { model.sheet = .keys } }
                    Button(model.demo ? "Leave Demo" : "Explore Demo", systemImage: "sparkles") { Task { await model.setDemo(!model.demo) } }
                } label: { Label("Settings", systemImage: "ellipsis") }
            }
            ToolbarItem(placement: .bottomBar) {
                Button { model.sheet = .offlineFiles } label: { BarLabel(title: "Offline", symbol: "pin") }
                    .accessibilityLabel("Offline Files, \(model.offlinePins.count) files, \(model.offlineFolders.count) folders saved")
                    .accessibilityIdentifier("offline-library")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                DownloadsBarButton(model: model)
            }
        }
    }
}

#endif
