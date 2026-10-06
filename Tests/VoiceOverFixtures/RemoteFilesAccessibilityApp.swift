import SwiftUI
import UIKit
import RemoteFilesCore
import Crypto
import NIOSSH
@testable import RemoteFilesUI

// Exercise the large-document initial path before VoiceOver turns on, then the
// actual assistive fallback during heading/table/link traversal.
private let largeTableLinkFixture: String = {
    let first = "# Local Markdown heading\n\n| Area | Reference |\n| --- | --- |\n| Reader | [Local cell link](https://example.invalid/cell) |\n\n[After table link](https://example.invalid/after)"
    let tail = (0..<36).map { index in
        "\n\n## Additional section \(index)\n\n" +
        String(repeating: "Long-document selectable prose. ", count: 50) +
        "\n\n```text\n" + String(repeating: "wide_code_", count: 60) + "\n```\n\n" +
        "| Area | Reference |\n| --- | --- |\n| Section \(index) | Additional table content |"
    }.joined()
    let result = first + tail
    precondition(result.utf8.count >= 64 * 1024)
    return result
}()

private actor LocalImageResolver: RemoteResourceResolving {
    let file: URL
    private var calls = 0
    init(file: URL) { self.file = file }
    func localFile(for reference: String, in document: RemoteDocumentLocation) async throws -> URL {
        calls += 1
        print("VO IMAGE resolver call=\(calls)")
        if calls == 2 {
            throw NSError(domain: "VoiceOverFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Local image fixture unavailable. Tap to retry."])
        }
        return file
    }
}

private struct ImageFixture: View {
    let resolver: LocalImageResolver
    let location: RemoteDocumentLocation
    init() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voiceover-diagram.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200))
        let bytes = renderer.pngData { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            ("LOCAL DIAGRAM" as NSString).draw(at: CGPoint(x: 35, y: 90),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.white])
        }
        try! bytes.write(to: file)
        resolver = LocalImageResolver(file: file)
        let profile = ConnectionProfile(name: "Local fixture", host: "fixture.invalid", username: "fixture",
                                        identityID: UUID(), startingDirectory: "/fixture")
        location = .init(profile: profile, path: "/fixture/report.md")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading) {
                    Text("Local image accessibility check").accessibilityAddTraits(.isHeader)
                    RemoteInlineImage(reference: "diagram.png", alt: "Purple local project diagram",
                                      location: location, resolver: resolver, viewportHeight: 900)
                    Text("End of local image fixture")
                }.padding()
            }.coordinateSpace(name: "readerViewport")
                .navigationTitle("Image fixture")
        }
    }
}

private actor ImageExistenceFixtureService: RemoteFileService {
    let exists: Bool
    init(exists: Bool) { self.exists = exists }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        if !exists { throw RemoteFileError.notFound }
        return .init(name: RemotePath.name(of: path), path: path, kind: .file)
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func disconnect() async {}
}

private struct MissingImageFixture: View {
    let resolver: RemoteResourceResolver
    let location: RemoteDocumentLocation
    init() {
        let profile = ConnectionProfile(name: "Moved audit fixture", host: "fixture.invalid", username: "fixture", identityID: UUID())
        location = .init(profile: profile, path: "/new/wardrobe/audit.md")
        resolver = RemoteResourceResolver(
            service: ImageExistenceFixtureService(exists: ProcessInfo.processInfo.arguments.contains("--image-exists")),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    var body: some View {
        NavigationStack {
            DocumentContentView(text: "# Moved audit\n\n![Audit screenshot](/old/wardrobe/02-item-before.png)",
                                markdown: true, source: false, filename: "audit.md", location: location, resolver: resolver)
                .navigationTitle("audit.md")
        }
    }
}

private struct StaleReaderFixture: View {
    @State private var model: AppModel?
    var body: some View {
        Group {
            if let model, let profile = model.metadata.connections.first {
                NavigationStack {
                    ReaderView(model: model, profile: profile,
                        entry: .init(name: "Too large.md", path: "/Projects/Too large.md", kind: .file))
                }
            } else { ProgressView("Preparing local cached fixture") }
        }.task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let value = try! AppModel(directory: directory)
            await value.setDemo(true)
            let profile = value.metadata.connections[0]
            value.cache(Data("# Cached local report\n\nPreviously loaded report text.".utf8),
                        id: profile.id, path: "/Projects/Too large.md")
            if ProcessInfo.processInfo.arguments.contains("--voiceover-delayed-fixture"),
               let service = value.service as? CoalescingFileService,
               let demo = Mirror(reflecting: service).children.first(where: { $0.label == "base" })?.value as? DemoRemoteFileService {
                // Reuse the preceding reader probe's immutable fixture-actor lookup.
                await demo.configure(delayNanoseconds: 15_000_000_000, failure: nil)
            }
            model = value
        }
    }
}

@main struct RemoteFilesApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--small-features-fixture") { SmallFeatureFixture() }
            else if ProcessInfo.processInfo.arguments.contains("--missing-image-fixture") { MissingImageFixture() }
            else if ProcessInfo.processInfo.arguments.contains("--voiceover-image-fixture") { ImageFixture() }
            else if ProcessInfo.processInfo.arguments.contains("--voiceover-stale-fixture") { StaleReaderFixture() }
            else if ProcessInfo.processInfo.arguments.contains("--voiceover-table-links-fixture") {
                NavigationStack {
                    DocumentContentView(text: largeTableLinkFixture, markdown: true, source: false)
                        .navigationTitle("Local Markdown fixture")
                        .onAppear { print("VO LARGE fixture bytes=\(largeTableLinkFixture.utf8.count), actual_voiceover=\(UIAccessibility.isVoiceOverRunning)") }
                }
            }
            else { RemoteFilesRootView() }
        }
    }
}

