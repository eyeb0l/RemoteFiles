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
    /// Bumped by each Find request, so an open Find field takes focus again.
    private(set) var findFocusRequest = 0
    private(set) var findKeyboardRestoreRequest = 0
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
    func startFind() { isFinding = true; findFocusRequest += 1 }
    func restoreFindKeyboard() { if isFinding { findKeyboardRestoreRequest += 1 } }
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
        result[lower..<upper].backgroundColor = .yellow
        result[lower..<upper].foregroundColor = .black
        return result
    }
}

#if os(iOS)
struct ReaderFindBar: View {
    @Bindable var navigation: ReaderNavigationState
    let inSource: Bool
    let isCovered: Bool
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.offlineKeyboardScope) private var offlineKeyboardScope
    var body: some View {
        // Large text needs the whole width for what's being typed.
        let large = dynamicTypeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find in document", text: $navigation.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($focused)
                    // Return moves to the next result, like Find Next.
                    .onSubmit { navigation.move(1, inSource: inSource) }
                    .accessibilityIdentifier("reader-find-query")
                if !large { statusText }
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(.fill.tertiary, in: .capsule)
            HStack(spacing: 0) {
                if large { statusText; Spacer(minLength: 8) }
                Button { focused = false; navigation.move(-1, inSource: inSource) } label: { IconTarget(symbol: "chevron.up") }
                    .accessibilityLabel("Previous result")
                    .disabled(navigation.matches.isEmpty)
                Button { focused = false; navigation.move(1, inSource: inSource) } label: { IconTarget(symbol: "chevron.down") }
                    .accessibilityLabel("Next result")
                    .disabled(navigation.matches.isEmpty)
                Button { focused = false; navigation.closeFind() } label: {
                    Text("Done").frame(minHeight: 44).padding(.horizontal, 6).contentShape(Rectangle())
                }
                // Offline Files needs a native cancel binding ahead of its sheet's dismissal.
                // The live reader already has the root's priority Escape command.
                .keyboardShortcut(offlineKeyboardScope != nil && !isCovered ? .cancelAction : nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background {
            FindCancelResponder(request: navigation.findKeyboardRestoreRequest, enabled: !isCovered) {
                navigation.closeFind()
            }
        }
        .onAppear { focused = !isCovered }
        .onChange(of: navigation.findFocusRequest) { _, _ in focused = !isCovered }
        // iPad apps on Mac can leave this hidden field first responder under Headings.
        // Its responder chain then bypasses the covering sheet and takes Escape underneath it.
        // The presenting reader restores a native responder after the sheet's dismissal.
        .onChange(of: isCovered) { _, covered in if covered { focused = false } }
        // Closing Find removes the focused field, which hides the keyboard, and UIKit animates
        // every change made while it hides. Animations it started on this bar's layers never
        // reported stopping once the bar had gone, and XCTest then waited a minute before each
        // step. The bar goes at once instead; see "Idle waits after Find closes" in docs/CI_HISTORY.md.
        .transition(.identity)
        .transaction { $0.animation = nil }
    }
    private var statusText: some View {
        Text(status).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
            .contentTransition(.numericText())
            .accessibilityIdentifier("reader-find-status")
            .accessibilityAddTraits(.updatesFrequently)
    }
    private var status: String {
        if navigation.query.isEmpty { return " " }
        if navigation.searching { return "Searching…" }
        if navigation.matches.isEmpty { return "No results" }
        return "\(navigation.selected + 1) of \(navigation.matches.count)\(navigation.truncated ? "+" : "")"
    }
}

/// Restores keyboard handling after a sheet without relying on a stale SwiftUI FocusState.
/// It lives inside Find, so Escape reaches it before the containing presentation's cancel action.
struct FindCancelResponder: UIViewRepresentable {
    let request: Int
    let enabled: Bool
    let cancel: () -> Void

    func makeUIView(context: Context) -> KeyView { KeyView() }
    func updateUIView(_ view: KeyView, context: Context) {
        view.cancel = enabled ? cancel : nil
        if !enabled { view.resignFirstResponder() }
        if view.request != request {
            view.request = request
            if request > 0 && enabled { view.becomeFirstResponder() }
        }
    }

    final class KeyView: UIView {
        var request = 0
        var cancel: (() -> Void)?
        override var canBecomeFirstResponder: Bool { cancel != nil }
        override var keyCommands: [UIKeyCommand]? {
            guard cancel != nil else { return nil }
            let key = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFind(_:)))
            key.wantsPriorityOverSystemBehavior = true
            return [key]
        }
        @objc func closeFind(_ sender: Any?) { cancel?() }
    }
}

/// Find, the document's reading modes and Headings, within reach of a thumb, in one place for
/// connected and offline readers.
struct ReaderBottomBar: ToolbarContent {
    let findTitle: String
    let find: () -> Void
    var headings: (() -> Void)?
    /// Nil for a document with only one way to read it.
    var source: Binding<Bool>?
    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button(findTitle, systemImage: "magnifyingglass", action: find)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if let source {
            ToolbarItem(placement: .bottomBar) { ReadingModePicker(source: source).fixedSize() }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        if let headings {
            ToolbarItem(placement: .bottomBar) {
                Button("Headings", systemImage: "list.bullet.indent", action: headings)
            }
        }
    }
}

/// The reading modes as a segmented control that never writes an old mode back.
/// UIKit moves a segmented control's selection when the touch ends, and sends its action only after
/// the next Core Animation commit. SwiftUI's segmented `Picker` writes its binding's value to the
/// control on every update, so a reader update arriving in between put the old mode back and the
/// tap did nothing. This writes only a mode that changed elsewhere.
private struct ReadingModePicker: UIViewRepresentable {
    @Binding var source: Bool

    func makeCoordinator() -> Coordinator { Coordinator(source: $source) }
    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: ["Rendered", "Source"])
        control.selectedSegmentIndex = source ? 1 : 0
        control.addTarget(context.coordinator, action: #selector(Coordinator.selectionChanged(_:)), for: .valueChanged)
        return control
    }
    func updateUIView(_ control: UISegmentedControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.source = $source
        guard coordinator.synchronized != source else { return }
        coordinator.synchronized = source
        control.selectedSegmentIndex = source ? 1 : 0
    }

    @MainActor final class Coordinator: NSObject {
        var source: Binding<Bool>
        /// The mode the control last took from the reader or gave to it.
        var synchronized: Bool
        init(source: Binding<Bool>) {
            self.source = source
            synchronized = source.wrappedValue
        }
        @objc func selectionChanged(_ control: UISegmentedControl) {
            synchronized = control.selectedSegmentIndex == 1
            source.wrappedValue = synchronized
        }
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
                    Text(heading.title)
                        .font(heading.level == 1 ? .body.weight(.semibold) : .body)
                        .foregroundStyle(heading.level > 2 ? .secondary : .primary)
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 14)
                }
                .accessibilityLabel("\(heading.title), heading level \(heading.level)")
            }
            .listStyle(.plain)
            .navigationTitle("Headings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
