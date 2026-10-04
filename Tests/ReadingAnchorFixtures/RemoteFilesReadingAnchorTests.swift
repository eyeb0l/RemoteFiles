import XCTest

/// Dedicated owned-fixture UI lane. Observe the actual RemoteInlineImage button frame;
/// do not use these accessibility queries as rendering-performance instrumentation.
@MainActor final class ReadingAnchorUITests: XCTestCase {
    private func roundTrip(arguments: [String]) throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = arguments; app.launch()
        let rendered = app.scrollViews["Rendered Markdown document"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 15))
        let image = app.buttons["Open image anchor.png"]
        let placeholder = app.staticTexts["anchor.png"]
        for _ in 0..<12 {
            if image.exists { break }
            if placeholder.exists {
                let delta = placeholder.frame.midY - (rendered.frame.minY + 150)
                drag(rendered, by: max(-550, min(550, delta)))
            } else { rendered.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        for _ in 0..<8 {
            let delta = image.frame.midY - (rendered.frame.minY + 60)
            if abs(delta) < 8 { break }
            drag(rendered, by: max(-550, min(550, delta)))
        }
        XCTAssertLessThan(abs(image.frame.midY - (rendered.frame.minY + 60)), 25,
                          "The real image must occupy the viewport anchor point")
        let before = image.frame
        for iteration in 0..<3 {
            app.buttons["Source"].tap()
            XCTAssertTrue(app.scrollViews["Markdown source"].waitForExistence(timeout: 15))
            app.buttons["Rendered"].tap()
            XCTAssertTrue(image.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 1)
            let after = image.frame
            print("IMAGE ANCHOR iteration=\(iteration) before=\(before) after=\(after)")
            XCTAssertEqual(after.minY, before.minY, accuracy: 4)
            XCTAssertEqual(after.height, before.height, accuracy: 2)
        }
    }

    private func drag(_ rendered: XCUIElement, by amount: CGFloat) {
        let start = rendered.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -amount)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
        Thread.sleep(forTimeInterval: 0.25)
    }

    func testVisibleImageReturnsAcrossRepeatedSourceSwitches() throws { try roundTrip(arguments: []) }
    func testImageDominantViewportReturnsAcrossRepeatedSourceSwitches() throws {
        try roundTrip(arguments: ["--tall-image"])
    }
    func testImageAfterDeferredBlocksReturnsAcrossRepeatedSourceSwitches() throws {
        try roundTrip(arguments: ["--preceding-overflow"])
    }
}
