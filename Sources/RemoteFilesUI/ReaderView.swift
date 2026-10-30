#if os(iOS)
import SwiftUI
import RemoteFilesCore
import UIKit

struct ReaderView: View {
    @Environment(\.workspaceNavigation) private var workspaceNavigate
    @Bindable var model: AppModel
    let profile: ConnectionProfile
    let entry: RemoteEntry
    @State private var preview: DocumentPreview?
    @State private var source = false
    @AppStorage("readerWrapLines") private var wrapLines = true
    @State private var imageVersion = 0
    @State private var lastImageRefresh = 0
    @State private var loading = false
    @State private var error: String?
    @State private var refreshID = 0
    @State private var requestID = UUID()
    @State private var copied = false
    @State private var loadedAt: Date?
    /// The remote version of the displayed text, used to revalidate it without a transfer.
    @State private var displayedVersion: RemoteFileVersion?
    @State private var readingPosition = DocumentReadingPosition()
    @State private var lastSessionRevision = -1
    @State private var lastRefreshID = -1
    @State private var linkTask: Task<Void, Never>?
    @State private var linkRequestID = UUID()
    @State private var openingLink = false
    @State private var linkError: String?
    @State private var navigation = ReaderNavigationState()
    @State private var headingsPresented = false
    @State private var appliedInitialFragment = false
    @State private var contentRevision = UUID()
    private struct ContentIdentity: Hashable { let revision: UUID; let images: Int }
    private struct FindWork: Equatable {
        let query: String
        let revision: UUID
        let inSource: Bool
        let active: Bool
    }
    var body: some View {
        VStack(spacing: 0) {
            if [.markdown, .html, .svg].contains(DocumentPolicy.kind(filename: entry.name)) {
                Picker("Reading mode", selection: $source) {
                    Text("Rendered").tag(false)
                    Text("Source").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            }
            if navigation.isFinding { ReaderFindBar(navigation: navigation, inSource: showsSource) }
            if openingLink {
                HStack {
                    ProgressView()
                    Text("Opening linked file…").font(.callout)
                    Spacer()
                    Button("Cancel") { cancelLink() }
                }.padding(.horizontal).padding(.vertical, 8)
            }
            if !isMedia {
                if let error { StatusBanner(message: preview == nil ? error : "Previously loaded copy · \(error)", error: true) }
                else if loading && preview != nil { StatusBanner(message: "Previously loaded copy · refreshing…") }
            }
            Group {
                if isMedia {
                    RemoteMediaView(model: model, profile: profile, entry: entry,
                                    kind: DocumentPolicy.kind(filename: entry.name), refreshID: refreshID)
                } else if let preview, model.isForeground {
                    switch preview {
                    case .text(let text, let markdown): DocumentContentView(text: text, markdown: markdown, source: source, filename: entry.name, location: .init(profile: profile, path: entry.path, canonicalRoot: entry.canonicalRoot), resolver: model.resources, readingPosition: readingPosition, openDocumentLink: openLink, wrapLines: wrapLines, navigation: navigation).id(ContentIdentity(revision: contentRevision, images: imageVersion))
                    case .empty: ContentUnavailableView("This file is empty", systemImage: "doc", description: Text("Refresh after it has been updated on the server."))
                    case .unsupportedFileType: infoView("Preview not available", detail: "This file type is not supported for preview.")
                    case .unsupportedEncodingOrBinary: infoView("Can’t display this file", detail: "This file contains binary data or text that is not UTF-8.")
                    case .tooLarge: infoView("Too Large to Preview", detail: "The document exceeds the 2 MiB preview limit.")
                    }
                } else if loading {
                    ProgressView("Reading document…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Couldn’t read document", systemImage: "doc.badge.ellipsis")
                    } description: { Text("You can return to the folder or try again.") }
                    actions: { Button("Try Again") { refreshID += 1 }.buttonStyle(.bordered) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { refreshID += 1 }
                    OfflinePinActions(model: model, profile: profile, entry: entry)
                    if case .text(let text, _) = preview {
                        Button([.html, .svg].contains(DocumentPolicy.kind(filename: entry.name)) ? "Find in Source" : "Find in Document", systemImage: "magnifyingglass") {
                            // Static HTML/SVG keep their native preview; search their literal source.
                            if [.html, .svg].contains(DocumentPolicy.kind(filename: entry.name)) { source = true }
                            navigation.isFinding = true
                        }
                        if navigation.index?.headings.isEmpty == false {
                            Button("Headings", systemImage: "list.bullet.indent") { headingsPresented = true }
                        }
                        if showsSource {
                            if SourceLayout.needsBoundedLayout(text) {
                                Label("Long documents always wrap", systemImage: "arrow.turn.down.left")
                            } else {
                                Toggle("Wrap Lines", systemImage: "arrow.turn.down.left", isOn: $wrapLines)
                            }
                        }
                        Button(copied ? "Source Copied" : "Copy Source", systemImage: "doc.on.doc") { SourceClipboard.copy(text); copied = true }
                    }
                    if let loadedAt { Text("Loaded \(loadedAt.formatted(date: .omitted, time: .shortened))") }
                    Text(profile.name)
                    Button("Disconnect", systemImage: "network.slash") { Task { await model.disconnectAndGoHome() } }
                } label: { Label("Document actions", systemImage: "ellipsis.circle") }
            }
        }
        .modifier(OriginalFileExportControl(profile: profile, entry: entry, allowedRoot: profile.startingDirectory,
                                            exporter: model.originalExporter, isEnabled: model.isForeground && !model.isDisconnecting,
                                            onError: { error in
                                                model.handle(error, profile: profile)
                                                return model.sheet != nil || model.errorMessage != nil
                                            }))
        .alert("Couldn’t open link", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) { linkError = nil }
        } message: { Text(linkError ?? "") }
        .sheet(isPresented: $headingsPresented) {
            ReaderHeadingsView(headings: navigation.index?.headings ?? []) { heading in
                source = false; navigation.show(heading)
            }
        }
        .task(id: FindWork(query: navigation.query, revision: navigation.revision, inSource: showsSource, active: navigation.isFinding)) {
            await navigation.search(inSource: showsSource)
        }
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)") { await reloadIfNeeded() }
        .onDisappear {
            releaseInactiveContent()
            Task { await readingPosition.flush() }
        }
        .onChange(of: model.isForeground) { _, active in
            cancelLink()
            if !active { releaseInactiveContent(keepPreview: true); Task { await readingPosition.flush() } }
        }
        .onChange(of: model.sessionRevision) { _, _ in cancelLink() }
    }
    private func releaseInactiveContent(keepPreview: Bool = false) {
        cancelLink(); requestID = UUID()
        // Keep only the selected reader's bounded original text across suspension,
        // so a failed reconnect can still explain and display the previous copy.
        if !keepPreview { preview = nil; displayedVersion = nil }
        navigation.clear()
        readingPosition.overflowGeometry.releaseInactiveContent()
    }

    private var isMedia: Bool {
        let kind = DocumentPolicy.kind(filename: entry.name)
        return [.image, .pdf, .video, .audio].contains(kind)
    }
    private var showsSource: Bool {
        source || ![.markdown, .html, .svg].contains(DocumentPolicy.kind(filename: entry.name))
    }
    private func infoView(_ title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc", description: Text("\(detail)\n\n\(entry.name)\n\(entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "Size unavailable")"))
    }
    private func cancelLink() {
        linkRequestID = UUID()
        linkTask?.cancel(); linkTask = nil
        openingLink = false
    }
    private func openLink(_ url: URL) {
        cancelLink()
        guard var components = URLComponents(string: url.absoluteString), components.scheme == nil, components.host == nil else { return }
        guard components.query == nil else { linkError = RemoteDocumentLinkError.queryUnsupported.localizedDescription; return }
        let fragment = components.fragment
        if components.percentEncodedPath.isEmpty, let fragment {
            revealHeading(fragment)
            return
        }
        components.fragment = nil
        guard let reference = components.string else { return }
        guard model.isForeground else {
            linkError = "Connection paused while the app is in the background. Try the link again after returning."
            return
        }
        let token = UUID(); linkRequestID = token
        let revision = model.sessionRevision
        openingLink = true; linkError = nil
        linkTask = Task {
            defer {
                if linkRequestID == token { openingLink = false; linkTask = nil }
            }
            do {
                let target = try await model.service.resolveDocumentLink(profile: profile, documentPath: entry.path, reference: reference)
                try Task.checkCancellation()
                guard linkRequestID == token, model.isForeground, model.sessionRevision == revision else { return }
                if fragment != nil, DocumentPolicy.kind(filename: target.name) != .markdown {
                    linkError = "Heading links require a Markdown document. Open the file using a link without the # heading fragment."
                    return
                }
                if target.path.utf8.elementsEqual(entry.path.utf8), let fragment { revealHeading(fragment) }
                else {
                    let route = AppModel.Route.file(profile.id, fragment.map { target.openingHeading($0) } ?? target)
                    if let workspaceNavigate { workspaceNavigate(route) } else { model.routes.append(route) }
                }
            } catch {
                guard !Task.isCancelled, linkRequestID == token, model.isForeground, model.sessionRevision == revision else { return }
                linkError = error.localizedDescription
                if !(error is RemoteDocumentLinkError) { model.handle(error, profile: profile) }
            }
        }
    }
    private func revealHeading(_ fragment: String) {
        guard let heading = navigation.index?.heading(fragment: fragment) else {
            linkError = fragment.isEmpty ? "This document has no headings. Use Find in Document to locate text." : "The heading “\(fragment)” could not be found. Use Headings or Find in Document."
            return
        }
        source = false; navigation.show(heading)
    }
    private func applyInitialFragment() {
        guard !appliedInitialFragment, let fragment = entry.headingFragment else { return }
        appliedInitialFragment = true
        revealHeading(fragment)
    }
    private func prepareReading(_ decoded: DocumentPreview) async {
        guard case .text(let text, let markdown) = decoded else { return }
        await model.prepareReadingPosition(readingPosition, text: text, profile: profile, path: entry.path)
        await navigation.prepare(text: text, markdown: markdown)
    }
    private func reloadIfNeeded() async {
        guard !model.isForeground || preview == nil || lastSessionRevision != model.sessionRevision || lastRefreshID != refreshID else { return }
        await reload()
    }
    private func reload() async {
        guard !model.isDisconnecting else { return }
        guard !isMedia else { return }
        guard model.isForeground else { loading = false; error = "Connection paused while the app is in the background."; return }
        guard DocumentPolicy.kind(filename: entry.name) != .unsupported else { preview = .unsupportedFileType; return }
        // Opening, returning to the foreground and unlocking revalidate; an explicit Refresh always reads.
        let explicitRefresh = lastRefreshID >= 0 && lastRefreshID != refreshID
        let token = UUID(); requestID = token
        let revision = model.sessionRevision
        lastSessionRevision = model.sessionRevision; lastRefreshID = refreshID
        loading = true; error = nil
        if let preview, navigation.index == nil {
            await prepareReading(preview)
            guard !Task.isCancelled, token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            contentRevision = navigation.revision
        }
        var knownVersion = preview == nil ? nil : displayedVersion
        if entry.navigationRoot == nil, entry.canonicalRoot == nil, preview == nil, let bytes = model.cachedDocument(profile.id, path: entry.path) {
            let version = model.cachedDocumentVersion(profile.id, path: entry.path)
            let cached = await Task.detached(priority: .userInitiated) { DocumentPolicy.decode(bytes, filename: entry.name) }.value
            await prepareReading(cached)
            guard !Task.isCancelled, token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            preview = cached; contentRevision = navigation.revision; displayedVersion = version
            knownVersion = version
        }
        do {
            let read = try await model.service.readFileIfChanged(profile: profile, entry: entry,
                                                                 limit: DocumentPolicy.previewByteLimit,
                                                                 since: explicitRefresh ? nil : knownVersion)
            guard case .contents(let bytes, let version) = read else {
                try Task.checkCancellation()
                guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
                loadedAt = .now
                model.connectionStates[profile.id] = "Connected"
                await model.recordRecent(profile: profile, entry: entry)
                applyInitialFragment()
                if token == requestID { loading = false }
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) { DocumentPolicy.decode(bytes, filename: entry.name) }.value
            try Task.checkCancellation()
            guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            let oldParts = navigation.index?.parts ?? []
            await prepareReading(decoded)
            try Task.checkCancellation()
            guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            let refreshImages = refreshID != lastImageRefresh
            let references = (oldParts + (navigation.index?.parts ?? [])).compactMap { part -> String? in
                if case .image(let reference, _) = part.content { return reference }; return nil
            }
            var invalidatedFiles: [URL] = []
            let published = try await ReaderReloadPublication.perform(
                clearImages: refreshImages,
                isCurrent: { token == requestID && !model.isDisconnecting && model.sessionRevision == revision },
                clearResources: { invalidatedFiles = await model.resources.invalidateResources(references, in: .init(profile: profile, path: entry.path, canonicalRoot: entry.canonicalRoot)) },
                clearDecoded: { await RemoteImageDecoder.shared.invalidate(files: invalidatedFiles) },
                publish: {
                    if refreshImages { lastImageRefresh = refreshID; imageVersion += 1 }
                    if case .text = decoded {} else { navigation.clear() }
                    preview = decoded; contentRevision = navigation.revision; loadedAt = .now; copied = false
                    displayedVersion = version
                    model.cache(bytes, version: version, id: profile.id, path: entry.path)
                    model.connectionStates[profile.id] = "Connected"
                    await model.recordRecent(profile: profile, entry: entry)
                })
            guard published else { return }
            applyInitialFragment()
        } catch {
            guard token == requestID, !model.isDisconnecting, model.sessionRevision == revision else { return }
            if !Task.isCancelled && !(error is CancellationError) {
                self.error = error.localizedDescription
                if model.isSecurityError(error) { preview = nil; displayedVersion = nil; navigation.clear() }
                model.handle(error, profile: profile)
            }
        }
        if token == requestID { loading = false }
    }
}
#endif
