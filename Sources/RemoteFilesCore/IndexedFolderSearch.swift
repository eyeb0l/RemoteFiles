import Foundation

public extension RemoteFolderSearch {
    /// Builds a bounded, point-in-time snapshot. Callers explicitly save only successful builds;
    /// cancellation and fatal errors leave the previous snapshot intact. No server-side index exists.
    ///
    /// With `previous`, the build still lists every folder, so new files are added and removed
    /// files dropped, but it keeps a previous document's text instead of reading the file again
    /// when the listing reports the same size and modification date. Documents whose extraction
    /// was truncated, or that lack either value, are read again. A previous snapshot built with
    /// other hidden-file or extraction choices is not used. A change that keeps both the size and
    /// the modification date is not detected; a build without `previous` reads every file.
    static func buildIndex(below root: String, profile: ConnectionProfile, service: any RemoteFileService,
                           includeHidden: Bool, limits: Limits = .init(),
                           contentLimits: ContentLimits = .init(maxFileBytes: DocumentPolicy.previewByteLimit),
                           extraction: SearchExtractionOptions = .init(includePDF: true),
                           reusing previous: SearchIndexSnapshot? = nil,
                           report: (Update) -> Void = { _ in }) async throws -> SearchIndexSnapshot {
        var documents: [SearchIndexDocument] = []
        var final = Update()
        // Byte keys keep distinct Unicode spellings of a name apart, as the store does.
        var unchanged: [Data: SearchIndexDocument] = [:]
        if let previous, previous.includeHidden == includeHidden, previous.extraction == extraction {
            for document in previous.documents where document.entry.size != nil && document.entry.modifiedAt != nil {
                // Indexes saved before truncation was recorded are complete only if not partial.
                guard document.isTruncated == false || (document.isTruncated == nil && !previous.isPartial) else { continue }
                unchanged[Data(document.entry.path.utf8)] = document
            }
        }
        let reusable: ((RemoteEntry) -> SearchIndexDocument?)? = unchanged.isEmpty ? nil : { entry in
            guard entry.kind == .file, entry.link == nil, let document = unchanged[Data(entry.path.utf8)],
                  document.entry.size == entry.size, document.entry.modifiedAt == entry.modifiedAt else { return nil }
            return document
        }
        try await search(query: "", root: root, profile: profile, service: service, includeHidden: includeHidden,
                         limits: limits, content: contentLimits, extraction: extraction,
                         collect: { documents.append($0) }, reusable: reusable) { update in
            final = update; report(update)
        }
        try Task.checkCancellation()
        return SearchIndexSnapshot(documents: documents, includeHidden: includeHidden, extraction: extraction,
            isPartial: final.stop != nil || final.skippedDeepFolders > 0 || final.unreadableFolders > 0 ||
                final.skippedFiles > 0 || final.unreadableFiles > 0 || final.truncatedFiles > 0)
    }

    /// Searches saved text only. It intentionally makes no freshness claim and performs no remote IO.
    static func indexedContents(matching query: String, snapshot: SearchIndexSnapshot, includeHidden: Bool,
                                options: SearchQueryOptions = .init(), maxMatches: Int = 500, root: String = "/") throws -> Update {
        var update = Update()
        guard !query.isEmpty else { update.isFinished = true; return update }
        for document in snapshot.documents {
            try Task.checkCancellation()
            let entry = document.entry
            let relative = entry.path.dropFirst(root == "/" ? 1 : root.count + 1)
            guard RemoteResourcePath.contains(entry.path, in: root), options.accepts(entry),
                  includeHidden || !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            update.filesSearched += 1
            for segment in document.segments {
                if let match = firstMatch(in: segment.text, query: query, entry: entry, options: options, page: segment.page) {
                    guard update.contentMatches.count < max(0, maxMatches) else {
                        update.stop = .matchLimit; update.isFinished = true; return update
                    }
                    update.contentMatches.append(match); break
                }
            }
        }
        update.isFinished = true
        return update
    }
}
