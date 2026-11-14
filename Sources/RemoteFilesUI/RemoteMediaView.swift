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
    @State private var loading = true
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
    @Namespace private var photoTransition

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
        // One view, not a Group: a Group's lifecycle modifiers would run per branch.
        VStack(spacing: 0) {
            Group {
                if kind == .image, let image {
                    PhotoStage(image: image.image, accessibilityLabel: "Open image \(entry.name) full screen",
                               transition: photoTransition) {
                        viewer = .init(reference: reference, filename: entry.name, location: location, preview: image)
                    }
                    .accessibilityFocused($imageFocused)
                } else if kind == .pdf, let pdf {
                    PDFDocumentView(document: pdf, restoration: pdfRestoration, readingPosition: readingPosition,
                                    onPageChange: { pdfPage = $0 })
                        .accessibilityLabel("PDF \(entry.name), \(pdf.pageCount) \(pdf.pageCount == 1 ? "page" : "pages")")
                        .overlay(alignment: .bottomLeading) { PDFPageBadge(page: min(pdfPage, pdf.pageCount - 1) + 1, count: pdf.pageCount) }
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
                            VideoStage(playback: playback, player: player, isFullScreen: fullScreenPlayback,
                                       openFullScreen: { fullScreenPlayback = true })
                        }
                    }
                } else if loading {
                    VStack(spacing: 16) {
                        Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        VStack(spacing: 4) {
                            Text(loadingMessage).font(.headline)
                            if kind == .video || kind == .audio, !downloadProgress.isComplete {
                                Text("You can play this file once the download finishes.")
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        }
                        downloadStatus.frame(maxWidth: 260)
                    }.padding(24)
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
        .animation(RemoteFilesStyle.contentFade, value: hasContent)
        .contentStatus(progress: hasContent && loading ? "Updating…" : nil,
                       failure: hasContent ? previewFailure.map { "Previously loaded copy · \($0)" } : nil,
                       retry: { retryID += 1 })
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)-\(retryID)") { await load() }
        .onDisappear { if !fullScreenPlayback { requestID = UUID(); playback.stop() } }
        // Inactive is Control Centre or a system prompt, with the connection still open: playback waits
        // where it is. Only the background ends it, when the model leaves the foreground below.
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.pause() } }
        .onChange(of: model.isForeground) { _, active in if !active { playback.stop() } }
        .onChange(of: model.mediaSecurityFailure(profile.id)) { _, message in
            guard let message else { return }
            requestID = UUID(); image = nil; pdf = nil; viewer = nil; playback.stop()
            failure = message; loading = false
        }
        .onChange(of: model.isDisconnecting) { _, disconnecting in if disconnecting { playback.stop() } }
        .fullScreenCover(item: $viewer, onDismiss: { imageFocused = true }) { item in
            RemoteImageViewer(item: item, resolver: model.resources).coversKeyboardCommands()
                .navigationTransition(.zoom(sourceID: PhotoStage.transitionID, in: photoTransition))
        }
        // Native fullscreen playback covers the reader too, though UIKit presents it.
        .focusedSceneValue(\.keyboardCommandsCovered, fullScreenPlayback ? true : nil)
        .background {
            NativeVideoPlayerPresentation(player: playback.player, isPresented: $fullScreenPlayback)
                .frame(width: 0, height: 0)
        }
    }

    private var downloadStatus: some View {
        VStack(spacing: 8) {
            if let fraction = downloadProgress.fraction {
                ProgressView(value: fraction).tint(RemoteFilesStyle.accent).accessibilityLabel("Download progress")
            } else {
                ProgressView().accessibilityLabel(loadingMessage)
            }
            Text(downloadProgress.sizeLabel())
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("Download size")
        }
    }

    private func load() async {
        guard !model.isDisconnecting else { loading = false; return }
        model.noteForegroundConnection(profile.id)
        if model.isForeground, playback.player != nil, lastLoadedSession == model.sessionRevision,
           refreshID == lastRefreshID, retryID == lastRetryID { loading = false; return }
        let token = UUID(); requestID = token
        let revision = model.sessionRevision
        let generation = model.listingGeneration(profile.id)
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
            let resource = try await model.loadMediaResource(for: reference, in: location, progress: { update in
                await MainActor.run {
                    guard requestID == token, !model.isDisconnecting, model.isForeground,
                          model.sessionRevision == revision, model.listingGeneration(profile.id) == generation else { return }
                    downloadProgress = update
                }
            })
            try Task.checkCancellation()
            guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision, model.listingGeneration(profile.id) == generation else { return }
            let file = resource.file
            failure = resource.connectionFailure?.localizedDescription
            if kind == .image {
                let decoded = try await RemoteImageDecoder.shared.decode(file, maxPixel: 1600)
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision, model.listingGeneration(profile.id) == generation else { return }
                image = decoded
            } else if kind == .video || kind == .audio {
                try await playback.prepare(file, filename: entry.name)
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision, model.listingGeneration(profile.id) == generation else {
                    playback.stop(); return
                }
            } else {
                // Hash the bytes before PDFKit opens them: a changed document starts at the top.
                var restorable = false
                if let readingPosition {
                    restorable = await model.preparePDFReadingPosition(readingPosition, fileURL: file, profile: profile, path: entry.path)
                }
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision, model.listingGeneration(profile.id) == generation else { return }
                guard let document = PDFDocument(url: file), document.pageCount > 0 else {
                    throw MediaPreviewError.invalidPDF
                }
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision, model.listingGeneration(profile.id) == generation else { return }
                let restoration = Self.pdfRestoration(openingPage: appliedOpeningPage ? nil : entry.openingPage,
                                                      saved: restorable ? readingPosition?.pdfAnchor : nil,
                                                      pageCount: document.pageCount)
                appliedOpeningPage = true
                if restorable, restoration != nil { readingPosition?.pdfAnchor = restoration }
                pdfRestoration = restoration; pdfPage = restoration?.ordinal ?? 0
                pdf = document
            }
            lastLoadedSession = revision
            await model.recordRecent(profile: profile, entry: entry)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else { return }
            failure = error.localizedDescription
            if model.isSecurityError(error) { image = nil; pdf = nil; playback.stop() }
        }
    }
}

