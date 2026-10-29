#if os(iOS)
import SwiftUI
import RemoteFilesCore

struct SearchOptionsControls: View {
    @Binding var options: SearchQueryOptions
    var body: some View {
        Toggle("Match Case", isOn: $options.caseSensitive)
        Toggle("Whole Words", isOn: $options.wholeWord)
        Picker("File Type", selection: $options.fileExtension) {
            Text("All Supported Types").tag("")
            Text("Markdown (.md)").tag("md")
            Text("Text (.txt)").tag("txt")
            Text("PDF (.pdf)").tag("pdf")
            Text("PNG (.png)").tag("png")
            Text("JPEG (.jpg)").tag("jpg")
        }
    }
}

/// An explicit local snapshot, separate from live folder search and its freshness guarantees.
struct SearchIndexView: View {
    let model: AppModel
    let profile: ConnectionProfile
    let root: String
    let includeHidden: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: SearchIndexSnapshot?
    @State private var query = ""
    @State private var options = SearchQueryOptions()
    @State private var extraction = SearchExtractionOptions(includePDF: true)
    @State private var results: [RemoteFolderSearch.ContentMatch] = []
    @State private var error: String?
    @State private var building = false
    @State private var buildRevision = 0
    @State private var indexRevision = 0
    @State private var buildSession = 0
    @State private var progress = RemoteFolderSearch.Update()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(root).font(.caption).textSelection(.enabled)
                    if let snapshot {
                        Text("Saved \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.documents.count) files")
                            .accessibilityIdentifier("saved-search-index-date")
                        Text(snapshot.isPartial ? "Partial index. Some files or pages were skipped or a limit was reached." : "Snapshot of supported files at build time.")
                        Text("Remote files may have changed. Rebuild to refresh. Opening a result reads the current remote file.")
                        Text("PDF text: \(snapshot.extraction.includePDF ? "included" : "off") · OCR: \(snapshot.extraction.includeOCR ? "included" : "off") · Hidden files: \(snapshot.includeHidden ? "included" : "excluded")")
                    } else {
                        Text("Build an index to search saved text without rereading remote files. Extracted text stays on this device until removed or evicted by storage limits.")
                    }
                }.font(.footnote).foregroundStyle(.secondary)
                Section("Build Options") {
                    Toggle("Include PDF Text", isOn: $extraction.includePDF)
                    Toggle("Recognize Text in Images and Scans", isOn: $extraction.includeOCR)
                    Text("Up to 500 files, 2 MB per file, 16 MB transferred, 20 pages per PDF and 30 seconds to schedule work. Hidden files follow the folder setting. OCR runs on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                    if building {
                        ProgressView("Indexing… \(progress.filesSearched) files checked")
                        Button("Cancel Build", role: .cancel) { building = false; buildRevision += 1 }
                    } else {
                        Button(snapshot == nil ? "Build Index" : "Rebuild Index") { buildSession = model.sessionRevision; building = true; buildRevision += 1 }
                            .disabled(!model.isForeground || model.isDisconnecting)
                        if snapshot != nil || error != nil {
                            Button("Delete Index", role: .destructive) { Task { await removeIndex() } }
                        }
                    }
                }
                Section("Search Options") { SearchOptionsControls(options: $options) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section("Matches in Saved Text") {
                    if !query.isEmpty && results.isEmpty { Text("No matches in this index.").foregroundStyle(.secondary) }
                    ForEach(results, id: \.entry.path) { match in
                        Button {
                            dismiss()
                            // The reader rechecks the canonical search root when fetching current bytes.
                            let entry = RemoteEntry(name: match.entry.name, path: match.entry.path, kind: .file,
                                size: match.entry.size, modifiedAt: match.entry.modifiedAt, canonicalRoot: root)
                            model.openInWorkspace(.file(profile.id, entry))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(match.entry.name)
                                Text(match.entry.path).font(.caption).foregroundStyle(.secondary)
                                Text((match.page.map { "Page \($0)" } ?? "Line \(match.line)") + " · " + match.snippet)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("saved-search-result-" + match.entry.path)
                    }
                }
            }
            .accessibilityIdentifier("saved-search-index-list")
            .navigationTitle("Saved Search Index")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search saved contents")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: model.sessionRevision) { _, _ in
                building = false; results = []; snapshot = nil; dismiss()
            }
            .task(id: model.isForeground) {
                if model.isForeground { await loadIndex() }
                else { snapshot = nil; results = [] }
            }
            .task(id: "\(buildRevision)-\(model.isForeground)-\(model.sessionRevision)") { await buildIndex() }
            .task(id: "\(query)-\(options)-\(indexRevision)-\(model.isForeground)") { await searchIndex() }
        }
    }

    private func loadIndex() async {
        do {
            let saved = try await model.searchIndexStore().load(profile: profile, root: root)
            try Task.checkCancellation()
            snapshot = saved; indexRevision += 1
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func buildIndex() async {
        guard building else { return }
        guard model.isForeground, !model.isDisconnecting, buildSession == model.sessionRevision else { building = false; return }
        let revision = model.sessionRevision, build = buildRevision
        error = nil; progress = .init()
        do {
            let store = await model.searchIndexStore()
            let generation = try await store.beginBuild(profile: profile, root: root)
            let snapshot = try await RemoteFolderSearch.buildIndex(below: root, profile: profile,
                service: model.searchService, includeHidden: includeHidden, extraction: extraction) { update in
                Task { @MainActor in
                    guard building, buildRevision == build, model.sessionRevision == revision else { return }
                    progress = update
                }
            }
            try Task.checkCancellation()
            guard model.sessionRevision == revision, model.isForeground else { return }
            try await store.save(snapshot, profile: profile, root: root, generation: generation)
            try Task.checkCancellation()
            self.snapshot = snapshot; indexRevision += 1
        } catch {
            if !Task.isCancelled && !(error is CancellationError) {
                self.error = error.localizedDescription
                if model.isSecurityError(error) { dismiss(); model.handle(error, profile: profile) }
            }
        }
        if !Task.isCancelled { building = false }
    }

    private func removeIndex() async {
        do {
            try await model.searchIndexStore().remove(profile: profile, root: root)
            snapshot = nil; results = []; error = nil; indexRevision += 1
        } catch { self.error = error.localizedDescription }
    }

    private func searchIndex() async {
        guard model.isForeground, let snapshot else { results = []; return }
        let query = query, options = options
        do {
            try await Task.sleep(for: .milliseconds(150))
            let worker = Task.detached {
                try RemoteFolderSearch.indexedContents(matching: query, snapshot: snapshot, includeHidden: includeHidden, options: options, root: root)
            }
            let update = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            results = update.contentMatches
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
#endif
