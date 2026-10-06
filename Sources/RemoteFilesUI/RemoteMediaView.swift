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
    @State private var image: DisplayImage?
    @State private var pdf: PDFDocument?
    @State private var loading = false
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

    private var location: RemoteDocumentLocation { .init(profile: profile, path: entry.path) }
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
                StatusBanner(message: "Previously loaded copy · refreshing…")
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
                        Text("\(pdf.pageCount) \(pdf.pageCount == 1 ? "page" : "pages")")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        PDFDocumentView(document: pdf)
                            .accessibilityLabel("PDF \(entry.name), \(pdf.pageCount) pages")
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
                        ProgressView(loadingMessage)
                        if kind == .video || kind == .audio {
                            Text("Playback is available when the download finishes. Up to 128 MiB per file.")
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
        loading = true; failure = nil
        defer { if requestID == token { loading = false } }
        do {
            let file = try await model.resources.localFile(for: reference, in: location)
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
                guard let document = PDFDocument(url: file), document.pageCount > 0 else {
                    throw MediaPreviewError.invalidPDF
                }
                try Task.checkCancellation()
                guard requestID == token, !model.isDisconnecting, model.isForeground, model.sessionRevision == revision else { return }
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

private struct PlaybackControls: View {
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

private struct NativePlaybackView: UIViewControllerRepresentable {
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

private enum MediaPreviewError: LocalizedError {
    case invalidPDF
    var errorDescription: String? { "This file is not a readable PDF, or its PDF data is damaged." }
}

private struct PDFDocumentView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.document = document
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
#endif
