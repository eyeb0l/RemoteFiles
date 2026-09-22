import SwiftUI
import Textual
import RemoteFilesCore

/// The sole integration boundary for the Markdown renderer. Source is never editable.
public struct DocumentContentView: View {
    public let text: String
    public let markdown: Bool
    public let source: Bool
    @State private var prepared: AttributedString?
    @State private var preparedSource: String?
    @State private var preparationFailed = false

    public init(text: String, markdown: Bool, source: Bool) {
        self.text = text
        self.markdown = markdown
        self.source = source
    }

    public var body: some View {
        Group {
            if !markdown || source {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .accessibilityLabel(markdown ? "Markdown source" : "Plain text document")
            } else {
                ScrollView {
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
                            // The text changes only when preparation completes. Unrelated view updates
                            // and switching to Source do not reparse the document.
                            StructuredText(preparedSource ?? "", parser: PreparedDocumentParser(document: prepared))
                                .textual.textSelection(.enabled)
                                .textual.tableStyle(.overflow(relativeWidth: 3))
                                .textual.overflowMode(.scroll)
                                .textual.imageAttachmentLoader(NoImageLoader())
                                .textual.emojiAttachmentLoader(NoImageLoader())
                                .environment(\.openURL, OpenURLAction { url in
                                    DocumentPolicy.allowsExternalLink(url) ? .systemAction : .discarded
                                })
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                .accessibilityLabel("Rendered Markdown document")
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
    func prepare(_ text: String) throws -> AttributedString {
        try Task.checkCancellation()
        let result = try DocumentPolicy.prepareMarkdown(text)
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
