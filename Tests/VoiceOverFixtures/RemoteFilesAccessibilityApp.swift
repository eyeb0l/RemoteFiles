import SwiftUI
import UIKit
import RemoteFilesCore
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
            if ProcessInfo.processInfo.arguments.contains("--voiceover-image-fixture") { ImageFixture() }
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
