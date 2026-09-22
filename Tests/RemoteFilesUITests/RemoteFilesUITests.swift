import XCTest

@MainActor
final class RemoteFilesUITests: XCTestCase {
    func testBrowseReadRefreshAndReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        // Profiling attaches to a freshly launched process before XCTest drives the journey.
        // Normal test runs still own launch; only the explicit profiling harness reuses it.
        if ProcessInfo.processInfo.environment["REMOTEFILES_PROFILE_EXISTING_APP"] == "1" {
            app.activate()
        } else {
            app.launch()
        }

        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Mac")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest report")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        if !report.isHittable { app.swipeUp() }
        report.tap()
        let rendered = app.scrollViews["Rendered Markdown document"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 15))
        attachScreenshot("Physical reader")

        app.buttons["Source"].tap()
        XCTAssertTrue(app.scrollViews["Markdown source"].waitForExistence(timeout: 5))
        app.buttons["Rendered"].tap()
        XCTAssertTrue(rendered.waitForExistence(timeout: 5))
        app.buttons["Document actions"].tap()
        app.buttons["Refresh"].tap()
        XCTAssertTrue(rendered.waitForExistence(timeout: 10))
        app.navigationBars.buttons["Projects"].tap()
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        attachScreenshot("Physical folder after back")
        app.navigationBars.buttons["RemoteFiles"].tap()
        XCTAssertTrue(projects.waitForExistence(timeout: 5))
    }

    func testNormalLaunchOffersUsableConnectionSetup() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let add = app.buttons["Add Connection"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        XCTAssertTrue(add.isHittable)
        XCTAssertLessThan(add.frame.height, 150, "The setup action must not expand into an unreadable vertical capsule.")
        attachScreenshot("Physical normal Home")
        add.tap()
        XCTAssertTrue(app.textFields["Hostname or IP address"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// Explicitly opted-in hardware acceptance; never changes saved connections in ordinary runs.
@MainActor
final class RealServerUITests: XCTestCase {
    private let keyName = "RemoteFiles iPhone - MacBook"
    private func enabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REMOTEFILES_REAL_SERVER"] == "1", "Explicit real-server setup required")
        continueAfterFailure = false
    }

    func testPreparePublicIdentity() throws {
        try enabled()
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons["SSH Keys"].tap()
        let existing = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", keyName)).firstMatch
        if existing.waitForExistence(timeout: 2) {
            existing.tap()
        } else {
            try XCTUnwrap(app.buttons.matching(identifier: "Generate Key").allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
            let name = app.textFields.firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap(); name.typeText(keyName)
            try XCTUnwrap(app.buttons.matching(identifier: "Generate Key").allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        }
        let publicKey = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 ")).firstMatch
        XCTAssertTrue(publicKey.waitForExistence(timeout: 10))
        print("REMOTEFILES_PUBLIC_KEY=\(publicKey.label)")
    }
}


extension RealServerUITests {
    func testRealServerBrowseAndRefresh() throws {
        try enabled()
        let env = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(env["REMOTEFILES_REAL_HOST"])
        let username = try XCTUnwrap(env["REMOTEFILES_REAL_USER"])
        let directory = try XCTUnwrap(env["REMOTEFILES_REAL_DIRECTORY"])
        let fingerprint = try XCTUnwrap(env["REMOTEFILES_REAL_FINGERPRINT"])
        let app = XCUIApplication()
        app.launch()
        let connectionName = "My MacBook"
        let connection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", connectionName + ",")).firstMatch
        if !connection.waitForExistence(timeout: 2) {
            app.buttons["Add Connection"].tap()
            for (label, value) in [("Display name", connectionName), ("Hostname or IP address", host), ("Mac account username", username), ("Starting directory (optional)", directory)] {
                let field = app.textFields[label]
                if !field.isHittable { app.swipeUp() }
                field.tap(); field.typeText(value)
            }
            let tailscale = app.switches["Connect through Tailscale"]
            if !tailscale.isHittable { app.swipeUp() }
            if tailscale.value as? String == "0" { tailscale.tap() }
            app.buttons["Save"].tap()
        }
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        connection.tap()
        let trust = app.buttons["Trust & Connect"]
        if trust.waitForExistence(timeout: 12) {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fingerprint)).firstMatch.exists,
                          "Host fingerprint must match the independently read Mac host key")
            trust.tap()
        }
        let fixtures = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixtures,")).firstMatch
        XCTAssertTrue(fixtures.waitForExistence(timeout: 20), app.debugDescription)
        if !fixtures.isHittable { app.swipeUp() }
        fixtures.tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Live-server-report.md,")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10), app.debugDescription)
        report.tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 10))
        let first = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "initial connection")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Real server rendered report"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["Source"].tap()
        XCTAssertTrue(app.scrollViews["Markdown source"].waitForExistence(timeout: 5))
        print("REMOTEFILES_READY_FOR_SERVER_UPDATE")
        let updated = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "updated on the real Mac")).firstMatch
        for _ in 0..<10 {
            app.buttons["Document actions"].tap()
            app.buttons["Refresh"].tap()
            if updated.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(updated.exists, "Refresh must fetch the changed real-server bytes")
        app.buttons["Rendered"].tap()
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
        let refreshed = XCTAttachment(screenshot: app.screenshot()); refreshed.name = "Real server refreshed report"; refreshed.lifetime = .keepAlways; add(refreshed)
        app.navigationBars.buttons["Fixtures"].tap()
        XCTAssertTrue(report.waitForExistence(timeout: 5))
    }
}


extension RealServerUITests {
    func testSavedConnectionReopensRealProject() throws {
        try enabled()
        let app = XCUIApplication()
        app.launch()
        let connection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "My MacBook,")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        connection.tap()
        let docs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "docs,")).firstMatch
        XCTAssertTrue(docs.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Folder actions"].tap()
        if app.buttons["Add Favourite"].exists { app.buttons["Add Favourite"].tap() }
        else { app.tap() }
        docs.tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "READER_PERFORMANCE.md,")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        if !report.isHittable { app.swipeUp() }
        report.tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 10))
        let heading = app.staticTexts["Cold-reader performance investigation"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Real project report over SFTP"; capture.lifetime = .keepAlways; add(capture)
    }
}
