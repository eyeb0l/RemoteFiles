#if os(iOS)
import XCTest
import SwiftUI
import UIKit
@testable import RemoteFilesUI

@MainActor @Observable private final class NoticeProbe {
    var height: CGFloat = -1
}

/// The notice above a source document, as the reader stacks them.
private struct NoticeFixture: View {
    let text: String
    let probe: NoticeProbe
    var body: some View {
        VStack(spacing: 0) {
            DirectionCharacterNotice(text: text)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { probe.height = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in probe.height = height }
                })
            DocumentContentView(text: text, markdown: false, source: true, filename: "access.swift")
        }
    }
}

@MainActor
final class DirectionCharacterNoticeTests: XCTestCase {
    private static let hidden = "func check(isAdmin: Bool) {\n    if isAdmin { /* \u{202E} } \u{2066}begin admins only */ grant() \u{2069} \u{2066}\n    }\n}\n"

    func testANoticeAppearsAboveTextThatHasAReorderingCharacter() async throws {
        let probe = try show(Self.hidden)
        // The count is taken off the main actor; a loaded hosted runner can take seconds to come back.
        let deadline = ContinuousClock.now + .seconds(60)
        while probe.height <= 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(probe.height, 40, "The notice has a title and a line of explanation")
    }

    func testOrdinaryTextHasNoNotice() async throws {
        let ordinary = Self.hidden.unicodeScalars.filter { !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
        let probe = try show(String(String.UnicodeScalarView(ordinary)))
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            XCTAssertLessThanOrEqual(probe.height, 0)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func show(_ text: String) throws -> NoticeProbe {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let probe = NoticeProbe()
        window.rootViewController = UIHostingController(rootView: NoticeFixture(text: text, probe: probe))
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        return probe
    }
}
#endif
