#if os(iOS)
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import RemoteFilesCore
import Textual

/// Created only after Share Original is tapped. Cached toolbar/provider values must not
/// retain an idle reader's lease; an actual share owns it until the activity completes.
@MainActor final class OfflineShareItem: Identifiable {
    let id = UUID()
    private(set) var lease: OfflineFileLease?
    init(lease: OfflineFileLease) { self.lease = lease }

    func finish() { lease = nil }

    func makeActivity() -> (controller: UIActivityViewController, provider: NSItemProvider) {
        let provider = NSItemProvider()
        provider.suggestedName = lease?.url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { [self] completion in
            Task { @MainActor in
                guard let lease else { completion(nil, false, OfflineFileError.missing); return }
                // No open-in-place access: the service receives its own copy.
                Task.detached {
                    withExtendedLifetime(lease) { completion(lease.url, false, nil) }
                }
            }
            return nil
        }
        let controller = UIActivityViewController(activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: [provider]))
        controller.completionWithItemsHandler = { [self] _, _, _, _ in
            Task { @MainActor in lease = nil }
        }
        return (controller, provider)
    }
}

/// Present natively from a reader anchor. UIKit requires an explicit popover source
/// on iPad; using an unanchored activity controller as SwiftUI sheet content loses it.
private struct OfflineSharePresenter: UIViewRepresentable {
    let item: OfflineShareItem?
    let onDismiss: (UUID) -> Void
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ anchor: AnchorView, context: Context) {
        anchor.item = item
        anchor.onDismiss = onDismiss
        anchor.schedulePresentation()
    }

    final class AnchorView: UIView, UIPopoverPresentationControllerDelegate {
        var item: OfflineShareItem?
        var onDismiss: ((UUID) -> Void)?
        private var presentedID: UUID?
        private var completedID: UUID?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            schedulePresentation()
        }
        func schedulePresentation() {
            // SwiftUI updates must not synchronously mutate presentation state.
            DispatchQueue.main.async { [weak self] in self?.presentShare() }
        }
        private func presentShare() {
            guard let item, item.id != completedID, presentedID == nil,
                  var presenter = window?.rootViewController else { return }
            // Present from this window's current modal controller, including when
            // Offline Files is itself displayed in a sheet.
            while let presented = presenter.presentedViewController { presenter = presented }
            guard !presenter.isBeingDismissed, presenter.viewIfLoaded?.window != nil else { return }
            presentedID = item.id
            let controller = item.makeActivity().controller
            let completion = controller.completionWithItemsHandler
            let onDismiss = self.onDismiss
            controller.completionWithItemsHandler = { [weak self] activity, completed, values, error in
                completion?(activity, completed, values, error)
                if let self { self.finish(item.id) }
                else { onDismiss?(item.id) }
            }
            if let popover = controller.popoverPresentationController {
                popover.sourceView = self
                popover.sourceRect = bounds
                popover.delegate = self
            }
            presenter.present(controller, animated: true)
            controller.presentationController?.delegate = self
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let item else { return }
            item.finish()
            finish(item.id)
        }
        private func finish(_ id: UUID) {
            guard presentedID == id else { return }
            completedID = id
            presentedID = nil
            onDismiss?(id)
        }
    }
}

/// SwiftUI may cache copies of a covered view and its callbacks. They share this owner,
/// so releasing the reader clears the lease even when an old view value is retained.
@MainActor @Observable private final class OfflineReaderLeaseState {
    var value: OfflineFileLease?
}