/// A video as large as fits at its own shape, with the controls beneath it, or beside it when a
/// landscape phone has no height to spare. It leaves no black bars for the screen to light around it.
struct VideoStage: View {
    let playback: RemotePlaybackController
    let player: AVPlayer
    /// AVKit moves the player's layer to its fullscreen controller, so returning needs a new inline view.
    var isFullScreen = false
    var openFullScreen: (() -> Void)? = nil
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        let beside = verticalSizeClass == .compact
        let layout = beside ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            NativePlaybackView(player: player).id(isFullScreen)
                .aspectRatio(playback.videoAspectRatio ?? 16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PlaybackControls(playback: playback, openFullScreen: openFullScreen)
                .id(ObjectIdentifier(player))
                .frame(maxWidth: beside ? 320 : .infinity)
        }
    }
}

/// Transport controls laid out as the system's own players do: a scrubber with elapsed and remaining
/// time, then skip and play in the middle. Fullscreen sits apart, as it isn't part of the transport.
struct PlaybackControls: View {
    let playback: RemotePlaybackController
    var openFullScreen: (() -> Void)? = nil
    @State private var scrubbing = false
    @State private var position: Double = 0
    @ScaledMetric(relativeTo: .title) private var playSize: CGFloat = 60
    private static let skipSeconds: Double = 10
    private var shownElapsed: Double { scrubbing ? position : min(playback.elapsed, playback.duration) }
    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { shownElapsed },
                                  set: { position = $0; if !scrubbing { playback.seek(to: $0) } }), in: 0...max(playback.duration, 0.01)) { editing in
                if editing { position = min(playback.elapsed, playback.duration) }
                scrubbing = editing
                if !editing { playback.seek(to: position) }
            }
            .disabled(playback.duration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(time(scrubbing ? position : playback.elapsed)) of \(time(playback.duration))")
            HStack {
                Text(time(shownElapsed))
                Spacer()
                Text("-" + time(playback.duration - shownElapsed))
                    .accessibilityLabel("\(time(playback.duration - shownElapsed)) remaining")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                // The same width as Full Screen, so the transport stays in the middle.
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                Spacer(minLength: 0)
                HStack(spacing: 20) {
                    skip("Back 10 Seconds", symbol: "gobackward.10", by: -Self.skipSeconds)
                    playButton
                    skip("Forward 10 Seconds", symbol: "goforward.10", by: Self.skipSeconds)
                }
                Spacer(minLength: 0)
                if let openFullScreen {
                    Button(action: openFullScreen) {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly).font(.body.weight(.medium)).foregroundStyle(.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }
            .padding(.top, 4)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .accessibilityIdentifier("Playback controls")
    }
    private var playButton: some View {
        Button { playback.togglePlayback() } label: {
            Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                .labelStyle(.iconOnly).font(.title).foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: playSize, height: playSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
    private func skip(_ title: String, symbol: String, by seconds: Double) -> some View {
        Button { playback.seek(to: playback.elapsed + seconds) } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly).font(.title2).foregroundStyle(.primary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(playback.duration <= 0)
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
        // The stage sizes this to the video; any sliver of rounding shows the screen, not black.
        controller.view.backgroundColor = .clear
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
        context.coordinator.openURL = context.environment.openURL
        context.coordinator.attach(view, parent: self)
        return view
    }
    func updateUIView(_ view: RestoringPDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.openURL = context.environment.openURL
        if view.document !== document {
            view.document = document
            view.restart(with: restoration)
        }
    }
    static func dismantleUIView(_ view: RestoringPDFView, coordinator: Coordinator) {
        coordinator.record()
        coordinator.detach()
    }

    @MainActor final class Coordinator: NSObject, PDFViewDelegate {
        var parent: PDFDocumentView?
        var openURL: OpenURLAction?
        private weak var view: RestoringPDFView?

        func attach(_ view: RestoringPDFView, parent: PDFDocumentView) {
            self.view = view; self.parent = parent
            // Without a delegate that takes link taps, PDFKit opens the URL itself, whatever its scheme.
            view.delegate = self
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            view.onRestored = { [weak self] in self?.pageChanged() }
            // The weak capture becomes a no-op once this view is gone; a newer view replaces it.
            parent.readingPosition?.capturePDFPosition = { [weak self] in self?.record() }
        }
        func detach() {
            if let view { NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: view) }
            view?.onRestored = nil
            view?.delegate = nil
            view = nil
        }
        /// A link in a PDF gets the rule Markdown and HTML links get: web addresses only, so a
        /// document cannot start another app, a shortcut or an install through a custom scheme.
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            guard DocumentPolicy.allowsExternalLink(url) else { return }
            openURL?(url)
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
