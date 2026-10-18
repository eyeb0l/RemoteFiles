import SwiftUI
import RemoteFilesCore
import Textual

struct ReaderTextReveal: Equatable {
    let id = UUID()
    let target: DocumentTextTarget
    let inSource: Bool
}

@MainActor @Observable public final class ReaderNavigationState {
    private(set) var index: DocumentTextIndex?
    private(set) var revision = UUID()
    var query = ""
    var isFinding = false
    private(set) var matches: [DocumentTextTarget] = []
    private(set) var selected = 0
    private(set) var truncated = false
    private(set) var searching = false
    private(set) var reveal: ReaderTextReveal?
    private(set) var completedReveal: UUID?
    var pendingRevealID: UUID? { reveal?.id == completedReveal ? nil : reveal?.id }
    @ObservationIgnored private var preparationID = UUID()

    func prepare(text: String, markdown: Bool) async {
        if let index, index.source.utf8.elementsEqual(text.utf8) { return }
        let token = UUID(); preparationID = token
        let task = Task.detached(priority: .userInitiated) { try DocumentTextIndex(text: text, markdown: markdown) }
        let result = await withTaskCancellationHandler(operation: { try? await task.value }, onCancel: { task.cancel() })
        guard !Task.isCancelled, preparationID == token else { return }
        index = result; revision = UUID(); matches = []; reveal = nil; selected = 0
    }

    func search(inSource: Bool) async {
        let query = query
        guard isFinding else { searching = false; return }
        guard !query.isEmpty, let index else { matches = []; reveal = nil; searching = false; return }
        searching = true; matches = []; reveal = nil
        do {
            try await Task.sleep(for: .milliseconds(150))
            let task = Task.detached(priority: .userInitiated) { try index.matches(query, inSource: inSource) }
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard self.query == query, isFinding else { return }
            matches = result.targets; truncated = result.truncated; selected = 0; searching = false
            if let first = matches.first { reveal = .init(target: first, inSource: inSource) }
        } catch { if !Task.isCancelled { searching = false } }
    }

    func move(_ delta: Int, inSource: Bool) {
        guard !matches.isEmpty else { return }
        selected = (selected + delta + matches.count) % matches.count
        reveal = .init(target: matches[selected], inSource: inSource)
    }
    func show(_ heading: DocumentHeading) {
        isFinding = false; query = ""; matches = []
        reveal = .init(target: heading.target, inSource: false)
    }
    func closeFind() { isFinding = false; query = ""; reveal = nil; matches = [] }
    func didReveal(_ id: UUID) { if reveal?.id == id { completedReveal = id } }
    func clear() {
        preparationID = UUID(); index = nil; revision = UUID()
        closeFind(); completedReveal = nil; searching = false
    }

    func decorated(_ text: AttributedString, partID: Int) -> AttributedString {
        guard let reveal, !reveal.inSource, reveal.target.partID == partID,
              let range = Range(reveal.target.range, in: String(text.characters)),
              let lower = AttributedString.Index(range.lowerBound, within: text),
              let upper = AttributedString.Index(range.upperBound, within: text) else { return text }
        var result = text
        result[lower..<upper][TextualNavigationTarget.self] = reveal.id
        result[lower..<upper].backgroundColor = .yellow.opacity(0.65)
        result[lower..<upper].foregroundColor = .black
        return result
    }
}

#if os(iOS)
struct ReaderFindBar: View {
    @Bindable var navigation: ReaderNavigationState
    let inSource: Bool
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                TextField("Find in document", text: $navigation.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($focused)
                    .accessibilityIdentifier("reader-find-query")
                    .frame(minHeight: 44)
                Button("Previous result", systemImage: "chevron.up") { focused = false; navigation.move(-1, inSource: inSource) }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(navigation.matches.isEmpty)
                Button("Next result", systemImage: "chevron.down") { focused = false; navigation.move(1, inSource: inSource) }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(navigation.matches.isEmpty)
                Button("Done") { focused = false; navigation.closeFind() }.frame(minHeight: 44)
            }
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader-find-status")
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer()
            }
        }
        .padding(.horizontal).padding(.vertical, 8).background(.bar)
        .onAppear { focused = true }
    }
    private var status: String {
        if navigation.query.isEmpty { return "Enter text to find" }
        if navigation.searching { return "Searching…" }
        if navigation.matches.isEmpty { return "No results" }
        return "\(navigation.selected + 1) of \(navigation.matches.count)\(navigation.truncated ? "+" : "")"
    }
}

struct ReaderHeadingsView: View {
    let headings: [DocumentHeading]
    let select: (DocumentHeading) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(headings) { heading in
                Button {
                    select(heading); dismiss()
                } label: {
                    Text(heading.title).foregroundStyle(.primary)
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                }
                .accessibilityLabel("\(heading.title), heading level \(heading.level)")
            }
            .navigationTitle("Headings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
