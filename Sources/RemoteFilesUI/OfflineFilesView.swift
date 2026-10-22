#if os(iOS)
import SwiftUI
import PDFKit
import CoreTransferable
import UniformTypeIdentifiers
import RemoteFilesCore

/// The item provider retains the lease while handing the file to the share service, even if
/// navigation releases the reader. The receiving service gets a copy, not an in-place file.
struct OfflineShareItem: Transferable {
    let lease: OfflineFileLease
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(item.lease.url, allowAccessingOriginalFile: false)
        }.suggestedFileName { $0.lease.url.lastPathComponent }
    }
}

struct OfflinePinActions: View {
    let model: AppModel
    let profile: ConnectionProfile
    let entry: RemoteEntry
    var body: some View {
        if entry.kind == .file {
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
        }
    }
}

struct OfflinePinProgress: View {
    let model: AppModel
    var body: some View {
        if let name = model.pinningName {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.cancellingPin ? "Cancelling save…" : "Saving \(name) offline…")
                        .font(.callout).lineLimit(2)
                    Spacer()
                    Button("Cancel") { model.cancelOfflinePin() }.disabled(model.cancellingPin)
                }
                if let fraction = model.pinProgress.fraction { ProgressView(value: fraction) }
                else { ProgressView().frame(maxWidth: .infinity) }
                Text(model.pinProgress.sizeLabel()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding().background(.bar)
            .accessibilityIdentifier("offline-save-progress")
        }
    }
}

struct OfflineFilesView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                Text("Saved copies on this device. Updates happen only when you choose Update; they need a connection.")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.demo { Label("Demo copies are separate from your files.", systemImage: "sparkles").font(.footnote) }
                Text("\(model.offlinePins.count) of 100 files · \(ByteCountFormatter.string(fromByteCount: Int64(model.offlinePins.reduce(0) { $0 + $1.byteCount }), countStyle: .file)) of 512 MiB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.offlineError {
                ContentUnavailableView("Offline library unavailable", systemImage: "exclamationmark.folder", description: Text(error))
            } else if model.offlinePins.isEmpty {
                ContentUnavailableView("No offline files", systemImage: "pin", description: Text("Choose Keep Offline in a file’s actions menu or its folder context menu."))
                    .accessibilityIdentifier("offline-empty")
            }
            ForEach(model.offlinePins) { pin in
                NavigationLink {
                    if let store = model.offlineStore { OfflineReaderView(pin: pin, store: store) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(pin.filename, systemImage: "doc.fill").foregroundStyle(.primary)
                        Text(pin.connectionName + " · " + pin.path).font(.caption).foregroundStyle(.secondary)
                        Text("Saved \(pin.savedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(pin.byteCount), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
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
            Section {
                Text("128 MiB per file. Removing a saved copy never deletes the remote file. Markdown images and links to other remote files aren’t saved with it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Offline Files")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

/// This view has no transport, resource resolver or connection. Every preview starts from a
/// verified local lease, and the ordinary renderer's network/resource policies still apply.
struct OfflineReaderView: View {
    let pin: OfflinePin
    let store: OfflineFileStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var lease: OfflineFileLease?
    @State private var preview: DocumentPreview?
    @State private var image: DisplayImage?
    @State private var pdf: PDFDocument?
    @State private var playback = RemotePlaybackController()
    @State private var source = false
    @State private var failure: String?
    @State private var loading = true
    @State private var requestID = UUID()
    private var savedCopy: OfflinePin { lease?.pin ?? pin }
    private var kind: DocumentKind { DocumentPolicy.kind(filename: savedCopy.documentFilename) }

    var body: some View {
        VStack(spacing: 0) {
            Text("Offline copy · saved \(savedCopy.savedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground))
                .accessibilityIdentifier("offline-copy-date")
            Group {
                if let failure = failure ?? playback.failure {
                    ContentUnavailableView("Couldn’t open saved copy", systemImage: "exclamationmark.doc", description: Text(failure))
                } else if loading {
                    ProgressView("Opening saved copy…")
                } else if let image {
                    Image(decorative: image.image, scale: 1).resizable().scaledToFit().padding()
                        .accessibilityHidden(false)
                        .accessibilityLabel(savedCopy.filename)
                } else if let pdf { PDFDocumentView(document: pdf) }
                else if let player = playback.player {
                    VStack {
                        if kind == .video { NativePlaybackView(player: player).aspectRatio(16 / 9, contentMode: .fit) }
                        else { Image(systemName: "waveform").font(.system(size: 64)).padding(32).accessibilityHidden(true) }
                        PlaybackControls(playback: playback)
                    }
                } else if let preview {
                    switch preview {
                    case .text(let text, let markdown):
                        DocumentContentView(text: text, markdown: markdown, source: source, filename: savedCopy.documentFilename)
                    case .empty: ContentUnavailableView("This file is empty", systemImage: "doc")
                    case .tooLarge: unavailable("The file exceeds the 2 MiB text preview limit. You can share its original bytes.")
                    case .unsupportedEncodingOrBinary: unavailable("This file contains binary data or text that is not UTF-8. You can share the original.")
                    case .unsupportedFileType: unavailable("This file type has no preview. You can share its original bytes.")
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(savedCopy.filename).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let lease { ToolbarItem(placement: .primaryAction) { ShareLink(item: OfflineShareItem(lease: lease), preview: SharePreview(savedCopy.filename)) { Label("Share Original", systemImage: "square.and.arrow.up") } } }
            if case .text = preview, [.markdown, .html, .svg].contains(kind) {
                ToolbarItem(placement: .primaryAction) { Toggle("Source", isOn: $source) }
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await load() }
        }
        .onDisappear { release() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { release() } }
    }
    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView("Preview not available", systemImage: "doc", description: Text(message))
    }
    private func release() {
        requestID = UUID(); playback.stop(); image = nil; pdf = nil; lease = nil; preview = nil
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
                guard let document = PDFDocument(url: local.url), document.pageCount > 0 else { throw OfflineFileError.damaged }
                pdf = document
            case .video, .audio:
                try await playback.prepare(local.url, filename: local.pin.documentFilename)
                try Task.checkCancellation()
                guard requestID == token else { playback.stop(); return }
            default:
                let value = try await store.textPreview(local)
                try Task.checkCancellation()
                guard requestID == token else { return }
                preview = value
            }
        } catch is CancellationError { }
        catch { if requestID == token, !Task.isCancelled { failure = error.localizedDescription } }
    }
}
#endif