struct OfflinePinActions: View {
    let model: AppModel
    let profile: ConnectionProfile
    let entry: RemoteEntry
    var includeHidden = false
    var body: some View {
        if entry.kind == .file {
            Button("Download", systemImage: "arrow.down.circle") { model.enqueueDownload(profile: profile, entry: entry) }
                .disabled(!model.isForeground || model.downloads == nil)
            let pin = model.offlinePin(profile: profile, path: entry.path)
            Button(pin == nil ? "Keep Offline" : "Update Offline Copy", systemImage: "pin") {
                model.pinOffline(profile: profile, entry: entry)
            }
            .disabled(model.pinningName != nil || model.offlineStore == nil || !model.isForeground)
            if let pin {
                Button("Remove Offline Copy", systemImage: "pin.slash", role: .destructive) {
                    Task { await model.removeOfflinePin(pin) }
                }
            }
        } else if entry.kind == .directory {
            OfflineFolderPinActions(model: model, profile: profile, path: entry.path, includeHidden: includeHidden)
        }
    }
}

struct OfflinePinProgress: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let name = model.pinningName {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(model.cancellingPin ? "Cancelling save…" : "Saving \(name) offline…")
                        .font(.footnote.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { model.cancelOfflinePin() } label: {
                        Text("Cancel").font(.footnote).frame(minHeight: 44).padding(.leading, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.cancellingPin)
                }
                ThinProgress(fraction: model.pinProgress.fraction)
                HStack(spacing: 4) {
                    Text(model.pinProgress.sizeLabel()).monospacedDigit()
                    if let folder = model.folderPinProgress {
                        Text("· \(folder.files) files · \(folder.folders) folders")
                        if folder.skippedLinks > 0 { Text("· \(folder.skippedLinks) links skipped") }
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .contentTransition(.numericText())
                if let file = model.folderPinProgress?.currentFile {
                    Text(file).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 12).padding(.bottom, 4)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("offline-save-progress")
        }
    }
}

struct OfflineFilesView: View {
    let model: AppModel
    @State private var path = NavigationPath()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack(path: $path) {
            library
                .navigationTitle("Offline Files")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .navigationDestination(for: OfflineFolderRoute.self) { route in
                    OfflineFolderView(model: model, route: route)
                }
                .navigationDestination(for: OfflineDocumentRoute.self) { route in
                    if let store = model.offlineStore {
                        OfflineReaderView(pin: route.pin, store: store, initialFragment: route.fragment,
                                          readingPositions: model.offlineReadingPositions(for: route.pin),
                                          openDocument: { path.append($0) })
                    }
                }
        }
        // The library's own navigation replaces the app's while this sheet covers it.
        .focusedSceneValue(\.navigationCommands, NavigationCommandActions(context: "offline", back: path.isEmpty ? nil : { path.removeLast() }))
        // Nothing published in this sheet reaches the scene's commands, so its keys are UIKit key
        // commands on the sheet; see PlainKeyCommands.offlineFilesShows.
        .onChange(of: path.count, initial: true) { _, count in PlainKeyCommands.shared.offlineBack = count == 0 ? nil : { path.removeLast() } }
        .onAppear { PlainKeyCommands.shared.offlineFilesShows = true }
        .onDisappear { PlainKeyCommands.shared.offlineFilesShows = false; PlainKeyCommands.shared.offlineBack = nil }
    }

