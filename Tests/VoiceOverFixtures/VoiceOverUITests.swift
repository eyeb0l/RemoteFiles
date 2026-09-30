import XCTest

@MainActor final class VoiceOverChecks: XCTestCase {
    private var originalVoiceOver = false
    private var service: XCUIVoiceOverService { XCUIDevice.shared.voiceOverService }
    override func setUpWithError() throws {
        continueAfterFailure = true
        originalVoiceOver = service.isEnabled
        addTeardownBlock { [originalVoiceOver] in
            let service = XCUIDevice.shared.voiceOverService
            if originalVoiceOver { try service.enable() } else { try service.disable() }
            XCTAssertEqual(service.isEnabled, originalVoiceOver)
            print("VO TEARDOWN RESTORED enabled=\(service.isEnabled), original=\(originalVoiceOver)")
        }
    }
    private func withVoiceOver(_ body: () throws -> Void) throws {
        let original = service.isEnabled
        print("VO ORIGINAL enabled=\(original)")
        defer {
            do {
                if original { try service.enable() } else { try service.disable() }
                print("VO RESTORED enabled=\(service.isEnabled), expected=\(original)")
                XCTAssertEqual(service.isEnabled, original)
            } catch { XCTFail("VoiceOver restore failed: \(error)") }
        }
        if !original { try service.enable() }
        try body()
    }
    private func speech(_ name: String, limit: Int = 65) throws -> [String] {
        var result: [String] = []
        let current = try service.currentSpeech().utterance
        print("VO \(name) CURRENT: \(current)")
        result.append(current)
        var duplicates = 0
        for index in 0..<limit {
            let value = try service.moveForward().utterance
            print("VO \(name) \(index): \(value)")
            duplicates = value == result.last ? duplicates + 1 : 0
            result.append(value)
            if duplicates >= 2 { break }
        }
        return result
    }
    private func focus(_ contains: String, name: String, limit: Int = 35) throws {
        var value = try service.currentSpeech().utterance
        var previous = ""
        var duplicates = 0
        for _ in 0..<limit {
            print("VO FOCUS \(name): \(value)")
            if value.localizedCaseInsensitiveContains(contains) { return }
            previous = value
            value = try service.moveForward().utterance
            duplicates = value == previous ? duplicates + 1 : 0
            if duplicates >= 2 { break }
        }
        throw NSError(domain: "VoiceOverTargetNotReached", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not reach \(contains) in bounded \(name) traversal"])
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        print("VO HIERARCHY \(name)\n\(app.debugDescription)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testDemoReaderVoiceOverJourney() throws {
        continueAfterFailure = true
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        try withVoiceOver {
            try focus("Projects", name: "home")
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Mac")).firstMatch.doubleTap()
            let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest report")).firstMatch
            XCTAssertTrue(report.waitForExistence(timeout: 10), app.debugDescription)
            print("VO FOLDER CURRENT: \(try service.currentSpeech().utterance)")
            try focus("Weekly review.md", name: "folder")
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly review.md")).firstMatch.doubleTap()
            XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 10))
            let read = try speech("MARKDOWN")
            capture("VoiceOver rendered report", app)
            XCTAssertTrue(read.contains { $0.contains("A little closer to home") && $0.contains("Heading") })
            XCTAssertTrue(read.contains { $0.contains("Secure connections") })
            XCTAssertFalse(read.contains { $0.contains("Circle") && $0.contains("Image") }, "Decorative bullets must not be accessibility images")
            XCTAssertFalse(read.contains { $0.localizedCaseInsensitiveContains("double-tap to edit") }, "Read-only content must not advertise editing")
            XCTAssertTrue(read.contains { $0.contains("Area: Connection") && $0.contains("Row 2") }, "Table cells must associate content with their column and row")
            XCTAssertTrue(read.contains { $0.contains("A small configuration") && $0.contains("Heading") }, "Traversal must advance past the table")
            XCTAssertTrue(read.contains { $0.contains("Open Apple documentation") && $0.localizedCaseInsensitiveContains("link") })
            // Inspect the link's speech/trait without opening an external page.
            app.buttons["Source"].doubleTap()
            XCTAssertTrue(app.scrollViews["Markdown source"].waitForExistence(timeout: 5))
            let source = try speech("SOURCE", limit: 12)
            XCTAssertFalse(source.contains { $0.localizedCaseInsensitiveContains("double-tap to edit") })
            app.buttons["Rendered"].doubleTap()
            app.buttons["Document actions"].doubleTap()
            _ = try speech("ACTIONS", limit: 12)
            capture("VoiceOver document actions", app)
            app.buttons["Refresh"].doubleTap()
            XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 10))
            print("VO REFRESH CURRENT: \(try service.currentSpeech().utterance)")
            app.navigationBars.buttons["Projects"].doubleTap()
            XCTAssertTrue(report.waitForExistence(timeout: 5))
            print("VO BACK CURRENT: \(try service.currentSpeech().utterance)")
            capture("VoiceOver folder after dismissal", app)
        }
    }
    func testImageViewerFailureRetryShareAndReturn() throws {
        continueAfterFailure = true
        let app = XCUIApplication(); app.launchArguments = ["--voiceover-image-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["Open image diagram.png"].waitForExistence(timeout: 10))
        try withVoiceOver {
            try focus("Open image diagram.png", name: "inline")
            app.buttons["Open image diagram.png"].doubleTap()
            XCTAssertTrue(app.buttons["Tap to retry"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["Share"].isEnabled)
            let errors = try speech("IMAGE ERROR", limit: 15)
            capture("VoiceOver image error", app)
            XCTAssertTrue(errors.contains { $0.contains("Local image fixture unavailable") })
            XCTAssertTrue(errors.contains { $0.contains("Tap to retry") && $0.contains("Button") })
            // VoiceOver supplies traversal/speech; XCTest activates the named control.
            for _ in 0..<8 { _ = try service.moveBackward() }
            try focus("Tap to retry Button", name: "retry")
            app.buttons["Tap to retry"].doubleTap()
            XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 5))
            let deadline = Date().addingTimeInterval(8)
            while !app.buttons["Share"].isEnabled && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertTrue(app.buttons["Share"].isEnabled)
            let image = try speech("IMAGE LOADED", limit: 15)
            capture("VoiceOver image loaded", app)
            print("VO IMAGE DESCRIPTION PRESENT=\(image.contains { $0.localizedCaseInsensitiveContains("purple") || $0.localizedCaseInsensitiveContains("image") })")
            XCTAssertTrue(image.contains { $0.localizedCaseInsensitiveContains("purple") },
                          "Full-screen traversal should expose the image's alt description")
            for _ in 0..<8 { _ = try service.moveBackward() }
            try focus("Share", name: "share")
            app.buttons["Share"].doubleTap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), app.debugDescription)
            _ = try speech("SHARE", limit: 10)
            capture("VoiceOver share sheet", app)
            app.buttons["Close"].doubleTap()
            app.buttons["Done"].doubleTap()
            XCTAssertTrue(app.buttons["Open image diagram.png"].waitForExistence(timeout: 5))
            let returned = try service.currentSpeech().utterance
            print("VO IMAGE RETURN CURRENT: \(returned)")
            capture("VoiceOver image focus return", app)
            XCTAssertTrue(returned.contains("Open image diagram.png"), "Dismissal should return VoiceOver to its invoking image")
        }
    }
    func testTableCellLinkAndFollowingLinkRemainAccessible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--voiceover-table-links-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Local Markdown heading"].waitForExistence(timeout: 10))
        try withVoiceOver {
            let read = try speech("TABLE LINKS", limit: 20)
            capture("VoiceOver table and following links", app)
            XCTAssertTrue(read.contains { $0.contains("Reference: Local cell link") && $0.contains("Row 2") })
            XCTAssertTrue(read.contains { $0.contains("Local cell link") && $0.contains("Link") },
                          "A cell description must preserve the link trait")
            XCTAssertTrue(read.contains { $0.contains("After table link") && $0.contains("Link") })
        }
    }
    func testCachedRefreshingAndFailureSpeech() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--voiceover-stale-fixture", "--voiceover-delayed-fixture"]
        try withVoiceOver {
            app.launch()
            XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 10))
            let refreshing = try speech("REFRESHING", limit: 7)
            capture("VoiceOver cached reader refreshing", app)
            XCTAssertTrue(refreshing.contains { $0.contains("Previously loaded copy") && $0.contains("refreshing") })
            let banner = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Too Large to Preview")).firstMatch
            XCTAssertTrue(banner.waitForExistence(timeout: 18))
            for _ in 0..<8 { _ = try service.moveBackward() }
            let failed = try speech("REFRESH FAILED", limit: 9)
            capture("VoiceOver cached refresh failed", app)
            XCTAssertTrue(failed.contains { $0.contains("Previously loaded copy") && $0.contains("Too Large") })
        }
    }
}
