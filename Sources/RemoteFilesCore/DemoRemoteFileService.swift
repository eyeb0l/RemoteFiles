import Foundation

/// Deliberate demo/test service; never selected after a real connection fails.
public actor DemoRemoteFileService: RemoteFileService {
    public var delayNanoseconds: UInt64
    public var failure: String?
    private var generation = 0
    public init(delayNanoseconds: UInt64 = 180_000_000, failure: String? = nil) {
        self.delayNanoseconds = delayNanoseconds; self.failure = failure
    }
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
        if path == "/Projects/Thousand files" {
            return DirectorySnapshot(path: path, entries: (1...1000).map { RemoteEntry(name: "Report \($0).md", path: path + "/Report \($0).md", kind: .file, size: 8192) })
        }
        let entries: [RemoteEntry] = [
            .init(name: "Reports", path: path + "/Reports", kind: .directory),
            .init(name: "Empty", path: path + "/Empty", kind: .directory),
            .init(name: "Thousand files", path: path + "/Thousand files", kind: .directory),
            .init(name: "Example.swift", path: path + "/Example.swift", kind: .file, size: UInt64(Self.sourceExample.utf8.count)),
            .init(name: "Weekly review.md", path: path + "/Weekly review.md", kind: .file, size: UInt64(Self.report.utf8.count), modifiedAt: Date(timeIntervalSince1970: 1790035200)),
            .init(name: "Notes — 東京.txt", path: path + "/Notes — 東京.txt", kind: .file, size: 92),
            .init(name: ".config", path: path + "/.config", kind: .file, size: 18),
            .init(name: "Latest report", path: path + "/Latest report", kind: .symlink),
            .init(name: "Archive.zip", path: path + "/Archive.zip", kind: .file, size: 804892),
            .init(name: "Empty.txt", path: path + "/Empty.txt", kind: .file, size: 0),
            .init(name: "Binary.txt", path: path + "/Binary.txt", kind: .file, size: 3),
            .init(name: "Too large.md", path: path + "/Too large.md", kind: .file, size: 3_000_000)
        ]
        return DirectorySnapshot(path: path, entries: entries)
    }
    public func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        try await pause()
        if path.hasSuffix("Too large.md") { throw RemoteFileError.tooLarge(limit) }
        if path.hasSuffix("Binary.txt") { return Data([0, 0xff, 0]) }
        if path.hasSuffix("Empty.txt") { return Data() }
        let text = path.hasSuffix("Example.swift") ? Self.sourceExample : path.hasSuffix(".md") ? Self.report : "# RemoteFiles configuration\nmode = read-only\n\nSpaces and Unicode: 東京 ✨\n"
        let data = Data(text.utf8)
        guard data.count <= limit else { throw RemoteFileError.tooLarge(limit) }
        return data
    }
    public func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        try await pause()
        return RemoteEntry(name: "Weekly review.md", path: RemotePath.parent(of: path) + "/Weekly review.md", kind: .file)
    }
    public func disconnect() { generation += 1 }
    public static let sourceExample = """
    import Foundation

    // Keep remote files within reach. 東京 ✨
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