    /// Names that appear more than once, whose rows also say where each copy came from.
    private var repeatedNames: Set<String> {
        let names = model.offlineFolders.map(\.name) + model.standaloneOfflinePins.map(\.filename)
        return Set(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys)
    }
    private func source(_ connection: String, parent path: String) -> String {
        Set(model.offlinePins.map(\.connectionName) + model.offlineFolders.map(\.connectionName)).count > 1 ? "\(connection) · \(path)" : path
    }
    private var storedBytes: Int64 { Int64(model.offlinePins.reduce(0) { $0 + $1.byteCount }) }
    private static let storageLimit: Int64 = 512 * 1024 * 1024
    private var library: some View {
        let repeated = repeatedNames
        return List {
            if let error = model.offlineError {
                ContentUnavailableView("Offline library unavailable", systemImage: "exclamationmark.folder", description: Text(error))
                    .listRowSeparator(.hidden)
            } else if model.offlinePins.isEmpty && model.offlineFolders.isEmpty {
                ContentUnavailableView("No offline files", systemImage: "pin", description: Text("Choose Keep Offline in a file’s actions menu, or Keep Folder Offline in Folder actions."))
                    .accessibilityIdentifier("offline-empty")
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(model.offlineFolders) { folder in
                    NavigationLink(value: OfflineFolderRoute(folderID: folder.id, path: folder.path)) {
                        LocationRow(name: folder.name,
                                    subtitle: "\(folder.connectionName) · \(folder.path). \(folder.fileIDs.count) files, saved \(folder.savedAt.formatted(date: .abbreviated, time: .shortened))",
                                    symbol: "folder.fill", color: RemoteFilesStyle.accent,
                                    visibleSubtitle: repeated.contains(folder.name) ? source(folder.connectionName, parent: folder.path)
                                        : "\(folder.fileIDs.count) files · saved \(QuietDate.saved(folder.savedAt))")
                    }
                    .accessibilityIdentifier("offline-folder-" + folder.name)
                    .contextMenu { OfflineFolderLibraryActions(model: model, folder: folder) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash", role: .destructive) { Task { await model.removeOfflineFolder(folder) } }
                        Button("Update", systemImage: "arrow.clockwise") { model.refreshOfflineFolder(folder) }
                            .disabled(model.pinningName != nil || !model.isForeground)
                    }
                }
                ForEach(model.standaloneOfflinePins) { pin in
                    let size = ByteCountFormatter.string(fromByteCount: Int64(pin.byteCount), countStyle: .file)
                    NavigationLink(value: OfflineDocumentRoute(pin: pin)) {
                        LocationRow(name: pin.filename,
                                    subtitle: "\(pin.connectionName) · \(pin.path). Saved \(pin.savedAt.formatted(date: .abbreviated, time: .shortened)), \(size)",
                                    symbol: FileSymbol.name(forFilename: pin.documentFilename),
                                    visibleSubtitle: repeated.contains(pin.filename) ? source(pin.connectionName, parent: RemotePath.parent(of: pin.path))
                                        : "\(size) · saved \(QuietDate.saved(pin.savedAt))")
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .accessibilityIdentifier("offline-file-" + pin.filename)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash", role: .destructive) { Task { await model.removeOfflinePin(pin) } }
                        Button("Update", systemImage: "arrow.clockwise") { model.refreshOfflinePin(pin) }
                            .disabled(model.pinningName != nil || !model.isForeground)
                    }
                    .contextMenu {
                        Button("Update Offline Copy", systemImage: "arrow.clockwise") { model.refreshOfflinePin(pin) }
                            .disabled(model.pinningName != nil || !model.isForeground)
                        Button("Remove Offline Copy", systemImage: "trash", role: .destructive) { Task { await model.removeOfflinePin(pin) } }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.offlinePins.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ThinProgress(fraction: Double(storedBytes) / Double(Self.storageLimit))
                            Text("\(model.offlinePins.count) of 100 files · \(ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file)) of 512 MiB")
                                .monospacedDigit()
                        }
                    }
                    if model.demo { Text("Demo copies are separate from your files.") }
                    Text("Copies update only when you choose Update, which needs a connection. Up to 128 MiB per file. Removing a copy never touches the server. Document links open copies saved here; Markdown images aren’t loaded.")
                }
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 8)
            }
        }
        .listStyle(.plain)
    }
}

struct OfflineDocumentRoute: Hashable {
    let pin: OfflinePin
    var fragment: String? = nil
}

