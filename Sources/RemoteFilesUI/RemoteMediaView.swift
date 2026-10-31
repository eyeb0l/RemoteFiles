#if os(iOS)
import SwiftUI
import PDFKit
import AVKit
import RemoteFilesCore

/// Standalone files use the same bounded, cancellable SFTP resource pipeline as Markdown images.
struct RemoteMediaView: View {
    @Bindable var model: AppModel
    let profile: ConnectionProfile
    let entry: RemoteEntry
    let kind: DocumentKind
    let refreshID: Int
    /// Owned by the reader route, so a PDF's position survives refresh and suspension.
    var readingPosition: DocumentReadingPosition? = nil
    @State private var image: DisplayImage?
    @State private var pdf: PDFDocument?
    /// Where a newly loaded PDF opens: a search result's page once, then the saved position.
    @State private var pdfRestoration: SavedReadingPosition.Anchor?
    @State private var pdfPage = 0
    @State private var appliedOpeningPage = false
    @State private var loading = false
    @State private var downloadProgress = DownloadProgress()
    @State private var failure: String?
    @State private var lastRefreshID = 0
    @State private var retryID = 0
    @State private var lastRetryID = 0
    @State private var viewer: ImagePresentation?
    @State private var playback = RemotePlaybackController()
    @State private var fullScreenPlayback = false
    @State private var lastLoadedSession = -1
    @State private var requestID = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState(for: .voiceOver) private var imageFocused: Bool