/// All transports here are mocks. These fixtures never connect to a server or read a private key.
private actor SmallFeatureKeyInstaller: PublicKeyInstalling {
    let directory: URL
    let loseReply: Bool
    let slow: Bool
    private var attempts = 0
    init(directory: URL, loseReply: Bool, slow: Bool) { self.directory = directory; self.loseReply = loseReply; self.slow = slow }
    func install(_ request: PublicKeyInstallationRequest, password: String) async throws -> PublicKeyInstallationResult {
        attempts += 1
        print("FEATURE MOCK install attempt=\(attempts), public-key-only=true")
        if slow { try await Task.sleep(for: .seconds(15)) }
        try Task.checkCancellation()
        let file = directory.appendingPathComponent("mock-installed-public-keys.json")
        var keys = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? []
        if keys.contains(request.publicKey) { return .alreadyInstalled }
        keys.append(request.publicKey); try JSONEncoder().encode(keys).write(to: file, options: .atomic)
        if loseReply && attempts == 1 { throw PublicKeyInstallationError.uncertainOutcome }
        return .installed
    }
    func cancelAll() { print("FEATURE MOCK key cancellation") }
}

private actor SmallFeatureFileService: RemoteFileService {
    let base = DemoRemoteFileService(delayNanoseconds: 0)
    let slow: Bool
    private var generation = 0
    init(slow: Bool) { self.slow = slow }
    private func delay(_ path: String) async throws {
        let before = generation
        if slow && path != "/Projects" {
            print("FEATURE MOCK blocked nested request")
            try await Task.sleep(for: .seconds(15))
        }
        try Task.checkCancellation()
        guard before == generation else { throw CancellationError() }
    }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot {
        try await delay(path); return try await base.listDirectory(profile: profile, path: path)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data {
        try await delay(path); return try await base.readFile(profile: profile, path: path, limit: limit)
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        try await delay(path); return try await base.resolveEntry(profile: profile, path: path)
    }
    func disconnect() { generation += 1; print("FEATURE MOCK disconnected") }
}

private struct SmallFeatureFixture: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel?
    var body: some View {
        Group {
            if let model { AppNavigation(model: model) }
            else { ProgressView("Preparing local feature fixtures…") }
        }
        .task {
            guard model == nil else { return }
            let args = ProcessInfo.processInfo.arguments
            let label = args.first(where: { $0.hasPrefix("--feature-case=") })?.dropFirst("--feature-case=".count) ?? "default"
            let safe = String(label).replacingOccurrences(of: "[^a-zA-Z0-9-]", with: "", options: .regularExpression)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteFilesFeatureFixture-" + safe)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
            let details = try! HostKeyDetails(publicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
            let identity = IdentityMetadata(id: UUID(uuidString: "F1000000-0000-0000-0000-000000000001")!, name: "Fixture Public Identity",
                publicKey: details.publicKey, fingerprint: details.fingerprint, requiresPassphrase: false, keychainReference: "never-read")
            let profile = ConnectionProfile(id: UUID(uuidString: "F2000000-0000-0000-0000-000000000001")!, name: "Fixture Mac", host: "fixture.invalid",
                username: "fixture", identityID: identity.id, startingDirectory: "/Projects")
            let value = try! AppModel(directory: directory,
                fileService: CoalescingFileService(base: SmallFeatureFileService(slow: args.contains("--feature-slow-read"))),
                publicKeyInstaller: SmallFeatureKeyInstaller(directory: directory, loseReply: args.contains("--feature-lost-reply"), slow: args.contains("--feature-slow-install")))
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-v1.json").path) {
                var metadata = AppMetadata(); metadata.connections = [profile]; metadata.identities = [identity]
                metadata.favourites = [.init(connectionID: profile.id, path: "/Projects", name: "Projects")]
                metadata.recents = [.init(id: UUID(uuidString: "F3000000-0000-0000-0000-000000000001")!, connectionID: profile.id,
                    path: "/Projects/Weekly review.md", name: "Weekly review.md")]
                try! await value.metadataStore.save(metadata)
            }
            await value.load(); model = value
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model?.isForeground = false; Task { await model?.background() } }
            if phase == .active { model?.isForeground = true; model?.sessionRevision += 1 }
        }
    }
}
