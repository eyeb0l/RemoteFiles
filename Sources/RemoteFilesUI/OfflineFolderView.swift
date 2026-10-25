#if os(iOS)
import SwiftUI
import RemoteFilesCore

struct OfflineFolderPinActions: View {
    let model: AppModel
    let profile: ConnectionProfile
    let path: String
    var includeHidden = false
    var body: some View {
        let folder = model.offlineFolder(profile: profile, path: path)
        Button(folder == nil ? "Keep Folder Offline" : "Update Offline Folder", systemImage: "pin") {
            if let folder { model.refreshOfflineFolder(folder) }
            else { model.sheet = .offlineFolder(profile, path, includeHidden) }
        }
        .disabled(model.pinningName != nil || model.offlineStore == nil || !model.isForeground)
        if let folder {
            Button("Remove Offline Folder", systemImage: "pin.slash", role: .destructive) {
                Task { await model.removeOfflineFolder(folder) }
            }
        }
    }
}

struct OfflineFolderSetupView: View {
    let model: AppModel
    let profile: ConnectionProfile
    let path: String
    @State private var includeHidden: Bool
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, profile: ConnectionProfile, path: String, includeHidden: Bool) {
        self.model = model; self.profile = profile; self.path = path
        _includeHidden = State(initialValue: includeHidden)
    }
    var body: some View {
        Form {
            Section {
                Label(RemotePath.name(of: path).isEmpty ? "Root" : RemotePath.name(of: path), systemImage: "folder.fill")
                Text(profile.name + " · " + path).font(.caption).foregroundStyle(.secondary)
                Text("Save this folder and its subfolders on this device. Updates happen only when you choose Update.")
                Toggle("Include Hidden Files", isOn: $includeHidden)
            }
            Section {
                Text("Symbolic links and special files are skipped. If any regular file can’t be read, a limit is reached, or you cancel, the previous saved folder stays available.")
                Text("The library holds up to 32 saved folders, 100 files and 512 MiB in total, with 128 MiB per file. A folder can contain up to 256 directories, 16 levels and 10,000 entries. Saves stop after 10 minutes.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Save Folder Offline", systemImage: "pin.fill") {
                    model.sheet = nil
                    model.pinOffline(profile: profile,
                        entry: .init(name: RemotePath.name(of: path).isEmpty ? "Root" : RemotePath.name(of: path), path: path, kind: .directory),
                        includeHidden: includeHidden)
                    dismiss()
                }
                .disabled(model.pinningName != nil || !model.isForeground)
            }
        }
        .navigationTitle("Keep Folder Offline")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .accessibilityIdentifier("offline-folder-setup")
    }
}

struct OfflineFolderLibraryActions: View {
    let model: AppModel
    let folder: OfflineFolderPin
    var body: some View {
        Button("Update Offline Folder", systemImage: "arrow.clockwise") { model.refreshOfflineFolder(folder) }
            .disabled(model.pinningName != nil || !model.isForeground)
        Button("Remove Offline Folder", systemImage: "trash", role: .destructive) {
            Task { await model.removeOfflineFolder(folder) }
        }
    }
}

/// Byte-sensitive identity preserves distinct SFTP names with different Unicode normalization.
struct OfflineFolderRoute: Hashable {
    let folderID: UUID
    let path: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.folderID == rhs.folderID && lhs.path.utf8.elementsEqual(rhs.path.utf8)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(folderID); hasher.combine(Data(path.utf8)) }
}

struct OfflineFolderView: View {
    let model: AppModel
    let route: OfflineFolderRoute
    private var folder: OfflineFolderPin? { model.offlineFolders.first { $0.id == route.folderID } }
    private func isChild(_ path: String) -> Bool {
        !path.utf8.elementsEqual(route.path.utf8) && RemotePath.parent(of: path).utf8.elementsEqual(route.path.utf8)
    }
    var body: some View {
        Group {
            if let folder, folder.directories.contains(where: { $0.utf8.elementsEqual(route.path.utf8) }) {
                let directories = folder.directories.filter(isChild).map { OfflineFolderRoute(folderID: folder.id, path: $0) }
                let files = model.offlinePins.filter { folder.fileIDs.contains($0.id) && isChild($0.path) }
                List {
                    Section {
                        Text("Offline folder · saved \(folder.savedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("offline-folder-date")
                        Text(folder.includeHidden ? "Hidden files included" : "Hidden files excluded").font(.caption).foregroundStyle(.secondary)
                        if folder.skippedLinks + folder.skippedOtherEntries > 0 {
                            Text("\(folder.skippedLinks) symbolic links and \(folder.skippedOtherEntries) special files skipped")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(directories.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }), id: \.self) { child in
                        NavigationLink(value: child) { Label(RemotePath.name(of: child.path), systemImage: "folder.fill") }
                            .accessibilityIdentifier("offline-subfolder-" + RemotePath.name(of: child.path))
                    }
                    ForEach(files.sorted(by: { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending })) { pin in
                        NavigationLink(value: OfflineDocumentRoute(pin: pin)) { Label(pin.filename, systemImage: "doc.fill") }
                        .accessibilityIdentifier("offline-file-" + pin.filename)
                    }
                    if directories.isEmpty && files.isEmpty {
                        ContentUnavailableView("Empty saved folder", systemImage: "folder", description: Text("There are no saved files in this folder."))
                    }
                }
                .navigationTitle(route.path.utf8.elementsEqual(folder.path.utf8) ? folder.name : RemotePath.name(of: route.path))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu { OfflineFolderLibraryActions(model: model, folder: folder) }
                        label: { Label("Saved folder actions", systemImage: "ellipsis.circle") }
                    }
                }
            } else {
                ContentUnavailableView("Saved folder unavailable", systemImage: "folder.badge.questionmark", description: Text("This folder was removed or changed by an update. Go back to Offline Files."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
