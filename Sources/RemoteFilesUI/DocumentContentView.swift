import SwiftUI
import Textual
import RemoteFilesCore

/// The sole integration boundary for the Markdown renderer. Source is never editable.
public struct DocumentContentView: View {
    public let text: String
    public let markdown: Bool
    public let source: Bool
    public let filename: String?
    @State private var prepared: [MarkdownPart]?
    public let location: RemoteDocumentLocation?
    public let resolver: (any RemoteResourceResolving)?
    @State private var preparedSource: String?
    @State private var preparationFailed = false

    public init(text: String, markdown: Bool, source: Bool, filename: String? = nil, location: RemoteDocumentLocation? = nil, resolver: (any RemoteResourceResolving)? = nil) {
        self.text = text
        self.markdown = markdown
        self.source = source
        self.filename = filename
        self.location = location; self.resolver = resolver
    }

    public var body: some View {
        Group {
            if !markdown || source {
                ScrollView([.horizontal, .vertical]) {
                    SourceCodeView(text: text, language: markdown ? "markdown" : SourceLanguage.forFilename(filename))
                }
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
                                    StructuredText(String(attributed.characters), parser: PreparedDocumentParser(document: attributed))
                                        .textual.textSelection(.enabled)
                                        .textual.tableStyle(.overflow(relativeWidth: 3))
                                        .textual.overflowMode(.scroll)
                                        .textual.imageAttachmentLoader(NoImageLoader())
                                        .textual.emojiAttachmentLoader(NoImageLoader())
                                        .environment(\.openURL, OpenURLAction { url in
                                            DocumentPolicy.allowsExternalLink(url) ? .systemAction : .discarded
                                        })
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                case .image(let reference, let alt):
                                    #if os(iOS)
                                    if let location, let resolver {
                                        RemoteInlineImage(reference: reference, alt: alt, location: location,
                                                          resolver: resolver, viewportHeight: viewport.size.height)
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
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "readerViewport")
                .accessibilityLabel("Rendered Markdown document")
                }
            }
        }
        .task(id: markdown ? text : "") {
            guard markdown, preparedSource != text else { return }
            let input = text
            preparationFailed = false
            do {
                let result = try await MarkdownPreparation.shared.prepare(input)
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
}

private struct PreparedDocumentParser: MarkupParser {
    let document: AttributedString
    func attributedString(for input: String) throws -> AttributedString { document }
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
