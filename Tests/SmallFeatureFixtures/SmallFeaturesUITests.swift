import XCTest

@MainActor final class SmallFeaturesUITests: XCTestCase {
    private func app(_ name: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--small-features-fixture", "--feature-case=\(name)"] + extra
        app.launch(); return app
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func openInstaller(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap(); app.buttons["SSH Keys"].tap()
        let identity = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Public Identity")).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10)); identity.tap()
        let install = app.buttons["Install Public Key on Server"]
        XCTAssertTrue(install.waitForExistence(timeout: 10)); if !install.isHittable { app.swipeUp() }; install.tap()
        XCTAssertTrue(app.navigationBars["Install Public Key"].waitForExistence(timeout: 10))
    }
    private func review(_ app: XCUIApplication) {
        let password = app.secureTextFields["Account password"]
        for _ in 0..<4 { if password.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(password.waitForExistence(timeout: 5)); password.tap(); password.typeText("public-fixture-password")
        let review = app.buttons["Review Installation"]
        for _ in 0..<5 { if review.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(review.isHittable); review.tap()
        XCTAssertTrue(app.navigationBars["Confirm Installation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture@fixture.invalid:22"].exists)
        capture("Integrated public-key confirmation", app)
    }
    private func confirm(_ app: XCUIApplication) {
        let button = app.buttons["Install Public Key"]
        for _ in 0..<3 { if button.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(button.isHittable); button.tap()
    }
    private func text(_ contains: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", contains)).firstMatch
    }
    func testSwipeRemovalPersistsAfterActualRelaunchAndRemoteFileStillOpens() {
        continueAfterFailure = false
        let app = app("ui-recents-relaunch")
        let recent = app.buttons["recent-F3000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(recent.waitForExistence(timeout: 15)); capture("Integrated Home with recent", app); if !recent.isHittable { app.swipeUp() }; recent.swipeLeft()
        if app.buttons["Remove from Recents"].exists { app.buttons["Remove from Recents"].tap() }
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15)); XCTAssertFalse(recent.exists)
        capture("Integrated Home after persisted removal", app)
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Fixture Mac")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 5)); projects.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10), app.debugDescription)
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly review.md,")).firstMatch
        for _ in 0..<5 { if report.exists && report.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(report.waitForExistence(timeout: 5), app.debugDescription); report.tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 10))
    }
    func testNestedDisconnectWhileRequestIsInFlightReturnsHomeWithoutLateNavigation() {
        continueAfterFailure = false
        let app = app("ui-nested-disconnect", extra: ["--feature-slow-read"])
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Fixture Mac")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        let reports = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reports,")).firstMatch
        XCTAssertTrue(reports.waitForExistence(timeout: 10)); reports.tap()
        XCTAssertTrue(app.otherElements["Connecting and opening folder…"].exists || app.staticTexts["Connecting and opening folder…"].exists,
                      "Fixture must still have in-flight folder work")
        app.buttons["Folder actions"].tap(); app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.navigationBars["RemoteFiles"].waitForExistence(timeout: 10))
        XCTAssertTrue(projects.isHittable); XCTAssertFalse(app.navigationBars.buttons["Projects"].exists)
        projects.tap(); XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        XCTAssertTrue(reports.waitForExistence(timeout: 10)); app.navigationBars.buttons["RemoteFiles"].tap()
        XCTAssertTrue(projects.isHittable)
    }
    func testInstallationConfirmationCanCancelThenInstallAndRepeatWithoutDuplicate() {
        continueAfterFailure = false
        let app = app("ui-install-repeat"); openInstaller(app); review(app)
        app.navigationBars["Confirm Installation"].buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Install Public Key"].waitForExistence(timeout: 5))
        XCTAssertFalse(text("Public key installed for", in: app).exists)
        app.buttons["Review Installation"].tap()
        XCTAssertTrue(app.navigationBars["Confirm Installation"].waitForExistence(timeout: 5)); confirm(app)
        XCTAssertTrue(text("Public key installed for fixture@fixture.invalid:22", in: app).waitForExistence(timeout: 10))
        review(app); confirm(app)
        XCTAssertTrue(text("already listed for fixture@fixture.invalid:22", in: app).waitForExistence(timeout: 10))
    }
    func testLostReplyRetryAndDisruptedInstallClearPasswordAndNeverSendPrivateKey() {
        continueAfterFailure = false
        let app = app("ui-install-lost-reply", extra: ["--feature-lost-reply"])
        openInstaller(app); review(app); confirm(app)
        XCTAssertTrue(text("may have been added", in: app).waitForExistence(timeout: 10))
        review(app); confirm(app)
        XCTAssertTrue(text("already listed for fixture@fixture.invalid:22", in: app).waitForExistence(timeout: 10))
        app.terminate()
        let interrupted = self.app("ui-install-disrupted", extra: ["--feature-slow-install"])
        openInstaller(interrupted); review(interrupted); confirm(interrupted)
        XCTAssertTrue(text("Installing public key", in: interrupted).waitForExistence(timeout: 5) || interrupted.progressIndicators.firstMatch.exists)
        interrupted.navigationBars["Install Public Key"].buttons["Cancel"].tap()
        XCTAssertTrue(interrupted.buttons["Install Public Key on Server"].waitForExistence(timeout: 5))
        interrupted.buttons["Install Public Key on Server"].tap()
        let password = interrupted.secureTextFields["Account password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        for _ in 0..<5 { if interrupted.buttons["Review Installation"].exists { break }; interrupted.swipeUp() }
        XCTAssertTrue(interrupted.buttons["Review Installation"].exists, interrupted.debugDescription)
        XCTAssertFalse(interrupted.buttons["Review Installation"].isEnabled)
        XCTAssertFalse(text("Public key installed for", in: interrupted).exists)
    }
}
