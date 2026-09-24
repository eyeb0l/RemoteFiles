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


extension RealServerUITests {
    func testStandaloneImagePDFAndText() throws {
        try enabled()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REMOTEFILES_FORMAT_FIXTURES"] == "1",
                          "Generate format fixtures in the Image checks SFTP folder first")
        let app = XCUIApplication(); app.launch()
        let connection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Image checks,")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10)); connection.tap()

        func open(_ name: String) {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
            if !row.isHittable { app.swipeUp() }
            row.tap()
        }
        func back() { app.navigationBars.buttons["remote-images"].tap() }

        open("sample.png")
        let image = app.buttons["Open image sample.png full screen"]
        XCTAssertTrue(image.waitForExistence(timeout: 30), app.debugDescription)
        image.tap()
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap(); back()

        open("sample.pdf")
        XCTAssertTrue(app.staticTexts["1 page"].waitForExistence(timeout: 30), app.debugDescription)
        let pdf = XCTAttachment(screenshot: app.screenshot()); pdf.name = "Real SFTP PDF preview"; pdf.lifetime = .keepAlways; add(pdf)
        back()

        open("sample.csv")
        XCTAssertTrue(app.scrollViews["Plain text document"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "name,count")).firstMatch.exists)
    }
}

extension RealServerUITests {
    func testAuditRemoteInlineImages() throws {
        try enabled()
        let app = XCUIApplication(); app.launch()
        let audit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "audit.md,")).firstMatch
        XCTAssertTrue(audit.waitForExistence(timeout: 10), app.debugDescription)
        if !audit.isHittable { app.swipeUp() }
        audit.tap()
        let image = app.buttons["Open image 01-wardrobe-before.png"]
        let placeholder = app.staticTexts["01-wardrobe-before.png"]
        let scroll = app.scrollViews["Rendered Markdown document"]
        for _ in 0..<18 {
            if (image.exists && image.isHittable) || (placeholder.exists && placeholder.isHittable) { break }
            // Stop on the resource row instead of racing past it and cancelling its lazy fetch.
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(image.waitForExistence(timeout: 60), app.debugDescription)
        if !image.isHittable { app.swipeUp() }
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Real audit inline SFTP image"; capture.lifetime = .keepAlways; add(capture)
        image.tap()
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Share"].isEnabled)
        app.pinch(withScale: 2, velocity: 1)
        let full = XCTAttachment(screenshot: app.screenshot()); full.name = "Remote image zoom viewer"; full.lifetime = .keepAlways; add(full)
        app.buttons["Share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5) || app.buttons["Copy"].exists, app.debugDescription)
    }
}


extension RealServerUITests {
    func testRelativeLargeAndMissingImages() throws {
        try enabled()
        let app = XCUIApplication(); app.launch()
        let connection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Image checks,")).firstMatch
        if !connection.waitForExistence(timeout: 2) {
            let add = app.buttons["Add Connection"]
            if !add.isHittable { app.swipeUp() }
            add.tap()
            for (label, value) in [("Display name", "Image checks"), ("Hostname or IP address", "100.125.79.6"), ("Mac account username", "iris"), ("Starting directory (optional)", "/Users/iris/Developer/RemoteFiles/.test-server/remote-images")] {
                let field = app.textFields[label]
                if !field.isHittable { app.swipeUp() }
                field.tap(); field.typeText(value)
            }
            app.buttons["Save"].tap()
        }
        XCTAssertTrue(connection.waitForExistence(timeout: 10)); connection.tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "images.md,")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 20), app.debugDescription); report.tap()
        let small = app.buttons["Open image small.png"].firstMatch
        XCTAssertTrue(small.waitForExistence(timeout: 20), app.debugDescription)
        let missing = app.staticTexts["missing.png"]
        for _ in 0..<5 {
            if missing.exists && missing.isHittable { break }; app.swipeUp()
        }
        XCTAssertTrue(app.buttons["Tap to retry"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let failure = XCTAttachment(screenshot: app.screenshot()); failure.name = "Image failure with retry and open"; failure.lifetime = .keepAlways; add(failure)
        let large = app.buttons["Open image large-70mb.png"]
        for _ in 0..<4 { if large.exists && large.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(large.waitForExistence(timeout: 160), app.debugDescription)
        if !large.isHittable { app.swipeDown() }
        large.tap()
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 10))
        let share = app.buttons["Share"]
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: share)
        waitForExpectations(timeout: 30)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Seventy MB SFTP image downsampled"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["Done"].tap()
    }
}

extension RealServerUITests {
    func testImageFreeReadmeRendersBeforeAndAfterSourceSwitch() throws {
        try enabled()
        let app = XCUIApplication(); app.launch()
        let readme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "README.md,")).firstMatch
        XCTAssertTrue(readme.waitForExistence(timeout: 10), app.debugDescription)
        if !readme.isHittable { app.swipeUp() }
        readme.tap()
        let heading = app.staticTexts["Build and run"]
        XCTAssertTrue(heading.waitForExistence(timeout: 12), "Image-free README must render visible content, not merely an empty scroll view.\n" + app.debugDescription)
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "README rendered"; initial.lifetime = .keepAlways; add(initial)
        app.buttons["Source"].tap()
        XCTAssertTrue(app.scrollViews["Markdown source"].waitForExistence(timeout: 5))
        app.buttons["Rendered"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        app.buttons["Document actions"].tap(); app.buttons["Refresh"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
    }
}

