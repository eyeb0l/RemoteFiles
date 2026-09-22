#if os(iOS)
import SwiftUI
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
    @State private var nearViewport = false
    @State private var image: DisplayImage?
    @State private var failure: String?
    @State private var loading = false
    @State private var reservedHeight: CGFloat?
    @State private var retry = 0
    @State private var viewer: ImagePresentation?
    private var filename: String { URLComponents(string: reference)?.path.split(separator: "/").last.map(String.init) ?? reference }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Button { open() } label: {
                    Image(uiImage: UIImage(cgImage: image.image)).resizable().scaledToFit()
                        .frame(maxHeight: 520).frame(maxWidth: .infinity)
                }.buttonStyle(.plain).accessibilityLabel("Open image \(filename)")
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
                        Button("Open file") { open() }
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
        .onDisappear { image = nil }
        .fullScreenCover(item: $viewer) { item in
            RemoteImageViewer(item: item, resolver: resolver)
        }
    }
    private func open() { viewer = ImagePresentation(reference: reference, filename: filename, location: location) }
}

struct ImagePresentation: Identifiable {
    let id = UUID()
    let reference: String
    let filename: String
    let location: RemoteDocumentLocation
}

struct RemoteImageViewer: View {
    let item: ImagePresentation
    let resolver: any RemoteResourceResolving
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: DisplayImage?
    @State private var failure: String?
    @State private var retry = 0
    @State private var sharing = false
    var body: some View {
        NavigationStack {
            Group {
                if let image { ZoomableRemoteImage(image: UIImage(cgImage: image.image)) }
                else if let failure {
                    ContentUnavailableView {
                        Label(item.filename, systemImage: "photo")
                    } description: { Text(failure) } actions: { Button("Tap to retry") { retry += 1 } }
                } else { ProgressView("Loading image…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(item.filename).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") { sharing = true }.disabled(image == nil)
                }
            }
            .task(id: "\(retry)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                failure = nil
                do {
                    if retry > 0 { await resolver.invalidate(item.reference, in: item.location) }
                    let file = try await resolver.localFile(for: item.reference, in: item.location)
                    let result = try await RemoteImageDecoder.shared.decode(file, maxPixel: 3072)
                    try Task.checkCancellation(); image = result
                } catch is CancellationError { }
                catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
            .sheet(isPresented: $sharing) {
                if let image { ImageShareSheet(image: UIImage(cgImage: image.image)) }
            }
        }
    }
}

private struct ImageShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ZoomableRemoteImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ImageZoomScrollView {
        let scroll = ImageZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.imageView.image = image
        scroll.addSubview(scroll.imageView)
        return scroll
    }
    func updateUIView(_ scroll: ImageZoomScrollView, context: Context) { scroll.imageView.image = image }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageZoomScrollView)?.imageView }
    }
}
private final class ImageZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private var lastSize: CGSize = .zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        setZoomScale(1, animated: false)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }
}
#endif
