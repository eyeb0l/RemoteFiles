#if os(iOS)
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import RemoteFilesCore

// MARK: - The Transfers list

struct TransfersView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if let queue = model.transfers {
                if let error = queue.persistenceError { Text(error).foregroundStyle(.red) }
                if queue.items.isEmpty {
                    ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down.circle",
                        description: Text("Choose Upload Files in a folder’s menu, or touch and hold a file and choose Copy to… to send it to another server."))
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(queue.items) { item in
                        TransferRow(item: item, isActive: queue.activeID == item.id, canRetry: model.canTransfer,
                                    cancel: { queue.cancel(item.id) },
                                    retry: { model.retryTransfer(item, conflict: $0) },
                                    remove: { model.removeTransfer(item) })
                    }
                } footer: {
                    // Only while it matters: nothing is running once the list is all results.
                    if queue.items.contains(where: \.isPending) {
                        Text(model.backgroundTransfers.status)
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
            } else if let error = model.transferError ?? model.downloadError { Text(error).foregroundStyle(.red) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .presentationBackground(Color(uiColor: .systemBackground))
        .navigationTitle("Transfers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            if model.transfers?.items.contains(where: { $0.state == .completed || $0.state == .cancelled }) == true {
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear Finished") { model.transfers?.removeFinished() }
                }
            }
        }
        .modifier(DeleteAllLocalFilesAction(title: "Remove all transfers?",
            message: "This cancels queued and active transfers and clears this list. Files already sent stay on their servers.",
            isAvailable: model.transfers?.items.isEmpty == false) { [queue = model.transfers, transport = model.uploadTransport] in
            queue?.removeAll(service: transport)
        })
        .onAppear { model.transferProblemsSeen() }
        .onChange(of: model.transfers?.items.count) { model.transferProblemsSeen() }
    }
}

