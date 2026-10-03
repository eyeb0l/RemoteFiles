#if os(iOS)
import SwiftUI
import RemoteFilesCore
import UIKit

struct ReaderView: View {
    @Bindable var model: AppModel
    let profile: ConnectionProfile
    let entry: RemoteEntry
    @State private var preview: DocumentPreview?
    @State private var source = false
    @State private var imageVersion = 0
    @State private var lastImageRefresh = 0
    @State private var loading = false
    @State private var error: String?
    @State private var refreshID = 0
    @State private var requestID = UUID()
    @State private var copied = false
    @State private var loadedAt: Date?
    var body: some View {
        VStack(spacing: 0) {
            if DocumentPolicy.kind(filename: entry.name) == .markdown {
                Picker("Reading mode", selection: $source) {
                    Text("Rendered").tag(false)
                    Text("Source").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            }
            if !isMedia {
                if let error { StatusBanner(message: preview == nil ? error : "Previously loaded copy · \(error)", error: true) }
                else if loading && preview != nil { StatusBanner(message: "Previously loaded copy · refreshing…") }
            }
            Group {
                if isMedia {
                    RemoteMediaView(model: model, profile: profile, entry: entry,
                                    kind: DocumentPolicy.kind(filename: entry.name), refreshID: refreshID)
                } else if let preview {
                    switch preview {
                    case .text(let text, let markdown): DocumentContentView(text: text, markdown: markdown, source: source, filename: entry.name, location: .init(profile: profile, path: entry.path), resolver: model.resources).id(imageVersion)
                    case .empty: ContentUnavailableView("This file is empty", systemImage: "doc", description: Text("Refresh after it has been updated on your Mac."))
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
                    if case .text(let text, _) = preview {
                        Button(copied ? "Source Copied" : "Copy Source", systemImage: "doc.on.doc") { UIPasteboard.general.string = text; copied = true }
                    }
                    if let loadedAt { Text("Loaded \(loadedAt.formatted(date: .omitted, time: .shortened))") }
                    Text(profile.name)
                } label: { Label("Document actions", systemImage: "ellipsis.circle") }
            }
        }
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)") { await reload() }
    }
    private var isMedia: Bool {
        let kind = DocumentPolicy.kind(filename: entry.name)
        return kind == .image || kind == .pdf
    }
    private func infoView(_ title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc", description: Text("\(detail)\n\n\(entry.name)\n\(entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "Size unavailable")"))
    }
    private func reload() async {
        guard !isMedia else { return }
        guard model.isForeground else { loading = false; error = "Connection paused while the app is in the background."; return }
        guard DocumentPolicy.kind(filename: entry.name) != .unsupported else { preview = .unsupportedFileType; return }
        let token = UUID(); requestID = token
        if preview == nil, let bytes = model.cachedDocument(profile.id, path: entry.path) {
            preview = DocumentPolicy.decode(bytes, filename: entry.name)
        }
        loading = true; error = nil
        do {
            let bytes = try await model.service.readFile(profile: profile, path: entry.path, limit: DocumentPolicy.previewByteLimit)
            let decoded = await Task.detached(priority: .userInitiated) { DocumentPolicy.decode(bytes, filename: entry.name) }.value
            let refreshImages = refreshID != lastImageRefresh
            let published = try await ReaderReloadPublication.perform(
                clearImages: refreshImages,
                isCurrent: { token == requestID },
                clearResources: { await model.resources.clearCache() },
                clearDecoded: { await RemoteImageDecoder.shared.clear() },
                publish: {
                    if refreshImages { lastImageRefresh = refreshID; imageVersion += 1 }
                    preview = decoded; loadedAt = .now; copied = false
                    model.cache(bytes, id: profile.id, path: entry.path)
                    model.connectionStates[profile.id] = "Connected"
                    await model.recordRecent(profile: profile, entry: entry)
                })
            guard published else { return }
        } catch {
            guard token == requestID else { return }
            if !Task.isCancelled && !(error is CancellationError) {
                self.error = error.localizedDescription
                if model.isSecurityError(error) { preview = nil }
                model.handle(error, profile: profile)
            }
        }
        if token == requestID { loading = false }
    }
}
#endif