    private var location: RemoteDocumentLocation { .init(profile: profile, path: entry.path, canonicalRoot: entry.canonicalRoot) }
    private var hasContent: Bool { image != nil || pdf != nil || playback.player != nil }
    private var previewFailure: String? { failure ?? playback.failure }
    private var symbol: String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .video: return "film"
        case .audio: return "waveform"
        default: return "photo"
        }
    }
    private var loadingMessage: String {
        if downloadProgress.isComplete { return "Preparing preview…" }
        switch kind {
        case .pdf: return "Loading PDF…"
        case .video: return "Downloading video…"
        case .audio: return "Downloading audio…"
        default: return "Loading image…"
        }
    }
    private var reference: String {
        var components = URLComponents()
        components.path = entry.name
        return components.percentEncodedPath
    }

    var body: some View {
        VStack(spacing: 0) {
            if let failure = previewFailure {
                StatusBanner(message: hasContent ? "Previously loaded copy · \(failure)" : failure, error: true)
            } else if loading && hasContent {
                VStack(spacing: 8) {
                    StatusBanner(message: "Previously loaded copy · refreshing…")
                    downloadStatus.padding(.horizontal).padding(.bottom, 8)
                }
            }
            Group {
                if kind == .image, let image {
                    ScrollView {
                        Button { viewer = .init(reference: reference, filename: entry.name, location: location) } label: {
                            Image(uiImage: UIImage(cgImage: image.image))
                                .resizable().scaledToFit().frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open image \(entry.name) full screen")
                        .accessibilityFocused($imageFocused)
                    }
                } else if kind == .pdf, let pdf {
                    VStack(spacing: 0) {
                        Text("Page \(min(pdfPage, pdf.pageCount - 1) + 1) of \(pdf.pageCount)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                            .accessibilityIdentifier("PDF page indicator")
                        PDFDocumentView(document: pdf, restoration: pdfRestoration, readingPosition: readingPosition,
                                        onPageChange: { pdfPage = $0 })
                            .accessibilityLabel("PDF \(entry.name), \(pdf.pageCount) \(pdf.pageCount == 1 ? "page" : "pages")")
                    }
                } else if let player = playback.player {
                    VStack(spacing: 0) {
                        if kind == .audio {
                            VStack(spacing: 16) {
                                Image(systemName: "waveform").font(.system(size: 64)).foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(entry.name).font(.headline).multilineTextAlignment(.center)
                            }.padding().frame(maxHeight: .infinity)
                        }
                        if kind == .audio {
                            PlaybackControls(playback: playback).id(ObjectIdentifier(player))
                        } else {
                            NativePlaybackView(player: player).id(fullScreenPlayback)
                            PlaybackControls(playback: playback, openFullScreen: { fullScreenPlayback = true })
                                .id(ObjectIdentifier(player))
                        }
                    }
                } else if loading {
                    VStack(spacing: 12) {
                        Text(loadingMessage).font(.headline)
                        downloadStatus.frame(maxWidth: 320)
                        if kind == .video || kind == .audio {
                            Text("You can play this file once the download finishes.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }.padding()
                } else {
                    ContentUnavailableView {
                        Label(entry.name, systemImage: symbol)
                    } description: {
                        Text(previewFailure ?? "The preview is unavailable.")
                    } actions: {
                        Button("Tap to retry") { retryID += 1 }.buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)-\(retryID)") { await load() }
        .onDisappear { if !fullScreenPlayback { requestID = UUID(); playback.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.stop() } }
        .onChange(of: model.isForeground) { _, active in if !active { playback.stop() } }
        .onChange(of: model.isDisconnecting) { _, disconnecting in if disconnecting { playback.stop() } }
        .fullScreenCover(item: $viewer, onDismiss: { imageFocused = true }) { item in RemoteImageViewer(item: item, resolver: model.resources) }
        .background {
            NativeVideoPlayerPresentation(player: playback.player, isPresented: $fullScreenPlayback)
                .frame(width: 0, height: 0)
        }
    }

    private var downloadStatus: some View {
        VStack(spacing: 8) {
            if let fraction = downloadProgress.fraction {
                ProgressView(value: fraction).accessibilityLabel("Download progress")
            } else {
                ProgressView().accessibilityLabel(loadingMessage)
            }
            Text(downloadProgress.sizeLabel())
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("Download size")
        }
    }

    private func load() async {
        guard !model.isDisconnecting else { return }
        if model.isForeground, playback.player != nil, lastLoadedSession == model.sessionRevision,
           refreshID == lastRefreshID, retryID == lastRetryID { return }
        let token = UUID(); requestID = token
        let revision = model.sessionRevision
        guard model.isForeground else {
            image = nil; pdf = nil; playback.stop(); loading = false
            failure = "Connection paused while the app is in the background."
            return
        }
        if refreshID != lastRefreshID || retryID != lastRetryID {
            // PDFKit may read pages lazily from the cached file. Release it before replacing that file.
            pdf = nil
            playback.pause()
            await model.resources.invalidate(reference, in: location)
            lastRefreshID = refreshID
            lastRetryID = retryID
        }
        downloadProgress = DownloadProgress(totalBytes: entry.size)
        loading = true; failure = nil
        defer { if requestID == token { loading = false } }
        do {
            let file = try await model.resources.localFile(for: reference, in: location, progress: { update in
                await MainActor.run {
                    guard requestID == token, !model.isDisconnecting, model.isForeground,
                          model.sessionRevision == revision else { return }
                    downloadProgress = update
                }
            })
            try Task.checkCancellation()
            guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else { return }
            if kind == .image {
                let decoded = try await RemoteImageDecoder.shared.decode(file, maxPixel: 1600)
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else { return }
                image = decoded
            } else if kind == .video || kind == .audio {
                try await playback.prepare(file, filename: entry.name)
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else {
                    playback.stop(); return
                }
            } else {
                // Hash the bytes before PDFKit opens them: a changed document starts at the top.
                var restorable = false
                if let readingPosition {
                    restorable = await model.preparePDFReadingPosition(readingPosition, fileURL: file, profile: profile, path: entry.path)
                }
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else { return }
                guard let document = PDFDocument(url: file), document.pageCount > 0 else {
                    throw MediaPreviewError.invalidPDF
                }
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else { return }
                let restoration = Self.pdfRestoration(openingPage: appliedOpeningPage ? nil : entry.openingPage,
                                                      saved: restorable ? readingPosition?.pdfAnchor : nil,
                                                      pageCount: document.pageCount)
                appliedOpeningPage = true
                if restorable, restoration != nil { readingPosition?.pdfAnchor = restoration }
                pdfRestoration = restoration; pdfPage = restoration?.ordinal ?? 0
                pdf = document
            }
            model.connectionStates[profile.id] = "Connected"
            lastLoadedSession = revision
            await model.recordRecent(profile: profile, entry: entry)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else { return }
            failure = error.localizedDescription
            if model.isSecurityError(error) { image = nil; pdf = nil; playback.stop() }
            if error is PlaybackError { model.connectionStates[profile.id] = "Connected" }
            else { model.handle(error, profile: profile) }
        }
    }
}

struct PlaybackControls: View {
    let playback: RemotePlaybackController
    var openFullScreen: (() -> Void)? = nil
    @State private var scrubbing = false
    @State private var position: Double = 0
    var body: some View {
        VStack(spacing: 16) {
            Slider(value: Binding(get: { scrubbing ? position : min(playback.elapsed, playback.duration) },
                                  set: { position = $0; if !scrubbing { playback.seek(to: $0) } }), in: 0...max(playback.duration, 0.01)) { editing in
                if editing { position = min(playback.elapsed, playback.duration) }
                scrubbing = editing
                if !editing { playback.seek(to: position) }
            }
            .disabled(playback.duration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(time(scrubbing ? position : playback.elapsed)) of \(time(playback.duration))")
            HStack {
                Text(time(scrubbing ? position : playback.elapsed))
                Spacer()
                Text(time(playback.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.togglePlayback()
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if let openFullScreen {
                    Button(action: openFullScreen) {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.body.weight(.semibold)).foregroundStyle(.primary)
                            .padding(.horizontal, 16).frame(minHeight: 50)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }.padding(24).accessibilityIdentifier("Playback controls")
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds.isFinite ? seconds : 0, Double(Int.max / 2))))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                             : String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct NativePlaybackView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsVideoFrameAnalysis = false
        controller.allowsPictureInPicturePlayback = false
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}

extension RemoteMediaView {
    /// A search result's page wins once over saved history; either must exist in this revision.
    static func pdfRestoration(openingPage: Int?, saved: SavedReadingPosition.Anchor?, pageCount: Int) -> SavedReadingPosition.Anchor? {
        if let openingPage, (1...pageCount).contains(openingPage) { return .init(kind: "pdf-page", ordinal: openingPage - 1) }
        guard let saved, saved.kind == "pdf-page", saved.ordinal < pageCount else { return nil }
        return saved
    }
}

private enum MediaPreviewError: LocalizedError {
    case invalidPDF
    var errorDescription: String? { "This file is not a readable PDF, or its PDF data is damaged." }
}

struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    /// Applied once after the first layout of each document; nil opens at the top.
    var restoration: SavedReadingPosition.Anchor? = nil
    var readingPosition: DocumentReadingPosition? = nil
    /// Reports the zero-based page PDFKit considers current.
    var onPageChange: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RestoringPDFView {
        let view = RestoringPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.document = document
        view.pendingRestoration = restoration
        context.coordinator.attach(view, parent: self)
        return view
    }
    func updateUIView(_ view: RestoringPDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document {
            view.document = document
            view.restart(with: restoration)
        }
    }
    static func dismantleUIView(_ view: RestoringPDFView, coordinator: Coordinator) {
        coordinator.record()
        coordinator.detach()
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PDFDocumentView?
        private weak var view: RestoringPDFView?

        func attach(_ view: RestoringPDFView, parent: PDFDocumentView) {
            self.view = view; self.parent = parent
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            view.onRestored = { [weak self] in self?.pageChanged() }
            // The weak capture becomes a no-op once this view is gone; a newer view replaces it.
            parent.readingPosition?.capturePDFPosition = { [weak self] in self?.record() }
        }
        func detach() {
            if let view { NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: view) }
            view?.onRestored = nil
            view = nil
        }
        /// Saves where the reader is. Ignored until restoration so the initial layout at page 1
        /// never replaces a saved or requested position.
        func record() {
            guard let view, view.isRestored, !view.isAdjustingLayout, let anchor = view.readingAnchor() else { return }
            parent?.readingPosition?.pdfAnchor = anchor
        }
        @objc func pageChanged() {
            guard let view, view.isRestored else { return }
            if let page = view.currentPage, let document = view.document {
                let index = document.index(for: page)
                if index != NSNotFound { parent?.onPageChange?(index) }
            }
            record()
        }
    }
}

/// Waits for a real layout before scrolling, since PDFKit ignores destinations in a zero-sized view.
/// A later size change (rotation, iPad resizing) keeps the same reading position: PDFKit rescales
/// the pages but would otherwise leave the old offset in place.
final class RestoringPDFView: PDFView {
    var pendingRestoration: SavedReadingPosition.Anchor?
    var onRestored: (() -> Void)?
    private(set) var isRestored = false
    private var scheduled = false
    private var generation = 0
    /// Captured before a size change, under the old layout, and restored after the new one.
    private var resizeAnchor: SavedReadingPosition.Anchor?
    private var resizeScheduled = false
    /// True between a size change and its restoration; positions seen then are transitional.
    var isAdjustingLayout: Bool { resizeAnchor != nil }

    override var frame: CGRect { willSet { prepareForResize(to: newValue.size) } }
    override var bounds: CGRect { willSet { prepareForResize(to: newValue.size) } }

    private func prepareForResize(to size: CGSize) {
        guard isRestored, resizeAnchor == nil, bounds.width > 0, bounds.height > 0, size != bounds.size else { return }
        resizeAnchor = readingAnchor()
    }

    func restart(with restoration: SavedReadingPosition.Anchor?) {
        generation += 1
        pendingRestoration = restoration; isRestored = false; scheduled = false
        resizeAnchor = nil; resizeScheduled = false
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isRestored, resizeAnchor != nil, !resizeScheduled, bounds.width > 0, bounds.height > 0 {
            resizeScheduled = true
            let expected = generation
            // As with the first restoration, let autoScales apply the new width first.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                if let anchor = self.resizeAnchor { self.restore(anchor) }
                self.resizeAnchor = nil; self.resizeScheduled = false
                self.onRestored?()
            }
        }
        guard !isRestored, !scheduled, document != nil, bounds.width > 0, bounds.height > 0 else { return }
        scheduled = true
        let expected = generation
        // Let autoScales settle the page scale for this width before positioning.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected else { return }
            if let anchor = self.pendingRestoration { self.restore(anchor) }
            self.pendingRestoration = nil
            self.isRestored = true
            self.onRestored?()
        }
    }

    func restore(_ anchor: SavedReadingPosition.Anchor) {
        guard anchor.kind == "pdf-page", let document, anchor.ordinal < document.pageCount,
              let page = document.page(at: anchor.ordinal) else { return }
        guard anchor.fraction > 0 else { go(to: page); return }
        let box = page.bounds(for: displayBox)
        go(to: PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.maxY - CGFloat(anchor.fraction) * box.height)))
    }

    /// The page and vertical position at the top edge of the visible area.
    func readingAnchor() -> SavedReadingPosition.Anchor? {
        guard let document, bounds.height > 0 else { return nil }
        let probe = CGPoint(x: bounds.midX, y: bounds.minY + safeAreaInsets.top + 1)
        guard let page = page(for: probe, nearest: true) else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else { return nil }
        let box = page.bounds(for: displayBox)
        guard box.height > 0 else { return nil }
        let point = convert(probe, to: page)
        let fraction = Double(min(1, max(0, (box.maxY - point.y) / box.height)))
        return .init(kind: "pdf-page", ordinal: index, fraction: fraction.isFinite ? fraction : 0)
    }
}
#endif