private struct TransferRow: View {
    @ScaledMetric(relativeTo: .body) private var iconColumn = RemoteFilesStyle.iconColumn
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: ManagedTransfer
    let isActive: Bool
    let canRetry: Bool
    let cancel: () -> Void
    let retry: (UploadConflictPolicy?) -> Void
    let remove: () -> Void
    private var stateText: String {
        switch item.state {
        case .transferring: return item.progress.transferLabel()
        case .completed: return item.isCopy ? "Copied" : "Uploaded"
        case .failed where item.nameTaken: return "Name Taken"
        default: return item.state.rawValue.capitalized
        }
    }
    private var symbol: String {
        switch item.state {
        case .completed: return "checkmark.circle.fill"
        case .transferring: return item.isCopy ? "arrow.left.arrow.right.circle" : "arrow.up.circle"
        case .queued: return "clock"
        default: return "exclamationmark.circle"
        }
    }
    private var symbolColor: Color {
        switch item.state {
        case .completed: return .green
        case .transferring, .queued: return .secondary
        default: return .orange
        }
    }
    /// Where it is going: the folder first, since a long server name is what gets cut short.
    private var route: String { "\(RemotePath.displayName(RemotePath.name(of: item.directory))) on \(item.destination.name)" }
    /// Where a copy from another server came from.
    private var origin: String? {
        guard let source = item.sourceProfile, source.id != item.destination.id else { return nil }
        return "From \(source.name)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(symbolColor)
                    .frame(width: iconColumn).accessibilityHidden(true)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(RemotePath.displayName(item.filename)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Text("\(stateText) · \(route)")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .contentTransition(.numericText())
                    if let origin {
                        Text(origin).font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                trailingAction
            }
            if item.state == .transferring { ThinProgress(fraction: item.progress.fraction) }
            if item.keepsPartialBytes, !item.nameTaken {
                Text("\(item.progress.transferLabel()). Retry continues from there.")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let message = item.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash", role: .destructive, action: remove).tint(.red)
        }
        .contextMenu { Button("Remove", systemImage: "trash", role: .destructive, action: remove) }
        .accessibilityActions { Button("Remove", action: remove) }
        .sensoryFeedback(.success, trigger: item.state) { _, new in new == .completed }
    }
    @ViewBuilder private var trailingAction: some View {
        Group {
            switch item.state {
            case .completed: EmptyView()
            case .queued, .transferring:
                Button(role: .destructive, action: cancel) { IconTarget(symbol: "xmark.circle") }.accessibilityLabel("Cancel")
            case .failed where item.nameTaken:
                // The bytes are already on the server; either answer only gives them a name.
                Menu {
                    Button("Replace", systemImage: "arrow.triangle.2.circlepath", role: .destructive) { retry(.replace) }
                    Button("Keep Both", systemImage: "plus.square.on.square") { retry(.keepBoth) }
                } label: { IconTarget(symbol: "questionmark.circle") }
                    .accessibilityLabel("Name Taken: Replace or Keep Both").disabled(!canRetry)
            default:
                Button { retry(nil) } label: { IconTarget(symbol: "arrow.clockwise") }.accessibilityLabel("Retry").disabled(!canRetry || isActive)
            }
        }
        .buttonStyle(.borderless)
    }
}

/// What uploads and copies are doing, as a button in the navigation bar: a ring that fills while they run,
/// a mark when one needs attention or has just finished. It opens Transfers. Kept small and apart from the
/// screens that show it, so a transfer's progress redraws only this, and in the bar rather than over the
/// content, so that starting a transfer covers nothing and takes no folder away.
struct TransferStatus: ToolbarContent {
    let model: AppModel
    /// Home shows it whenever there is anything in the list; a folder only while there is something to say.
    var whenListed = false
    var body: some ToolbarContent {
        // The item itself comes and goes: an empty one would still draw its place in the bar.
        if TransferStatusButton.isShown(model, whenListed: whenListed) {
            ToolbarItem(placement: .primaryAction) { TransferStatusButton(model: model) }
        }
    }
}

struct TransferStatusButton: View {
    let model: AppModel
    static func isShown(_ model: AppModel, whenListed: Bool) -> Bool {
        guard let queue = model.transfers else { return false }
        return queue.items.contains(where: \.isPending) || model.unseenTransferProblems(in: queue.items) > 0
            || model.transferNotice != nil || (whenListed && !queue.items.isEmpty)
    }
    var body: some View {
        let pending = model.transfers?.items.filter(\.isPending) ?? []
        let problems = model.unseenTransferProblems(in: model.transfers?.items ?? [])
        let finished = model.transferNotice
        Button { model.sheet = .transfers } label: {
            Group {
                if !pending.isEmpty { TransferRing(fraction: Self.fraction(of: pending)) }
                else if problems > 0 { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                else if finished != nil { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                else { Image(systemName: "arrow.up.arrow.down.circle") }
            }
            .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(Self.label(pending: pending, problems: problems, finished: finished))
        .accessibilityIdentifier("transfer-manager")
        .sensoryFeedback(.success, trigger: finished) { _, new in new != nil }
    }
    static func label(pending: [ManagedTransfer], problems: Int, finished: String?) -> String {
        if !pending.isEmpty {
            let percent = fraction(of: pending).map { ", \(Int(($0 * 100).rounded())) percent" } ?? ""
            return "Transfers, \(pending.count) in progress\(percent)"
        }
        if problems > 0 { return problems == 1 ? "Transfers, one needs attention" : "Transfers, \(problems) need attention" }
        return finished.map { "Transfers, \($0)" } ?? "Transfers"
    }
    /// Across everything still to do; unknown while any size is.
    static func fraction(of pending: [ManagedTransfer]) -> Double? {
        var sent: UInt64 = 0, total: UInt64 = 0
        for item in pending {
            guard let expected = item.expectedBytes else { return nil }
            sent += min(item.sentBytes, expected); total += expected
        }
        return total == 0 ? nil : Double(sent) / Double(total)
    }
}

/// A small ring that fills as bytes are confirmed, around an arrow that says which way they are going.
private struct TransferRing: View {
    let fraction: Double?
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
            if let fraction {
                Circle().trim(from: 0, to: max(0.03, min(1, fraction)))
                    .stroke(RemoteFilesStyle.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
            }
            Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundStyle(RemoteFilesStyle.accent)
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Choosing files to upload

/// The system's file browser, asked for copies: the files it returns are the app's own to move into the
/// transfer queue, and the originals stay where they are.
struct UploadFilePicker: UIViewControllerRepresentable {
    let picked: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = true
        controller.shouldShowFileExtensions = true
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: ([URL]) -> Void
        init(picked: @escaping ([URL]) -> Void) { self.picked = picked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls) }
    }
}

/// A photo or video chosen from the library, as the file the library hands over: the original's bytes in
/// its current format, copied to a folder of its own because the library's file goes when the hand-over ends.
struct PickedLibraryFile: Transferable {
    let url: URL
    static let folderPrefix = "remotefiles-picked-"

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try PickedLibraryFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try PickedLibraryFile(copying: $0.file) }
    }
    private init(copying file: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(file.lastPathComponent)
        do { try FileManager.default.copyItem(at: file, to: url) }
        catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Removes copies a previous run of the app made and never queued, as when it was closed while asking
    /// about a taken name. Called once a process, before anything can be chosen.
    static func removeAbandoned(in directory: URL = FileManager.default.temporaryDirectory) {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.lastPathComponent.hasPrefix(folderPrefix) { try? FileManager.default.removeItem(at: child) }
    }

    /// The copies of what was chosen, in the order chosen, and how many items couldn't be loaded.
    static func load(_ items: [PhotosPickerItem]) async -> (files: [URL], failed: Int) {
        var files: [URL] = [], failed = 0
        for item in items {
            if Task.isCancelled { break }
            if let picked = try? await item.loadTransferable(type: PickedLibraryFile.self) { files.append(picked.url) } else { failed += 1 }
        }
        return (files, failed)
    }
}

/// Copies files dragged in from another app into the queue's own folder. A provider's file exists only
/// until its handler returns, so each is copied there and then.
enum UploadDrop {
    static let types = [UTType.item]
    /// What a link or a selection of text is offered as. Styled text comes as an archive of itself as well.
    private static func isTextOrLink(_ type: UTType) -> Bool {
        type.conforms(to: .url) || type.conforms(to: .text) || [UTType.flatRTFD, .rtfd, .webArchive].contains { type.conforms(to: $0) }
    }

    /// What to say of dropped items that were left out, or nil if none was. One that isn't a file (a folder,
    /// a link, selected text) is a different matter from a file that couldn't be read, as one in iCloud that
    /// didn't arrive, and the second is not told that folders can't be uploaded.
    static func message(skipped: Int, unread: Int) -> String? {
        var said: [String] = []
        if skipped > 0 {
            said.append(skipped == 1 ? "One item wasn’t a file and wasn’t uploaded. Folders can’t be uploaded yet."
                : "\(skipped) items weren’t files and weren’t uploaded. Folders can’t be uploaded yet.")
        }
        if unread > 0 {
            said.append(unread == 1 ? "One file couldn’t be read and wasn’t uploaded." : "\(unread) files couldn’t be read and weren’t uploaded.")
        }
        return said.isEmpty ? nil : said.joined(separator: " ")
    }

    /// Whether what a provider handed over is a regular file, or nil if that can't be told: only something
    /// known not to be one is a folder, and anything that can't be looked at is a file that couldn't be read.
    static func isRegularFile(_ url: URL) -> Bool? { (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile }

    /// Calls `done` on the main actor with the copies made, how many dropped items were not files, and how
    /// many were files that could not be read.
    @MainActor static func load(_ providers: [NSItemProvider], into folder: URL,
                                done: @escaping @MainActor ([URL], _ skipped: Int, _ unread: Int) -> Void) {
        let results = Results()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            // A folder of its own for each, so two files of one name don't collide before they are queued.
            let place = folder.appendingPathComponent("\(index)", isDirectory: true)
            // A dragged link or piece of selected text is not a file someone meant to send. A file says so by
            // offering a file URL beside its contents, or failing that by having contents that aren't text, or a
            // name and no link: a link to a page can come with the page's title as its name and its address as text.
            let types = provider.registeredContentTypes
            let offersLink = types.contains { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }
            let isFile = types.contains { $0.conforms(to: .fileURL) } || !types.allSatisfy(Self.isTextOrLink)
                || (provider.suggestedName != nil && !offersLink)
            // A provider answers for the types it registered, not for one they conform to, so it is asked
            // for its own: the first that is file contents and not a reference to them.
            guard isFile, let content = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) }) else {
                results.skip(); group.leave(); continue
            }
            // The file handed over has a made-up name unless the provider suggests one. Its file URL has the real one.
            let copy: @Sendable (String?) -> Void = { original in
                _ = provider.loadFileRepresentation(forTypeIdentifier: content.identifier) { url, _ in
                    defer { group.leave() }
                    guard let url, let isFile = Self.isRegularFile(url) else { results.fail(); return }
                    guard isFile else { results.skip(); return }
                    let suggested = provider.suggestedName.map { suggested in
                        // The suggestion often lacks the extension the file itself has.
                        url.pathExtension.isEmpty || suggested.hasSuffix("." + url.pathExtension) ? suggested : suggested + "." + url.pathExtension
                    }
                    let name = [suggested, original].compactMap { $0 }.first(where: UploadRequest.isValidName) ?? url.lastPathComponent
                    do {
                        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                        let copy = place.appendingPathComponent(name)
                        try FileManager.default.copyItem(at: url, to: copy)
                        results.add(copy, at: index)
                    } catch { results.fail() }
                }
            }
            if provider.suggestedName == nil, types.contains(where: { $0.conforms(to: .fileURL) }) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    copy(url.flatMap { $0.isFileURL ? $0.lastPathComponent : nil })
                }
            } else { copy(nil) }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { done(results.files, results.skipped, results.unread) }
        }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var copies: [(Int, URL)] = []
        private var missed = 0, failed = 0
        var files: [URL] { lock.withLock { copies.sorted { $0.0 < $1.0 }.map(\.1) } }
        var skipped: Int { lock.withLock { missed } }
        var unread: Int { lock.withLock { failed } }
        func add(_ url: URL, at index: Int) { lock.withLock { copies.append((index, url)) } }
        func skip() { lock.withLock { missed += 1 } }
        func fail() { lock.withLock { failed += 1 } }
    }
}

