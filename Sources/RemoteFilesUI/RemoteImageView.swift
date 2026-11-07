#if os(iOS)
import SwiftUI
import Textual
import UIKit
import ImageIO
import RemoteFilesCore

struct RemoteInlineImage: View {
    @Environment(\.scenePhase) private var scenePhase
    let reference: String
    let alt: String
    let location: RemoteDocumentLocation
    let resolver: any RemoteResourceResolving
    let viewportHeight: CGFloat
    var readingAnchorID = ""
    var readingGeometry: OverflowGeometryCache? = nil
    @State private var nearViewport = false
    @State private var image: DisplayImage?
    @State private var failure: String?
    @State private var loading = false
    @State private var reservedHeight: CGFloat?
    @State private var retry = 0
    @State private var viewer: ImagePresentation?
    private enum ImageAction: Hashable { case image, openFile }
    @AccessibilityFocusState(for: .voiceOver) private var focusedAction: ImageAction?
    @State private var invokingAction: ImageAction?
    private var filename: String { URLComponents(string: reference)?.path.split(separator: "/").last.map(String.init) ?? reference }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Button { open(from: .image) } label: {
                    Image(uiImage: UIImage(cgImage: image.image)).resizable().scaledToFit()
                        .frame(maxHeight: 520).frame(maxWidth: .infinity)
                }.buttonStyle(.plain).accessibilityLabel("Open image \(filename)")
                    .accessibilityFocused($focusedAction, equals: .image)
                if !alt.isEmpty { Text(alt).font(.caption).foregroundStyle(.secondary) }
            } else {
                HStack {
                    Image(systemName: "photo")
                    Text(filename).font(.callout).lineLimit(2)
                    Spacer()
                    if loading { ProgressView().accessibilityLabel("Loading \(filename)") }
                }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    HStack {
                        Button("Tap to retry") { retry += 1 }
                        Button("Open file") { open(from: .openFile) }
                            .accessibilityFocused($focusedAction, equals: .openFile)
                    }.font(.callout)
                } else { Text("Image loads as you scroll").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(image == nil ? 12 : 0)
        .frame(minHeight: image == nil ? reservedHeight : nil)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if image != nil { reservedHeight = height }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(image == nil ? Color.secondary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .onGeometryChange(for: Bool.self) { proxy in
            let frame = proxy.frame(in: .named("readerViewport"))
            return frame.maxY >= -300 && frame.minY <= viewportHeight + 300
        } action: { nearViewport = $0 }
        .task(id: "\(nearViewport)-\(retry)-\(scenePhase)") {
            guard scenePhase == .active, nearViewport else { image = nil; return }
            loading = true; failure = nil
            defer { loading = false }
            do {
                if retry > 0 { await resolver.invalidate(reference, in: location) }
                let file = try await resolver.localFile(for: reference, in: location)
                let decoded = try await RemoteImageDecoder.shared.decode(file, maxPixel: 1600)
                try Task.checkCancellation(); image = decoded
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .textual.readingAnchorRegion(id: readingAnchorID, geometryCache: readingGeometry,
                                    ready: image != nil || failure != nil)
        .onDisappear { image = nil }
        .fullScreenCover(item: $viewer, onDismiss: { focusedAction = invokingAction }) { item in
            RemoteImageViewer(item: item, resolver: resolver).coversKeyboardCommands()
        }
    }
    private func open(from action: ImageAction) {
        invokingAction = action
        viewer = ImagePresentation(reference: reference, filename: filename, location: location, alt: alt,
                                   checkExistence: action == .openFile, preview: image)
    }
}

struct ImagePresentation: Identifiable {
    let id = UUID()
    let reference: String
    let filename: String
    let location: RemoteDocumentLocation
    var alt: String = ""
    var checkExistence = false
    /// The smaller copy already on screen, shown at once while the full-size decode runs.
    var preview: DisplayImage? = nil
    var accessibilityDescription: String {
        alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? filename : alt
    }
}

struct RemoteImageViewer: View {
    let item: ImagePresentation
    let resolver: any RemoteResourceResolving
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: DisplayImage?
    @State private var failure: String?
    @State private var retry = 0
    /// A failed reload discards the preview too, so a stale picture never stands in for an error.
    private var shown: DisplayImage? { image ?? (failure == nil ? item.preview : nil) }
    var body: some View {
        ImageViewerChrome(title: item.filename, image: shown.map { UIImage(cgImage: $0.image) },
                          shareable: image.map { UIImage(cgImage: $0.image) },
                          description: item.accessibilityDescription) {
            if let failure {
                ContentUnavailableView {
                    Label(item.filename, systemImage: "photo")
                } description: {
                    Text(failure).accessibilityIdentifier("remote-image-viewer-error")
                } actions: {
                    Button("Tap to retry") { retry += 1 }
                        .accessibilityIdentifier("remote-image-viewer-retry")
                }
            } else { ProgressView("Loading image…") }
        }
        .task(id: "\(retry)-\(scenePhase)") {
            guard scenePhase == .active else { return }
            failure = nil
            do {
                if retry > 0 { await resolver.invalidate(item.reference, in: item.location) }
                let file: URL
                if item.checkExistence {
                    file = try await resolver.localFileForOpening(for: item.reference, in: item.location)
                } else {
                    file = try await resolver.localFile(for: item.reference, in: item.location)
                }
                let result = try await RemoteImageDecoder.shared.decode(file, maxPixel: 3072)
                try Task.checkCancellation(); image = result
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled {
                    image = nil
                    failure = error.localizedDescription
                }
            }
        }
    }
}

/// The full-screen picture, connected and offline, behaving as Photos does: bars over the system
/// background, and a tap takes them away and turns everything else black. VoiceOver and Switch
/// Control keep the bars, as the picture alone would leave them nothing to reach.
struct ImageViewerChrome<Unavailable: View>: View {
    let title: String
    /// What's on screen, possibly the reader's smaller copy while the full-size one decodes.
    let image: UIImage?
    /// What Share sends: only the full-size copy, and nothing once a reload has failed.
    let shareable: UIImage?
    let description: String
    @ViewBuilder let unavailable: () -> Unavailable
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @State private var barsHidden = false
    @State private var zoomed = false
    @State private var sharing = false
    private var immersive: Bool { barsHidden && image != nil && !voiceOver && !switchControl }
    var body: some View {
        NavigationStack {
            ZStack {
                (immersive ? Color.black : Color(uiColor: .systemBackground)).ignoresSafeArea()
                if let image {
                    ZoomableRemoteImage(image: image, description: description,
                                        onTap: { withAnimation(RemoteFilesStyle.contentFade) { barsHidden.toggle() } },
                                        onZoomChange: { zoomed = $0 })
                        .ignoresSafeArea()
                } else { unavailable() }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") { sharing = true }.disabled(shareable == nil)
                }
            }
            .toolbarVisibility(immersive ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(immersive)
            .persistentSystemOverlays(immersive ? .hidden : .automatic)
            .background {
                // Done's own Escape shortcut leaves with the bar, so this stands in for it.
                if immersive {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                        .opacity(0).accessibilityHidden(true)
                }
            }
            .sheet(isPresented: $sharing) {
                if let shareable { ImageShareSheet(image: shareable) }
            }
            .onChange(of: shareable == nil) { _, gone in if gone { sharing = false } }
        }
        // Dragging a zoomed picture moves the picture; it shouldn't also start closing the viewer.
        .interactiveDismissDisabled(zoomed)
        .accessibilityAction(.escape) { dismiss() }
    }
}

/// A picture in a reader: as large as fits, centred, with no frame of its own, and never blown up
/// past its pixels. Opening it grows it into the viewer from where it sits.
struct PhotoStage: View {
    let image: CGImage
    let accessibilityLabel: String
    let transition: Namespace.ID
    let open: () -> Void
    static let transitionID = "photo-stage"
    var body: some View {
        Button(action: open) {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: CGFloat(image.width), maxHeight: CGFloat(image.height))
                .matchedTransitionSource(id: Self.transitionID, in: transition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ImageShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ZoomableRemoteImage: UIViewRepresentable {
    let image: UIImage
    let description: String
    var onTap: (() -> Void)? = nil
    var onZoomChange: ((Bool) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ImageZoomScrollView {
        let scroll = ImageZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.show(image)
        scroll.imageView.isAccessibilityElement = true
        scroll.imageView.accessibilityTraits = .image
        scroll.imageView.accessibilityLabel = description
        scroll.addSubview(scroll.imageView)
        return scroll
    }
    func updateUIView(_ scroll: ImageZoomScrollView, context: Context) {
        scroll.show(image)
        scroll.imageView.accessibilityLabel = description
        scroll.onTap = onTap
        context.coordinator.onZoomChange = onZoomChange
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        var onZoomChange: ((Bool) -> Void)?
        private var zoomed = false
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageZoomScrollView)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ImageZoomScrollView)?.centerImage()
            let now = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard now != zoomed else { return }
            zoomed = now
            // Zooming can happen during layout, where SwiftUI state mustn't change.
            Task { @MainActor [weak self] in self?.onZoomChange?(now) }
        }
    }
}

/// Sizes the image view to the picture rather than the screen, so it stays centred at any zoom and
/// panning stops at the picture's edges instead of carrying on into empty space.
final class ImageZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    var onTap: (() -> Void)?
    private var fittedBounds: CGSize = .zero
    private var fittedAspect: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Swapping in a sharper copy of the same picture keeps the current zoom and position.
    func show(_ image: UIImage) {
        imageView.image = image
        guard image.size.height > 0, abs(image.size.width / image.size.height - fittedAspect) > 0.01 else { return }
        fittedBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != fittedBounds, let size = imageView.image?.size, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        fittedBounds = bounds.size
        fittedAspect = size.width / size.height
        setZoomScale(minimumZoomScale, animated: false)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        contentSize = imageView.frame.size
        centerImage()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }

    /// Zoomed in, returns to the whole picture. Otherwise zooms in around `point`, which is in the
    /// image view's coordinates: far enough to fill the screen, or further if it nearly fills it.
    func toggleZoom(at point: CGPoint) {
        let animated = !UIAccessibility.isReduceMotionEnabled
        guard zoomScale <= minimumZoomScale + 0.01 else { setZoomScale(minimumZoomScale, animated: animated); return }
        let fitted = imageView.bounds.size
        guard fitted.width > 0, fitted.height > 0 else { return }
        let fill = max(bounds.width / fitted.width, bounds.height / fitted.height)
        let scale = min(fill > 1.25 ? fill : 2.5, maximumZoomScale)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
             animated: animated)
    }

    @objc private func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
        toggleZoom(at: recognizer.location(in: imageView))
    }
    @objc private func didTap() { onTap?() }
}
#endif