extension RealServerUITests {
    func testBackgroundReconnectsToChangedRealServerDocument() throws {
        try enabled()
        let app = XCUIApplication()
        app.launch()
        let connection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Image checks,")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10), app.debugDescription)
        connection.tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "lifecycle.md,")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 20), app.debugDescription)
        report.tap()
        XCTAssertTrue(app.staticTexts["Initial lifecycle revision"].waitForExistence(timeout: 15), app.debugDescription)

        print("REMOTEFILES_LIFECYCLE_CONNECTED_READY")
        Thread.sleep(forTimeInterval: 4)
        XCUIDevice.shared.press(.home)
        print("REMOTEFILES_LIFECYCLE_BACKGROUND_READY")
        // The host test harness changes the remote fixture while this app is backgrounded.
        Thread.sleep(forTimeInterval: 15)
        app.activate()

        let updated = app.staticTexts["Updated while backgrounded"]
        XCTAssertTrue(updated.waitForExistence(timeout: 25),
                      "Foregrounding must make a new SFTP read and display the changed server file.\n" + app.debugDescription)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Connection paused while the app is in the background")).firstMatch.exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Foreground reconnect fetched changed server document"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testLocalNetworkDeniedAndRestored() throws {
        try enabled()
        let host = try XCTUnwrap(ProcessInfo.processInfo.environment["REMOTEFILES_LAN_HOST"])
        let fingerprint = try XCTUnwrap(ProcessInfo.processInfo.environment["REMOTEFILES_LAN_FINGERPRINT"])
        let app = XCUIApplication()
        app.launch()
        let localProfile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Local network check,")).firstMatch
        if !localProfile.waitForExistence(timeout: 2) {
            let add = app.buttons["Add Connection"]
            if !add.isHittable { app.swipeUp() }
            add.tap()
            for (label, value) in [("Display name", "Local network check"),
                                   ("Hostname or IP address", host),
                                   ("Mac account username", "iris"),
                                   ("Starting directory (optional)", "/Users/iris/Developer/RemoteFiles/.test-server/remote-images")] {
                let field = app.textFields[label]
                if !field.isHittable { app.swipeUp() }
                field.tap(); field.typeText(value)
            }
            app.buttons["Save"].tap()
        }
        XCTAssertTrue(localProfile.waitForExistence(timeout: 10), app.debugDescription)
        localProfile.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 5) {
            let deny = springboard.alerts.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
            XCTAssertTrue(deny.exists, springboard.alerts.firstMatch.debugDescription)
            deny.tap()
        }

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let privacy = settings.buttons["Privacy & Security"]
        if !privacy.isHittable { for _ in 0..<6 where !privacy.isHittable { settings.swipeUp() } }
        XCTAssertTrue(privacy.waitForExistence(timeout: 5), settings.debugDescription)
        privacy.tap()
        let local = settings.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Local Network")).firstMatch
        if !local.isHittable { for _ in 0..<5 where !local.isHittable { settings.swipeUp() } }
        XCTAssertTrue(local.waitForExistence(timeout: 5), settings.debugDescription)
        local.tap()
        let permission = settings.switches["RemoteFiles"]
        if !permission.isHittable { for _ in 0..<8 where !permission.isHittable { settings.swipeUp() } }
        XCTAssertTrue(permission.waitForExistence(timeout: 5), settings.debugDescription)
        permission.tap()
        let permissionToggle = settings.switches["Local Network"]
        XCTAssertTrue(permissionToggle.waitForExistence(timeout: 5), settings.debugDescription)
        if permissionToggle.value as? String != "0" {
            permissionToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(permissionToggle.value as? String, "0")
        defer {
            settings.activate()
            if permissionToggle.value as? String == "0" {
                permissionToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
        }

        app.activate()
        let denied = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Local Network")).firstMatch
        XCTAssertTrue(denied.waitForExistence(timeout: 15), "A denied LAN connection needs actionable guidance.\n" + app.debugDescription)
        let retainedFile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "images.md,")).firstMatch
        XCTAssertTrue(app.buttons["Try Again"].exists || retainedFile.exists,
                      "The folder must remain navigable, with either retry or its previously loaded entries.")
        let failure = XCTAttachment(screenshot: app.screenshot())
        failure.name = "Local Network denied with Settings guidance"
        failure.lifetime = .keepAlways
        add(failure)

        settings.activate()
        permissionToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(permissionToggle.value as? String, "1")
        app.activate()
        let trust = app.buttons["Trust & Connect"]
        if trust.waitForExistence(timeout: 15) {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fingerprint)).firstMatch.exists)
            trust.tap()
        }
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "images.md,")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 25), "Re-enabling permission should permit the LAN SFTP read.\n" + app.debugDescription)
        app.navigationBars.buttons["RemoteFiles"].tap()
        localProfile.press(forDuration: 1)
        app.buttons["Delete Connection"].tap()
        XCTAssertFalse(localProfile.exists)
    }
}