// MARK: - Names already taken

/// Files chosen for a folder that already holds some of their names, waiting for an answer.
struct TransferConflictPrompt: Identifiable {
    let id = UUID()
    /// The names already in the folder.
    let names: [String]
    /// How many files were chosen in all.
    let total: Int
    /// The answer for the taken names, or nil to leave those files out and send the rest.
    let resolve: (UploadConflictPolicy?) -> Void
    /// Nothing is sent.
    let cancel: () -> Void
}

private struct TransferConflictDialog: ViewModifier {
    @Binding var prompt: TransferConflictPrompt?
    /// Kept while the dialog closes, when the binding is already nil.
    @State private var shown: TransferConflictPrompt?
    @State private var answered = false
    func body(content: Content) -> some View {
        content
            .onChange(of: prompt?.id) { if let prompt { shown = prompt; answered = false } }
            .confirmationDialog(title, isPresented: Binding(get: { prompt != nil }, set: { presented in
                guard !presented else { return }
                // Closed without choosing counts as Cancel.
                if !answered { answered = true; (prompt ?? shown)?.cancel() }
                prompt = nil
            }), titleVisibility: .visible) {
                Button("Replace", role: .destructive) { answer { $0.resolve(.replace) } }
                Button("Keep Both") { answer { $0.resolve(.keepBoth) } }
                if let shown = prompt ?? shown, shown.total > shown.names.count {
                    Button(shown.names.count == 1 ? "Skip This File" : "Skip These Files") { answer { $0.resolve(nil) } }
                }
                Button("Cancel", role: .cancel) { answer { $0.cancel() } }
            } message: { Text(message) }
    }
    private func answer(_ act: (TransferConflictPrompt) -> Void) {
        guard !answered, let current = prompt ?? shown else { return }
        answered = true
        act(current)
    }
    private var title: String {
        guard let shown = prompt ?? shown else { return "" }
        return shown.names.count == 1 ? "“\(RemotePath.displayName(shown.names[0]))” is already in this folder"
            : "\(shown.names.count) of these files are already in this folder"
    }
    private var message: String {
        guard let shown = prompt ?? shown else { return "" }
        let listed = shown.names.prefix(3).map { RemotePath.displayName($0) }.joined(separator: ", ")
        let names = shown.names.count > 1 ? listed + (shown.names.count > 3 ? " and \(shown.names.count - 3) more. " : ". ") : ""
        return names + "Replace overwrites what is on the server. Keep Both adds a number to the new name."
    }
}

