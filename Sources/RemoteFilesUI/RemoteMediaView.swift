#if os(iOS)
import SwiftUI
import PDFKit
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
    @AccessibilityFocusState(for: .voiceOver) private var imageFocused: Bool

    private var location: RemoteDocumentLocation { .init(profile: profile, path: entry.path) }
    private var reference: String {
        var components = URLComponents()
        components.path = entry.name
        return components.percentEncodedPath
    }

    var body: some View {
        VStack(spacing: 0) {
            if let failure {
                StatusBanner(message: (image != nil || pdf != nil) ? "Previously loaded copy · \(failure)" : failure, error: true)
            } else if loading && (image != nil || pdf != nil) {
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
                } else if loading {
                    ProgressView(kind == .pdf ? "Loading PDF…" : "Loading image…")
                } else {
                    ContentUnavailableView {
                        Label(entry.name, systemImage: kind == .pdf ? "doc.richtext" : "photo")
                    } description: {
                        Text(failure ?? "The preview is unavailable.")
                    } actions: {
                        Button("Tap to retry") { retryID += 1 }.buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(model.isForeground)-\(model.sessionRevision)-\(refreshID)-\(retryID)") { await load() }
        .fullScreenCover(item: $viewer, onDismiss: { imageFocused = true }) { item in RemoteImageViewer(item: item, resolver: model.resources) }
    }

    private func load() async {
        guard model.isForeground else {
            image = nil; pdf = nil; loading = false
            failure = "Connection paused while the app is in the background."
            return
        }
        if refreshID != lastRefreshID || retryID != lastRetryID {
            // PDFKit may read pages lazily from the cached file. Release it before replacing that file.
            pdf = nil
            await model.resources.invalidate(reference, in: location)
            lastRefreshID = refreshID
            lastRetryID = retryID
        }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let file = try await model.resources.localFile(for: reference, in: location)
            if kind == .image {
                let decoded = try await RemoteImageDecoder.shared.decode(file, maxPixel: 1600)
                try Task.checkCancellation()
                image = decoded
            } else {
                guard let document = PDFDocument(url: file), document.pageCount > 0 else {
                    throw MediaPreviewError.invalidPDF
                }
                try Task.checkCancellation()
                pdf = document
            }
            model.connectionStates[profile.id] = "Connected"
            await model.recordRecent(profile: profile, entry: entry)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            if model.isSecurityError(error) { image = nil; pdf = nil }
            model.handle(error, profile: profile)
        }
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
