import SwiftUI
import Textual
import RemoteFilesCore

/// The sole integration boundary for the Markdown renderer. Source is never editable.
public struct DocumentContentView: View {
    public let text: String
    public let markdown: Bool
    public let source: Bool
    public let filename: String?
    public let openDocumentLink: ((URL) -> Void)?
    public let readingPosition: DocumentReadingPosition?
    public let wrapLines: Bool
    private let navigation: ReaderNavigationState?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var localReadingPosition = DocumentReadingPosition()
    @State private var prepared: [MarkdownPart]?
    public let location: RemoteDocumentLocation?
    public let resolver: (any RemoteResourceResolving)?
    @State private var preparedSource: String?
    @State private var preparationFailed = false
    @State private var deferInitialOverflow = false

    public init(text: String, markdown: Bool, source: Bool, filename: String? = nil, location: RemoteDocumentLocation? = nil, resolver: (any RemoteResourceResolving)? = nil, readingPosition: DocumentReadingPosition? = nil, openDocumentLink: ((URL) -> Void)? = nil, wrapLines: Bool = true, navigation: ReaderNavigationState? = nil) {
        self.text = text
        self.markdown = markdown
        self.source = source
        self.filename = filename
        self.location = location; self.resolver = resolver
        self.readingPosition = readingPosition; self.openDocumentLink = openDocumentLink
        self.wrapLines = wrapLines
        self.navigation = navigation
    }

    public var body: some View {
        @Bindable var position = readingPosition ?? localReadingPosition
        Group {
            #if os(iOS)
            if !source, let filename, DocumentPolicy.kind(filename: filename) == .html {
                HTMLContentView(text: text, filename: filename, readingPosition: position)
            } else if !source, let filename, DocumentPolicy.kind(filename: filename) == .svg {
                SVGContentView(text: text, filename: filename)
            } else if !markdown || source {
                SourceCodeView(text: text, language: markdown ? "markdown" : SourceLanguage.forFilename(filename),
                               bounded: true, readingPosition: position, reveal: navigation?.reveal,
                               wrapLines: SourceLayout.needsBoundedLayout(text) || wrapLines,
                               revealPending: navigation?.pendingRevealID != nil,
                               onReveal: { navigation?.didReveal($0) })
            } else {
                ordinaryContent(position: position)
            }
            #else
            ordinaryContent(position: position)
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            position.overflowGeometry.clearLayoutCache()
        }
        #endif
        .task(id: markdown ? text : "") {
            await prepareMarkdownIfNeeded()
        }
        .onChange(of: dynamicTypeSize) { _, _ in
            guard !source, navigation?.pendingRevealID == nil else { return }
            let position = readingPosition ?? localReadingPosition
            position.overflowGeometry.restoreReadingAnchor { position.rendered = $0 }
        }
    }

