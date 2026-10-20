#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import RemoteFilesUI

/// Records each laid-out line as the source character offsets of its glyphs.
private final class TextLayoutRecord: @unchecked Sendable {
    var lines: [[Int]] = []
    var glyphs: Int { lines.reduce(0) { $0 + $1.count } }
}

private struct RecordingRenderer: TextRenderer {
    let record: TextLayoutRecord
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let origin = layout.first?.first?.characterIndices.first
        record.lines = layout.map { line in
            line.flatMap { run in run.characterIndices.compactMap { origin?.distance(to: $0) } }
        }
        for line in layout { for run in line { context.draw(run) } }
    }
}

@MainActor final class FingerprintWrapTests: XCTestCase {
    private let fingerprints = [
        "SHA256:asy6YpBUXdt6O1ZXiAw0IfDubhvPYjO9r3PCCcJsJz8",
        "SHA256:R9yiNYD4WMHbkqZqFo9FFes0LR2pwTOGk0kivWJGoU0"
    ]
    private let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl RemoteFiles"

    private func layout(_ view: some View, width: CGFloat, size: DynamicTypeSize) async throws -> TextLayoutRecord {
        let record = TextLayoutRecord()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width + 40, height: 800)
        window.rootViewController = UIHostingController(rootView: view
            .textRenderer(RecordingRenderer(record: record))
            .environment(\.dynamicTypeSize, size)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let deadline = ContinuousClock.now + .seconds(5)
        while record.lines.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(record.lines.isEmpty, "Text was never drawn")
        return record
    }

    /// A glyph that maps to no new character is one the layout added, such as a hyphen at a break.
    private func assertNoInsertedGlyphs(_ record: TextLayoutRecord, value: String, _ context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(record.lines.count, 1, "\(context) must wrap for this check to mean anything", file: file, line: line)
        let drawn = record.lines.flatMap { $0 }
        XCTAssertEqual(drawn.count, Set(drawn).count, "\(context) repeats a character index where a line wraps: \(record.lines)", file: file, line: line)
        XCTAssertLessThanOrEqual(drawn.count, value.count, "\(context) draws more glyphs than characters", file: file, line: line)
    }

    func testPlainMonospacedTextHyphenatesWrappedFingerprints() async throws {
        // Guards this suite's sensitivity: if iOS stops hyphenating here, the checks below prove nothing.
        let value = fingerprints[0]
        let record = try await layout(Text(verbatim: value).font(.footnote.monospaced()), width: 120, size: .large)
        XCTAssertGreaterThan(record.lines.count, 1)
        XCTAssertGreaterThan(record.glyphs, value.count, "Expected iOS to insert a hyphen glyph at each wrap")
    }

    func testWrappedFingerprintsAddNoHyphen() async throws {
        for value in fingerprints {
            for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
                for width in [120.0, 200.0, 250.0] {
                    let record = try await layout(FingerprintView(value: value), width: width, size: size)
                    assertNoInsertedGlyphs(record, value: value, "\(value) at \(width) pt, \(size)")
                    XCTAssertEqual(record.glyphs, value.count, "\(value) at \(width) pt, \(size) dropped or added glyphs")
                }
            }
        }
    }

    func testWrappedPublicKeyAddsNoHyphen() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            for width in [120.0, 250.0] {
                let record = try await layout(PublicKeyText(value: publicKey), width: width, size: size)
                assertNoInsertedGlyphs(record, value: publicKey, "Public key at \(width) pt, \(size)")
            }
        }
    }
}
#endif