/// This view has no transport, resource resolver or connection. Every preview starts from a
/// verified local lease, and the ordinary renderer's network/resource policies still apply.
struct OfflineReaderView: View {
    let pin: OfflinePin
    let store: OfflineFileStore
    let initialFragment: String?
    /// The connected reader's history, keyed by the copy's connection, path and content hash,
    /// so identical bytes share one position. Nil for Demo and removed connections.
    var readingPositions: ReadingPositionStore? = nil
    let openDocument: (OfflineDocumentRoute) -> Void
    /// Identifies this reader's commands in PlainKeyCommands while it is on screen.
    @State private var readerID = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @State private var leaseState = OfflineReaderLeaseState()
    @State private var share: OfflineShareItem?
    @State private var visible = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var preview: DocumentPreview?
    @State private var image: DisplayImage?
    @State private var pdf: PDFDocument?
    @State private var pdfRestoration: SavedReadingPosition.Anchor?
    @State private var pdfPage = 0
    @State private var viewer: OfflineImagePresentation?
    @AccessibilityFocusState private var imageFocused: Bool
    @Namespace private var photoTransition
    @State private var fullScreenPlayback = false
    @State private var headingsPresented = false
    @State private var playback = RemotePlaybackController()
    @State private var source = false
    @State private var failure: String?
    @State private var loading = true
    /// Set only when a load completes. A retained lease alone doesn't mean the preview is
    /// ready: an interrupted load can still hold one and release it when it finally ends.
    @State private var loaded = false
    @State private var requestID = UUID()
    @State private var navigation = ReaderNavigationState()
    @State private var readingPosition = DocumentReadingPosition()
    @State private var appliedInitialFragment = false
    @State private var linkError: String?
    @State private var linkTask: Task<Void, Never>?
    @State private var linkRequestID = UUID()
    private var lease: OfflineFileLease? {
        get { leaseState.value }
        nonmutating set { leaseState.value = newValue }
    }
    private var savedCopy: OfflinePin { lease?.pin ?? pin }
    private var kind: DocumentKind { DocumentPolicy.kind(filename: savedCopy.documentFilename) }
    private var canRead: Bool { visible && scenePhase == .active }
    private var showsSource: Bool { source || ![.markdown, .html, .svg].contains(kind) }
    private struct FindWork: Equatable {
        let query: String
        let revision: UUID
        let inSource: Bool
        let active: Bool
    }

