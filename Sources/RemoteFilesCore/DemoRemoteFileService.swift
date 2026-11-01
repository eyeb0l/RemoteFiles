import Foundation

/// Deliberate demo/test service; never selected after a real connection fails.
public actor DemoRemoteFileService: RemoteFileService {
    public var delayNanoseconds: UInt64
    public var failure: String?
    private var generation = 0
    public init(delayNanoseconds: UInt64 = 180_000_000, failure: String? = nil) {
        self.delayNanoseconds = delayNanoseconds; self.failure = failure
    }
    public static let richMarkdown = #"""
    # Rich Markdown

    Diagrams, equations and static HTML render locally. Source keeps the original text.

    ## Mermaid diagram

    ```mermaid
    flowchart LR
        A[Choose a server] --> B[Verify host key]
        B --> C[Browse files]
        C --> D[Download a copy]
    ```

    ## Mathematical notation

    Inline math: $E = mc^2$.

    $$
    \int_0^1 x^2\,dx = \frac{1}{3}
    $$

    ## Embedded HTML

    <details><summary>Read the preview notes</summary><p>Local <strong>static HTML</strong> supports rich document structure.</p></details>

    <table><thead><tr><th>Feature</th><th>Rendering</th></tr></thead><tbody><tr><td>Diagrams</td><td>Mermaid</td></tr><tr><td>Equations</td><td>KaTeX</td></tr></tbody></table>

    [Open the navigation guide](Navigation%20guide.md) or [return to the diagram](#mermaid-diagram).
    """#

    public func configure(delayNanoseconds: UInt64, failure: String?) {
        self.delayNanoseconds = delayNanoseconds; self.failure = failure
    }
    private func pause() async throws {
        let token = generation
        try await Task.sleep(nanoseconds: delayNanoseconds)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        if let failure { throw RemoteFileError.unavailable(failure) }
    }
    public func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        try await pause()
        let path = path == "." ? "/Projects" : path
        if path == "/Projects/Empty" { return DirectorySnapshot(path: path, entries: []) }
        if path == Self.searchSampleFolder {
            return DirectorySnapshot(path: path, entries: Self.searchSampleNames.compactMap {
                Self.searchSampleEntry(path + "/" + $0)
            })
        }
        // Reports and its subfolder are finite, so searching subfolders ends.
        if path.hasSuffix("/Reports") {
            return DirectorySnapshot(path: path, entries: [
                .init(name: "2026", path: path + "/2026", kind: .directory),
                .init(name: "Linked notes.md", path: path + "/Linked notes.md", kind: .file, size: UInt64(Self.linkedNotes.utf8.count)),
                .init(name: "Heading notes.md", path: path + "/Heading notes.md", kind: .file, size: UInt64(Self.headingNotes.utf8.count)),
                .init(name: "Weekly review.md", path: path + "/Weekly review.md", kind: .file, size: UInt64(Self.report.utf8.count), modifiedAt: Date(timeIntervalSince1970: 1790035200))
            ])
        }
        if path.hasSuffix("/Reports/2026") {
            return DirectorySnapshot(path: path, entries: [
                .init(name: "Quarterly review.md", path: path + "/Quarterly review.md", kind: .file, size: UInt64(Self.report.utf8.count), modifiedAt: Date(timeIntervalSince1970: 1790035200)),
                .init(name: "Roadmap notes.md", path: path + "/Roadmap notes.md", kind: .file, size: UInt64(Self.report.utf8.count))
            ])
        }
        if path == Self.thousandFilesFolder {
            return DirectorySnapshot(path: path, entries: (1...1000).map { RemoteEntry(name: "Report \($0).md", path: path + "/Report \($0).md", kind: .file, size: 8192) })
        }
        var entries: [RemoteEntry] = [
            .init(name: "Reports", path: path + "/Reports", kind: .directory),
            .init(name: "Empty", path: path + "/Empty", kind: .directory),
            .init(name: "Thousand files", path: path + "/Thousand files", kind: .directory),
            .init(name: "Rich Markdown.md", path: path + "/Rich Markdown.md", kind: .file, size: UInt64(Self.richMarkdown.utf8.count)),
            .init(name: "Navigation guide.md", path: path + "/Navigation guide.md", kind: .file, size: UInt64(Self.navigationGuide.utf8.count)),
            .init(name: "Linked notes.md", path: path + "/Linked notes.md", kind: .file, size: UInt64(Self.linkedNotes.utf8.count)),
            .init(name: "Heading notes.md", path: path + "/Heading notes.md", kind: .file, size: UInt64(Self.headingNotes.utf8.count)),
            .init(name: "Example.swift", path: path + "/Example.swift", kind: .file, size: UInt64(Self.sourceExample.utf8.count)),
            .init(name: "Long lines.json", path: path + "/Long lines.json", kind: .file, size: UInt64(Self.longLineJSON.utf8.count)),
            .init(name: "Preview.html", path: path + "/Preview.html", kind: .file, size: UInt64(Self.htmlExample.utf8.count)),
            .init(name: "Icon.svg", path: path + "/Icon.svg", kind: .file, size: UInt64(Self.svgExample.utf8.count)),
            .init(name: "Sample audio.m4a", path: path + "/Sample audio.m4a", kind: .file, size: Self.mediaSize("Sample audio.m4a")),
            .init(name: "Sample video.mp4", path: path + "/Sample video.mp4", kind: .file, size: Self.mediaSize("Sample video.mp4")),
            .init(name: "Weekly review.md", path: path + "/Weekly review.md", kind: .file, size: UInt64(Self.report.utf8.count), modifiedAt: Date(timeIntervalSince1970: 1790035200)),
            .init(name: "Notes — 東京.txt", path: path + "/Notes — 東京.txt", kind: .file, size: 92),
            .init(name: ".config", path: path + "/.config", kind: .file, size: 18),
            .init(name: "Latest report", path: path + "/Latest report", kind: .symlink,
                  link: .target(.init(name: "Weekly review.md", path: path + "/Weekly review.md", kind: .file,
                                      size: UInt64(Self.report.utf8.count), modifiedAt: Date(timeIntervalSince1970: 1790035200)))),
            .init(name: "Current reports", path: path + "/Current reports", kind: .symlink,
                  link: .target(.init(name: "Reports", path: path + "/Reports", kind: .directory))),
            .init(name: "Old notes", path: path + "/Old notes", kind: .symlink, link: .broken),
            .init(name: "Archive.zip", path: path + "/Archive.zip", kind: .file, size: 804892),
            .init(name: "Empty.txt", path: path + "/Empty.txt", kind: .file, size: 0),
            .init(name: "Binary.txt", path: path + "/Binary.txt", kind: .file, size: 3),
            .init(name: "Too large.md", path: path + "/Too large.md", kind: .file, size: 3_000_000)
        ]
        if path == "/Projects" {
            entries.append(.init(name: "Search samples", path: Self.searchSampleFolder, kind: .directory))
        }
        return DirectorySnapshot(path: path, entries: entries)
    }
    public func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        try await pause()
        if let file = Self.searchSampleFile(path) ?? Self.mediaFile(RemotePath.name(of: path)) {
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= limit else { throw RemoteFileError.tooLarge(limit) }
            return bytes
        }
        if path.hasSuffix("Too large.md") { throw RemoteFileError.tooLarge(limit) }
        if path.hasSuffix("Binary.txt") { return Data([0, 0xff, 0]) }
        if path.hasSuffix("Empty.txt") { return Data() }
        let text: String
        if path.hasSuffix("Rich Markdown.md") { text = Self.richMarkdown }
        else if path.hasSuffix("Navigation guide.md") { text = Self.navigationGuide }
        else if path.hasSuffix("Linked notes.md") { text = Self.linkedNotes }
        else if path.hasSuffix("Heading notes.md") { text = Self.headingNotes }
        else if path.hasSuffix("Long lines.json") { text = Self.longLineJSON }
        else if path.hasSuffix("Preview.html") { text = Self.htmlExample }
        else if path.hasSuffix("Icon.svg") { text = Self.svgExample }
        else { text = path.hasSuffix("Example.swift") ? Self.sourceExample : path.hasSuffix(".md") ? Self.report : "# RemoteFiles configuration\nmode = read-only\n\nSpaces and Unicode: 東京 ✨\n" }
        let data = Data(text.utf8)
        guard data.count <= limit else { throw RemoteFileError.tooLarge(limit) }
        return data
    }
    public func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        try await pause()
        if path == "." || path == "/Projects" || path == Self.searchSampleFolder || path == Self.thousandFilesFolder ||
            path.hasSuffix("/Reports") || path.hasSuffix("/Reports/2026") || path.hasSuffix("/Empty") {
            let canonical = path == "." ? "/Projects" : path
            return RemoteEntry(name: RemotePath.name(of: canonical), path: canonical, kind: .directory)
        }
        if let entry = Self.searchSampleEntry(path) { return entry }
        if path.hasSuffix("/Old notes") { throw RemoteFileError.notFound }
        if path.hasSuffix("/Current reports") { return RemoteEntry(name: "Reports", path: RemotePath.parent(of: path) + "/Reports", kind: .directory) }
        return RemoteEntry(name: "Weekly review.md", path: RemotePath.parent(of: path) + "/Weekly review.md", kind: .file)
    }
    public func downloadSnapshotFile(profile: ConnectionProfile, path: String, canonicalRoot: String, destination: URL,
                                     limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        guard RemoteResourcePath.contains(path, in: canonicalRoot),
              !(path.hasSuffix("/Latest report") || path.hasSuffix("/Current reports")) else {
            throw RemoteDocumentLinkError.outsideConnection
        }
        return try await downloadFile(profile: profile, path: path, allowedRoot: canonicalRoot,
                                      destination: destination, limit: limit, progress: progress)
    }
    public func resolveDocumentLink(profile: ConnectionProfile, documentPath: String, reference: String) async throws -> RemoteEntry {
        try await pause()
        let root = profile.startingDirectory == "." ? "/Projects" : profile.startingDirectory
        let path = try RemoteDocumentLinkPath.resolve(reference, relativeTo: documentPath, connectionRoot: root)
        let name = RemotePath.name(of: path)
        let knownFiles = ["Rich Markdown.md", "Navigation guide.md", "Linked notes.md", "Heading notes.md", "Weekly review.md", "Example.swift", "Long lines.json", "Icon.svg", "Sample audio.m4a", "Sample video.mp4", "Notes — 東京.txt", ".config", "Empty.txt", "Binary.txt", "Too large.md"]
        guard knownFiles.contains(name) || Self.mediaFile(name) != nil || Self.searchSampleFile(path) != nil else { throw RemoteFileError.unavailable("The linked file could not be found. Check the link or open its folder.") }
        try Task.checkCancellation()
        return RemoteEntry(name: name, path: path, kind: .file, navigationRoot: root)
    }
    public func readDocumentFile(profile: ConnectionProfile, path: String, allowedRoot: String, limit: Int) async throws -> Data {
        let root = allowedRoot == "." ? "/Projects" : allowedRoot
        let canonical = path.hasSuffix("/Latest report") ? try await resolveEntry(profile: profile, path: path).path : path
        guard RemoteResourcePath.contains(canonical, in: root) else { throw RemoteDocumentLinkError.outsideConnection }
        return try await readFile(profile: profile, path: canonical, limit: limit)
    }
    public func readSearchFile(profile: ConnectionProfile, path: String, canonicalRoot: String, limit: Int) async throws -> Data {
        try await readDocumentFile(profile: profile, path: path, allowedRoot: canonicalRoot, limit: limit)
    }
    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                             destination: URL, limit: Int) async throws -> RemoteEntry {
        try await downloadFile(profile: profile, path: path, allowedRoot: allowedRoot, destination: destination, limit: limit, progress: { _ in })
    }
    public func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String,
                             destination: URL, limit: Int, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        let root = allowedRoot == "." ? "/Projects" : allowedRoot
        let canonical = path.hasSuffix("/Latest report") ? try await resolveEntry(profile: profile, path: path).path : path
        guard RemoteResourcePath.contains(canonical, in: root) else { throw RemoteResourceError.outsideDocument }
        let token = generation
        let bytes = try await readFile(profile: profile, path: canonical, limit: limit)
        try Task.checkCancellation()
        await progress(.init(totalBytes: UInt64(bytes.count)))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let chunkSize = max(1, (bytes.count + 3) / 4)
        for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
            try Task.checkCancellation()
            if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
            guard token == generation else { throw CancellationError() }
            let end = min(bytes.count, offset + chunkSize)
            try handle.write(contentsOf: bytes[offset..<end])
            await progress(.init(receivedBytes: UInt64(end), totalBytes: UInt64(bytes.count)))
        }
        try Task.checkCancellation()
        await progress(.init(receivedBytes: UInt64(bytes.count), totalBytes: UInt64(bytes.count), isComplete: true))
        return RemoteEntry(name: RemotePath.name(of: canonical), path: canonical, kind: .file, size: UInt64(bytes.count))
    }
    public func disconnect() { generation += 1 }

    private static let searchSampleFolder = "/Projects/Search samples"
    private static let thousandFilesFolder = "/Projects/Thousand files"
    private static let searchSampleNames = ["Text sample.pdf", "Scanned sample.pdf", "Image sample.png"]
    private static func searchSampleFile(_ path: String) -> URL? {
        let resource: String
        switch path {
        case searchSampleFolder + "/Text sample.pdf": resource = "search-sample.pdf"
        case searchSampleFolder + "/Scanned sample.pdf": resource = "search-scan.pdf"
        case searchSampleFolder + "/Image sample.png": resource = "search-image.png"
        default: return nil
        }
        return Bundle.module.url(forResource: (resource as NSString).deletingPathExtension,
                                 withExtension: (resource as NSString).pathExtension)
    }
    private static func searchSampleEntry(_ path: String) -> RemoteEntry? {
        guard let url = searchSampleFile(path) else { return nil }
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return RemoteEntry(name: RemotePath.name(of: path), path: path, kind: .file,
                           size: size.map(UInt64.init))
    }

    private static func mediaFile(_ name: String) -> URL? {
        let ext = (name as NSString).pathExtension
        if name == "Sample audio." + ext, ["m4a", "mp3", "wav", "flac", "aiff", "aac"].contains(ext) {
            return Bundle.module.url(forResource: "sample-audio", withExtension: ext)
        }
        if name == "Sample video." + ext, ["mp4", "mov"].contains(ext) {
            return Bundle.module.url(forResource: "sample-video", withExtension: ext)
        }
        return nil
    }
    private static func mediaSize(_ name: String) -> UInt64? {
        guard let url = mediaFile(name), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return UInt64(size)
    }

    /// Long, uniquely labelled sections make back-scroll acceptance observable on screen.
    public static let navigationGuide = "# Navigation guide\n\n[Jump to marker 20](#reading-marker-20)\n\n" + (1...28).map {
        "## Reading marker \($0)\n\nThis is local demo section \($0). Scroll to the links, open a note, and return to this reading position.\n\n"
    }.joined() + """
    ## Navigation return marker

    [Open nested note](Reports/Linked%20notes.md)

    [Open source example](Example.swift)

    [Heading link](Reports/Heading%20notes.md#details)

    [Missing heading](#missing-heading)

    [Missing file](Reports/Missing.md)

    [Outside starting folder](../outside.md)

    [Unsupported archive](Archive.zip)
    """ + "\n"
    public static let linkedNotes = """
    # Linked note marker

    This nested note was opened through a relative document link.

    [Open parent guide](../Navigation%20guide.md)

    [Jump to note heading](#linked-note-marker)

    [Open heading details](Heading%20notes.md#details)

    [Open nested review](2026/Quarterly%20review.md)

    [Missing note](Missing.md)
    """ + "\n"

    public static let headingNotes = "# Heading notes\n\n" + (1...18).map {
        "This is introductory paragraph \($0). Follow the heading link to jump past this introduction.\n\n"
    }.joined() + "## Details\n\nHeading navigation reached the linked details section.\n"

    // Synthetic regressions; no user document content is bundled.
    public static let longLineJSON = "{\n  \"version\": 1,\n  \"prompt\": \"" +
        String(repeating: "Local preview sample 東京 🌍. ", count: 180) + "\",\n  \"ready\": true\n}\n"
    public static let svgExample = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
    <rect width="512" height="512" rx="80" fill="#7047eb"/>
    <path d="M128 160h160v192H128z" fill="#fff"/>
    <path d="M320 160h64v192h-64z" fill="#24b4aa"/>
    </svg>
    """

    public static let sourceExample = """
    import Foundation

    // Keep remote files within reach. 東京 ✨
    // This deliberately long comment demonstrates visual line wrapping in the source reader. Turning Wrap Lines off keeps it on one line so you can scroll sideways to read the end. End of wrapping sample.
    struct Workspace {
        let name = "RemoteFiles"
        let fileLimit = 2_097_152

        func greeting() -> String {
            return "Welcome home"
        }
    }

    let workspace = Workspace()
    print(workspace.greeting())
    """ + "\n"
    public static let report = """
    # A little closer to home

    Weekly project review · 22 September 2026

    A quiet place to read the work your agents have finished. **RemoteFiles** brings the report to you, wherever you are.

    ## This week

    - A native, file-first workspace
    - Secure connections with dedicated SSH keys
    - Clear, readable reports without leaving the app

    > Good tools make the distance disappear.

    ## Delivery checklist

    - [x] Browse project folders
    - [x] Read Markdown and source
    - [ ] Verify on iPhone over cellular

    ## Project pulse

    | Area | Status | Next step |
    | :--- | :--- | :--- |
    | Connection | Ready to test | Verify the host fingerprint |
    | Reading | In progress | Review a real agent report |
    | Access | Read only | Keep your files in place |

    ### A small configuration

    ```swift
    let workspace = "~/Projects/RemoteFiles"
    let intention = "Keep useful documents within reach."
    ```

    1. Open a favourite folder.
    2. Choose the latest report.
    3. Pick up where you left off.

    ---

    Images stay private: ![A project diagram](https://example.invalid/never-requested.png)

    [Open Apple documentation](https://developer.apple.com/documentation/)
    """
}

public extension DemoRemoteFileService {
    static let htmlExample = """
    <!doctype html>
    <html lang="en"><head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>HTML preview</title>
      <style>
        :root { color-scheme: light dark; }
        body { font: 18px -apple-system, sans-serif; padding: 24px; line-height: 1.5; }
        h1 { color: #716cff; } .card { border: 2px solid #716cff; border-radius: 16px; padding: 20px; }
        table { border-collapse: collapse; width: 100%; } td, th { padding: 8px; text-align: left; border-bottom: 1px solid #999; }
      </style>
    </head><body>
      <h1>HTML preview</h1>
      <div class="card"><p>A styled document with <strong>bold text</strong> and Unicode: café 東京 🌍.</p>
      <ul><li>Rendered page</li><li>Original source</li></ul></div>
      <h2>Sample table</h2><table><tr><th>Format</th><th>View</th></tr><tr><td>HTML</td><td>Rendered + Source</td></tr></table>
      <p><a href="https://example.com">External link</a> · <a href="Linked%20notes.md">Linked notes</a></p>
    </body></html>
    """
}
