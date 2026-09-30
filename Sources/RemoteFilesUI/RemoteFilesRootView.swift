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
            Task { await RemoteImageDecoder.shared.clear() }
        }
        #endif
    }
}

private struct AppNavigation: View {
    @Bindable var model: AppModel
    var body: some View {
        NavigationStack(path: $model.routes) {
            HomeView(model: model)
                .navigationDestination(for: AppModel.Route.self) { route in
                    switch route {
                    case .folder(let id, let path):
                        if let profile = model.profile(id) { FolderView(model: model, profile: profile, requestedPath: path) }
                    case .file(let id, let entry):
                        if let profile = model.profile(id) { ReaderView(model: model, profile: profile, entry: entry) }
                    }
                }
        }
        .tint(.indigo)
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

private struct HomeView: View {
    @Bindable var model: AppModel
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Mac. Within reach.").font(.title2.bold())
                    Text("Open a project. Pick up the story.").font(.subheadline).foregroundStyle(.secondary)
                    if model.demo { Label("Demo workspace · sample files", systemImage: "sparkles").font(.caption).foregroundStyle(.indigo) }
                }.padding(.vertical, 10)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            if model.metadata.connections.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 44)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("A place for your projects").font(.title2.bold())
                        Text("Connect to your Mac to browse folders and read the latest reports.")
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
                Section("Favourites") {
                    ForEach(model.metadata.favourites) { location in
                        NavigationLink(value: AppModel.Route.folder(location.connectionID, location.path)) {
                            LocationRow(name: location.name, subtitle: "\(model.profile(location.connectionID)?.name ?? "Mac") · \(location.path)", symbol: "folder.fill", color: .indigo)
                        }
                    }
                }
            }
            Section("Machines") {
                ForEach(model.metadata.connections) { profile in
                    NavigationLink(value: AppModel.Route.folder(profile.id, profile.startingDirectory)) {
                        LocationRow(name: profile.name, subtitle: "\(profile.host) · \(model.connectionStates[profile.id] ?? "Disconnected")", symbol: "desktopcomputer", color: .secondary)
                    }
                    .contextMenu {
                        if !model.demo {
                            Button("Edit Connection", systemImage: "pencil") { model.sheet = .connection(profile.id) }
                            Button("Delete Connection", systemImage: "trash", role: .destructive) { Task { await model.removeConnection(profile) } }
                        }
                        Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnect() } }
                    }
                }
                if !model.metadata.connections.isEmpty && !model.demo {
                    Button("Add Connection", systemImage: "plus") { model.sheet = .connection(nil) }
                }
            }
            if !model.metadata.recents.isEmpty {
                Section("Recently opened") {
                    ForEach(model.metadata.recents) { location in
                        NavigationLink(value: AppModel.Route.file(location.connectionID, .init(name: location.name, path: location.path, kind: .file))) {
                            LocationRow(name: location.name, subtitle: model.profile(location.connectionID)?.name ?? "Mac", symbol: "doc.text", color: .secondary)
                        }
                    }
                }
            }
            Section {
                Label("Read only. Your files stay on your Mac.", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
        }
        .navigationTitle("RemoteFiles")
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
    let name: String
    let subtitle: String
    let symbol: String
    var color: Color = .indigo
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