    @ViewBuilder private func ordinaryContent(position: DocumentReadingPosition) -> some View {
        @Bindable var position = position
        Group {
            if !markdown || source {
                ScrollView(wrapLines ? .vertical : [.horizontal, .vertical]) {
                    SourceCodeView(text: text, language: markdown ? "markdown" : SourceLanguage.forFilename(filename))
                }
                .modifier(DocumentScrollPreservation(saved: Binding(
                    get: { CGPoint(x: wrapLines ? 0 : position.source.x, y: position.source.y) },
                    set: { position.source = $0 }), ready: true, navigationID: navigation?.pendingRevealID))
                .scrollIndicators(.visible)
                .scrollIndicatorsFlash(onAppear: !wrapLines)
                .id(wrapLines)
                .accessibilityLabel(markdown ? "Markdown source" : "Plain text document")
            } else {
                GeometryReader { viewport in
                ScrollView {
                    // Textual installs prepared content after its first layout. A lazy stack
                    // can retain that initial zero-height row for image-free documents.
                    // Mount text eagerly; RemoteInlineImage still gates I/O by viewport geometry.
                    VStack(alignment: .leading, spacing: 12) {
                        if let prepared {
                            if preparationFailed {
                                Label("The updated document could not be rendered. Showing the previous rendering.", systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else if preparedSource != text {
                                ProgressView("Preparing updated document…")
                                    .font(.callout)
                            }
                            ForEach(prepared) { part in
                                switch part.content {
                                case .text(let attributed):
                                    let decorated = navigation?.decorated(attributed, partID: part.id) ?? attributed
                                    StructuredText(decorated)
                                        .id(part.id)
                                        .textual.revealNavigationTarget(navigation?.reveal?.inSource == false ? navigation?.pendingRevealID : nil,
                                            onReveal: { navigation?.didReveal($0) })
                                        .textual.textSelection(.enabled)
                                        .textual.tableStyle(.overflow(relativeWidth: 3))
                                        .textual.overflowMode(.scroll)
                                        .textual.imageAttachmentLoader(NoImageLoader())
                                        .textual.emojiAttachmentLoader(NoImageLoader())
                                        .environment(\.openURL, OpenURLAction { url in
                                            if DocumentPolicy.allowsExternalLink(url) { return .systemAction }
                                            if DocumentPolicy.isRelativeDocumentLink(url), let openDocumentLink {
                                                openDocumentLink(url)
                                                return .handled
                                            }
                                            return .discarded
                                        })
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                case .image(let reference, let alt):
                                    #if os(iOS)
                                    if let location, let resolver {
                                        RemoteInlineImage(reference: reference, alt: alt, location: location,
                                                          resolver: resolver, viewportHeight: viewport.size.height,
                                                          readingAnchorID: "image-\(part.id)", readingGeometry: position.overflowGeometry)
                                    } else { Text(alt.isEmpty ? reference : alt).foregroundStyle(.secondary) }
                                    #else
                                    Text(alt.isEmpty ? reference : alt).foregroundStyle(.secondary)
                                    #endif
                                }
                            }

                        } else if preparationFailed {
                            ContentUnavailableView("Rendered Preview Unavailable", systemImage: "doc.text",
                                                   description: Text("Use Source to read or copy this document."))
                        } else {
                            ProgressView("Preparing document…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                        }
                    }
                    #if os(iOS)
                    .textual.viewportOverflowRendering(in: "readerViewport", viewportHeight: viewport.size.height,
                        deferInitialOffscreenContent: deferInitialOverflow, geometryCache: position.overflowGeometry)
                    #endif
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(DocumentScrollPreservation(saved: $position.rendered, ready: prepared != nil,
                                                     overflowGeometry: position.overflowGeometry,
                                                     navigationID: navigation?.pendingRevealID))
                .coordinateSpace(name: "readerViewport")
                .accessibilityLabel("Rendered Markdown document")
                .onAppear {
                    deferInitialOverflow = text.utf8.count >= 64 * 1024 && position.rendered == .zero
                }
                }
            }
        }
    }

    private func prepareMarkdownIfNeeded() async {
        guard markdown, preparedSource != text else { return }
        let input = text
        (readingPosition ?? localReadingPosition).overflowGeometry.documentDidChange(input)
        // Small documents and coordinate restoration keep precise eager layout.
        // Freeze this choice for the mount; ordinary scrolling must not switch renderers.
        deferInitialOverflow = input.utf8.count >= 64 * 1024 &&
            (readingPosition ?? localReadingPosition).rendered == .zero
        preparationFailed = false
        do {
            let result: [MarkdownPart]
            if let index = navigation?.index, index.source.utf8.elementsEqual(input.utf8) { result = index.parts }
            else { result = try await MarkdownPreparation.shared.prepare(input) }
            guard !Task.isCancelled else { return }
            prepared = result
            preparedSource = input
            preparationFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            preparationFailed = true
        }
    }
}

private actor MarkdownPreparation {
    static let shared = MarkdownPreparation()
    func prepare(_ text: String) throws -> [MarkdownPart] {
        try Task.checkCancellation()
        let result = try DocumentPolicy.remoteMarkdownParts(text)
        try Task.checkCancellation()
        return result
    }
}

/// Defense in depth: even if a later attributed-content change reintroduces an attachment URL,
/// this loader performs no file or network access. The policy replaces current images with alt text.
private struct NoImageLoader: AttachmentLoader {
    func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> BlockedImage {
        throw ImagesDisabled()
    }
    private struct ImagesDisabled: Error {}
}

private struct BlockedImage: Attachment {
    var description: String { "Image preview unavailable" }
    var body: some View { Text(description) }
    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize { .zero }
}