    var body: some View {
        // One view, not a Group: a Group's lifecycle modifiers would run per branch, and leaving the
        // placeholder would count as disappearing and release the lease.
        VStack(spacing: 0) {
            Group {
                if let failure = failure ?? playback.failure {
                    ContentUnavailableView("Couldn’t open saved copy", systemImage: "exclamationmark.doc", description: Text(failure))
                } else if loading {
                    LoadingPlaceholder(label: "Opening saved copy…", shape: .document)
                } else if let image {
                    PhotoStage(image: image.image, accessibilityLabel: "Open image \(savedCopy.filename) full screen",
                               transition: photoTransition) {
                        if let lease { viewer = OfflineImagePresentation(lease: lease, preview: image) }
                    }
                    .accessibilityFocused($imageFocused)
                } else if let pdf {
                    PDFDocumentView(document: pdf, restoration: pdfRestoration, readingPosition: readingPosition,
                                    onPageChange: { pdfPage = $0 })
                        .accessibilityLabel("PDF \(savedCopy.filename), \(pdf.pageCount) \(pdf.pageCount == 1 ? "page" : "pages")")
                        .overlay(alignment: .bottomLeading) { PDFPageBadge(page: min(pdfPage, pdf.pageCount - 1) + 1, count: pdf.pageCount) }
                }
                else if let player = playback.player {
                    if kind == .video {
                        VideoStage(playback: playback, player: player, isFullScreen: fullScreenPlayback,
                                   openFullScreen: { fullScreenPlayback = true })
                    } else {
                        VStack {
                            Image(systemName: "waveform").font(.system(size: 64)).padding(32).accessibilityHidden(true)
                            PlaybackControls(playback: playback)
                        }
                    }
                } else if kind == .certificate, let lease {
                    OfflineCertificateView(url: lease.url, filename: savedCopy.filename)
                } else if kind == .protectedCertificate, lease != nil {
                    ProtectedCertificateView(filename: savedCopy.filename, saveAction: "Share Original")
                } else if let preview {
                    switch preview {
                    case .text(let text, let markdown, let hiddenKeys):
                        if hiddenKeys > 0 { HiddenPrivateKeyNotice(count: hiddenKeys, saveAction: "Share Original") }
                        DocumentContentView(text: text, markdown: markdown, source: source, filename: savedCopy.documentFilename,
                                            readingPosition: readingPosition, openDocumentLink: openLink, navigation: navigation)
                            .textual.structuredTextStyle(.reader)
                    case .privateKey: PrivateKeyFileView(filename: savedCopy.filename, saveAction: "Share Original")
                    case .empty: ContentUnavailableView("This file is empty", systemImage: "doc")
                    case .tooLarge: unavailable("The file exceeds the 2 MiB text preview limit. You can share its original bytes.")
                    case .unsupportedEncodingOrBinary: unavailable("This file contains binary data or text that is not UTF-8. You can share the original.")
                    case .unsupportedFileType: unavailable("This file type has no preview. You can share its original bytes.")
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            if navigation.isFinding { ReaderFindBar(navigation: navigation, inSource: showsSource) }
        }
        .navigationTitle(savedCopy.filename).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(savedCopy.filename).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text("Saved \(QuietDate.saved(savedCopy.savedAt))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel("Offline copy, saved \(savedCopy.savedAt.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityIdentifier("offline-copy-date")
                }
            }
            if lease != nil || share != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Share Original", systemImage: "square.and.arrow.up") {
                        if let lease { share = OfflineShareItem(lease: lease) }
                    }
                    .disabled(lease == nil)
                    .accessibilityHint("Shares the saved file’s original bytes")
                }
            }
            if case .text = preview {
                // VoiceOver reaches the bottom bar after the whole document; these are a shortcut.
                if voiceOverEnabled {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(findTitle, systemImage: "magnifyingglass") { startFind() }
                            if navigation.index?.headings.isEmpty == false {
                                Button("Headings", systemImage: "list.bullet.indent") { headingsPresented = true }
                            }
                        } label: { Label("Document actions", systemImage: "ellipsis") }
                    }
                }
                ReaderBottomBar(findTitle: findTitle, find: startFind,
                                headings: navigation.index?.headings.isEmpty == false ? { headingsPresented = true } : nil,
                                source: [.markdown, .html, .svg].contains(kind) ? $source : nil)
            }
        }
        .background(alignment: .topTrailing) {
            // Native toolbar buttons can omit custom background views. Keep this
            // source in the reader hierarchy so it has a window when sharing starts.
            OfflineSharePresenter(item: share) { id in
                if share?.id == id { share = nil }
            }
            .frame(width: 1, height: 1)
        }
        .task(id: canRead) {
            if canRead, !loaded { await load() }
        }
        .task(id: FindWork(query: navigation.query, revision: navigation.revision, inSource: showsSource, active: navigation.isFinding)) {
            await navigation.search(inSource: showsSource)
        }
        .onAppear { visible = true }
        // A full-screen image or video covers this reader; it keeps what's loaded for its return.
        .onDisappear { visible = false; if viewer == nil, !fullScreenPlayback { saveAndRelease() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { saveAndRelease() } }
        .sheet(isPresented: $headingsPresented) {
            ReaderHeadingsView(headings: navigation.index?.headings ?? []) { heading in
                source = false; navigation.show(heading)
            }
            .coversKeyboardCommands()
        }
        .fullScreenCover(item: $viewer, onDismiss: { imageFocused = true }) { item in
            OfflineImageViewer(item: item).coversKeyboardCommands()
                .navigationTransition(.zoom(sourceID: PhotoStage.transitionID, in: photoTransition))
        }
        .background {
            NativeVideoPlayerPresentation(player: playback.player, isPresented: $fullScreenPlayback)
                .frame(width: 0, height: 0)
        }
        .alert("Couldn’t open link", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK") { linkError = nil }
        } message: { Text(linkError ?? "") }
        // Nothing published in this sheet reaches the scene's commands, so the reader's commands are
        // handed over directly, and withheld while its Headings sheet or image viewer covers it.
        .onChange(of: canRead && !headingsPresented && viewer == nil && !fullScreenPlayback ? commands : nil, initial: true) { _, commands in
            PlainKeyCommands.shared.setOfflineReader(readerID, commands)
        }
        .onDisappear { PlainKeyCommands.shared.setOfflineReader(readerID, nil) }
    }
    private var findTitle: String { [.html, .svg].contains(kind) ? "Find in Source" : "Find in Document" }
    private func startFind() {
        // Static HTML/SVG keep their native preview; search their literal source.
        if [.html, .svg].contains(kind) { source = true }
        navigation.startFind()
    }
    /// A saved copy has no Refresh: updating it needs a connection and is chosen in Offline Files.
    private var commands: ReaderCommandActions {
        var actions = ReaderCommandActions(context: "offline|\(pin.id)", showsSource: source)
        guard case .text = preview else { return actions }
        actions.find = startFind
        if navigation.isFinding, !navigation.matches.isEmpty {
            actions.findNext = { navigation.move(1, inSource: showsSource) }
            actions.findPrevious = { navigation.move(-1, inSource: showsSource) }
        }
        if navigation.isFinding { actions.closeFind = { navigation.closeFind() } }
        if navigation.index?.headings.isEmpty == false { actions.headings = { headingsPresented = true } }
        if [.markdown, .html, .svg].contains(kind) { actions.toggleSource = { source.toggle() } }
        return actions
    }
    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView("Preview not available", systemImage: "doc", description: Text(message))
    }
    /// Records where the reader is before its content goes, then writes it.
    private func saveAndRelease() {
        readingPosition.capturePDFPosition?()
        let position = readingPosition
        Task { await position.flush() }
        release()
    }
    private func release() {
        cancelLink()
        navigation.clear()
        readingPosition.overflowGeometry.releaseInactiveContent()
        requestID = UUID(); loaded = false; playback.stop(); image = nil; pdf = nil; lease = nil; preview = nil
    }
    private func cancelLink() {
        linkRequestID = UUID(); linkTask?.cancel(); linkTask = nil
    }
    private func openLink(_ url: URL) {
        cancelLink()
        guard canRead, let sourcePin = lease?.pin,
              var components = URLComponents(string: url.absoluteString),
              components.scheme == nil, components.host == nil else { return }
        guard components.query == nil else { linkError = RemoteDocumentLinkError.queryUnsupported.localizedDescription; return }
        let fragment = components.fragment
        if components.percentEncodedPath.isEmpty, let fragment { revealHeading(fragment); return }
        components.fragment = nil
        guard let reference = components.string else { return }
        let token = UUID(); linkRequestID = token; linkError = nil
        linkTask = Task {
            defer { if linkRequestID == token { linkTask = nil } }
            do {
                let target = try await store.resolveDocumentLink(from: sourcePin, reference: reference)
                try Task.checkCancellation()
                guard linkRequestID == token, canRead else { return }
                if fragment != nil, DocumentPolicy.kind(filename: target.documentFilename) != .markdown {
                    linkError = "Heading links require a Markdown document. Open the file using a link without the # heading fragment."
                } else if target.id == sourcePin.id, let fragment { revealHeading(fragment) }
                else { openDocument(.init(pin: target, fragment: fragment)) }
            } catch {
                guard !Task.isCancelled, linkRequestID == token, canRead else { return }
                linkError = error.localizedDescription
            }
        }
    }
    private func revealHeading(_ fragment: String) {
        guard let heading = navigation.index?.heading(fragment: fragment) else {
            linkError = "The heading “\(fragment)” could not be found in this saved document."
            return
        }
        source = false; navigation.show(heading)
    }
    private func load() async {
        let token = UUID(); requestID = token; loading = true; failure = nil
        defer { if requestID == token { loading = false } }
        do {
            let local = try await store.lease(pin.id)
            try Task.checkCancellation()
            guard requestID == token else { return }
            // Retain it before PDFKit/AVFoundation start lazy reads.
            lease = local
            switch kind {
            case .image:
                let decoded = try await RemoteImageDecoder.shared.decode(local.url, maxPixel: 1600)
                try Task.checkCancellation()
                guard requestID == token else { return }
                image = decoded
            case .pdf:
                // Hash the leased bytes before PDFKit opens them: a changed copy starts at the top.
                let restorable = await readingPosition.preparePDF(fileURL: local.url, store: readingPositions,
                                                                  connectionID: local.pin.connectionID, path: local.pin.path)
                try Task.checkCancellation()
                guard requestID == token else { return }
                guard let document = PDFDocument(url: local.url), document.pageCount > 0 else { throw OfflineFileError.damaged }
                let restoration = RemoteMediaView.pdfRestoration(openingPage: nil, saved: restorable ? readingPosition.pdfAnchor : nil,
                                                                 pageCount: document.pageCount)
                pdfRestoration = restoration; pdfPage = restoration?.ordinal ?? 0
                pdf = document
            case .video, .audio:
                try await playback.prepare(local.url, filename: local.pin.documentFilename)
                try Task.checkCancellation()
                guard requestID == token else { playback.stop(); return }
            case .certificate, .protectedCertificate:
                // The view reads the leased file itself. Its text never reaches `preview`.
                break
            default:
                let value = try await store.textPreview(local)
                try Task.checkCancellation()
                guard requestID == token else { return }
                if case .text(let text, let markdown, _) = value {
                    await readingPosition.prepare(text: text, store: readingPositions, connectionID: local.pin.connectionID, path: local.pin.path)
                    await navigation.prepare(text: text, markdown: markdown)
                    try Task.checkCancellation()
                    guard requestID == token else { return }
                }
                preview = value
                if !appliedInitialFragment, let initialFragment {
                    appliedInitialFragment = true
                    revealHeading(initialFragment)
                }
            }
            loaded = true
        } catch is CancellationError {
            if requestID == token { release() }
        }
        catch {
            if requestID == token, !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}

struct OfflineImagePresentation: Identifiable {
    let id = UUID()
    /// The reader's own verified lease: the viewer reads the same private copy and takes no new one.
    let lease: OfflineFileLease
    /// The reader's smaller copy, shown at once while the full-size decode runs.
    var preview: DisplayImage? = nil
}

/// Zoom and Share for a saved image, decoded from the reader's lease without any resolver.
/// Backgrounding closes it, so the lease is released with the reader's.
struct OfflineImageViewer: View {
    let item: OfflineImagePresentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: DisplayImage?
    @State private var failure: String?
    private var shown: DisplayImage? { image ?? (failure == nil ? item.preview : nil) }
    var body: some View {
        ImageViewerChrome(title: item.lease.pin.filename, image: shown.map { UIImage(cgImage: $0.image) },
                          shareable: image.map { UIImage(cgImage: $0.image) },
                          description: item.lease.pin.filename) {
            if let failure {
                ContentUnavailableView(item.lease.pin.filename, systemImage: "photo", description: Text(failure))
            } else { ProgressView("Loading image…") }
        }
        .task {
            do {
                let result = try await RemoteImageDecoder.shared.decode(item.lease.url, maxPixel: 3072)
                try Task.checkCancellation(); image = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { image = nil; dismiss() } }
    }
}
#endif