extension View {
    func transferConflictDialog(_ prompt: Binding<TransferConflictPrompt?>) -> some View { modifier(TransferConflictDialog(prompt: prompt)) }
}

// MARK: - Choosing where a copy goes

/// Picks a folder on any connection, including the one the file is on, to copy files into.
struct TransferDestinationPicker: View {
    let model: AppModel
    let source: ConnectionProfile
    let entries: [RemoteEntry]
    @Environment(\.dismiss) private var dismiss
    struct Place: Hashable { let connectionID: UUID; let path: String }
    private var title: String {
        entries.count == 1 ? "Copy “\(RemotePath.displayName(entries[0].exportFilename ?? entries[0].name))”" : "Copy \(entries.count) Files"
    }
    var body: some View {
        List {
            Section {
                ForEach(model.metadata.connections) { profile in
                    NavigationLink(value: Place(connectionID: profile.id, path: profile.startingDirectory)) {
                        LocationRow(name: profile.name, subtitle: profile.id == source.id ? "\(profile.host) · This server" : profile.host,
                                    symbol: "server.rack")
                    }
                }
            } header: { Text("Choose a server, then a folder") }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .navigationDestination(for: Place.self) { place in
            if let profile = model.profile(place.connectionID) {
                TransferDestinationFolder(model: model, source: source, entries: entries, profile: profile, requestedPath: place.path)
            }
        }
    }
}

private struct TransferDestinationFolder: View {
    let model: AppModel
    let source: ConnectionProfile
    let entries: [RemoteEntry]
    let profile: ConnectionProfile
    let requestedPath: String
    @State private var listing: FolderListing?
    @State private var folders: [FolderRow] = []
    @State private var error: String?
    @State private var attempt = 0
    @State private var conflict: TransferConflictPrompt?
    private var path: String { listing?.path ?? requestedPath }
    /// Copying a file onto itself would replace it with a file that is being read.
    private var holdsSource: Bool {
        guard profile.id == source.id, let listing else { return false }
        return entries.contains { RemotePath.parent(of: $0.path).utf8.elementsEqual(listing.path.utf8) }
    }
    var body: some View {
        Group {
            if let listing {
                List {
                    if folders.isEmpty {
                        ContentUnavailableView("No folders here", systemImage: "folder", description: Text("Copy Here puts the file in this folder."))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(folders) { row in
                        NavigationLink(value: TransferDestinationPicker.Place(connectionID: profile.id, path: row.entry.followingLink()?.path ?? row.entry.path)) {
                            LocationRow(name: row.entry.name, subtitle: "Folder", symbol: "folder.fill", color: RemoteFilesStyle.accent, visibleSubtitle: .some(nil))
                        }
                    }
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 6) {
                        if holdsSource {
                            Text("This is the folder the file is in. Choose another.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Button { copyHere(listing) } label: {
                            Label("Copy Here", systemImage: "arrow.down.doc").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(holdsSource || !model.canTransfer)
                        .accessibilityIdentifier("copy-here")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.bar)
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn’t open folder", systemImage: "folder.badge.questionmark")
                } description: { Text(error) }
                actions: { Button("Try Again") { attempt += 1 }.buttonStyle(.bordered) }
            } else { LoadingPlaceholder(label: "Connecting and opening folder…") }
        }
        .navigationTitle(RemotePath.displayName(RemotePath.name(of: path)))
        .navigationSubtitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await load() }
        .transferConflictDialog($conflict)
    }
    private func load() async {
        error = nil
        do {
            let snapshot = try await model.service.listDirectory(profile: profile, path: requestedPath)
            let prepared = await Task.detached(priority: .userInitiated) { () -> (FolderListing, [FolderRow]) in
                let value = FolderListing(snapshot)
                return (value, value.visible(query: "", showHidden: false, order: .name, options: .init()).filter { $0.entry.effectiveKind == .directory })
            }.value
            guard !Task.isCancelled else { return }
            listing = prepared.0; folders = prepared.1
            model.noteConnected(profile.id)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            // A key to trust or unlock is asked for from the library, where its sheet can be shown.
            self.error = model.isSecurityError(error)
                ? "Open “\(profile.name)” from the library first, to check its host key or unlock its key. \(error.localizedDescription)"
                : error.localizedDescription
        }
    }
    private func copyHere(_ listing: FolderListing) {
        let names = Set(listing.rows.map(\.entry.name))
        let taken = entries.map { $0.exportFilename ?? $0.name }.filter(names.contains)
        let directory = listing.path
        let send: (UploadConflictPolicy?) -> Void = { answer in
            model.enqueueCopies(entries, from: source, to: profile, directory: directory, taken: Set(taken), answer: answer)
            model.sheet = nil
        }
        if taken.isEmpty { send(nil) } else { conflict = .init(names: taken, total: entries.count, resolve: send, cancel: {}) }
    }
}
#endif
