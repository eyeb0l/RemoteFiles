import XCTest
import UIKit
import CryptoKit
import Security
import NIOSSH
@testable import RemoteFilesCore

extension XCUIApplication {
    /// The app under test, without Xcode's console mirroring of unified logs.
    ///
    /// XCTest answers each accessibility query on the app's main thread and logs every
    /// attribute it fetches (about 9 MB per journey). With `OS_ACTIVITY_DT_MODE` set, those
    /// messages are also written synchronously to the app's stderr, a pseudo-terminal that
    /// xcodebuild drains through its own main thread. On a loaded CI runner xcodebuild runs at
    /// utility priority and stops draining, so the app blocks in `writev` while serving the
    /// query and XCTest reports snapshot timeouts. The messages still reach the unified log.
    static func underTest() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS_ACTIVITY_DT_MODE"] = "NO"
        return app
    }
}

@MainActor
final class RemoteFilesUITests: XCTestCase {
    func testOfflineFolderSnapshotBrowsesSubfoldersAfterDisconnectBackgroundAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        let reports = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reports,")).firstMatch
        revealFolderRow(reports, in: app).tap()
        app.buttons["Folder actions"].tap()
        if app.buttons["Remove Offline Folder"].exists {
            app.buttons["Remove Offline Folder"].tap()
            app.buttons["Folder actions"].tap()
        }
        XCTAssertTrue(app.buttons["Keep Folder Offline"].waitForExistence(timeout: 5)); app.buttons["Keep Folder Offline"].tap()
        XCTAssertTrue(app.switches["Include Hidden Files"].waitForExistence(timeout: 5))
        app.buttons["Save Folder Offline"].tap()
        let saved = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.otherElements["offline-save-progress"])
        wait(for: [saved], timeout: 15)
        app.buttons["Folder actions"].tap()
        XCTAssertTrue(app.buttons["Update Offline Folder"].waitForExistence(timeout: 5))
        app.buttons["Disconnect"].tap()
        let library = app.buttons["offline-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        let folder = app.buttons["offline-folder-Reports"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.tap()
        XCTAssertTrue(app.staticTexts["offline-folder-date"].waitForExistence(timeout: 5))
        let nested = app.buttons["offline-subfolder-2026"]
        XCTAssertTrue(nested.waitForExistence(timeout: 5)); nested.tap()
        let file = app.buttons["offline-file-Quarterly review.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15))
        // The Markdown scroll container appears while its document is still preparing.
        // Wait for the leased reader's toolbar, rather than accepting that placeholder.
        XCTAssertTrue(app.buttons["Share Original"].waitForExistence(timeout: 15))
        attachScreenshot("Saved folder nested Markdown reader")
        XCUIDevice.shared.press(.home)
        waitForBackground(app); app.activate()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15))
        app.terminate(); app.launch()
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.tap()
        attachScreenshot("Offline folder snapshot and subfolders")
        XCTAssertTrue(nested.waitForExistence(timeout: 5)); nested.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["2026"].tap()
        app.navigationBars.buttons["Reports"].tap()
        let linked = app.buttons["offline-file-Linked notes.md"]
        XCTAssertTrue(linked.waitForExistence(timeout: 5)); linked.tap()
        let scroll = app.scrollViews["Rendered Markdown document"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        try revealDocumentLink("Jump to note heading", in: app, scroll: scroll).tap()
        XCTAssertTrue(app.staticTexts["Linked note marker"].isHittable)
        try revealDocumentLink("Open heading details", in: app, scroll: scroll).tap()
        XCTAssertTrue(app.navigationBars["Heading notes.md"].waitForExistence(timeout: 10))
        let details = app.staticTexts["Heading navigation reached the linked details section."]
        XCTAssertTrue(details.waitForExistence(timeout: 10) && details.isHittable)
        attachScreenshot("Offline document link to a saved heading")
        app.navigationBars.buttons["Linked notes.md"].tap()
        XCTAssertTrue(documentLink("Open heading details", in: scroll).waitForExistence(timeout: 10))
        XCTAssertTrue(documentLink("Open heading details", in: scroll).isHittable, "Back restores the saved reader position")
        for (label, explanation) in [("Missing note", "isn’t saved here"), ("Open parent guide", "leaves the saved folder")] {
            try revealDocumentLink(label, in: app, scroll: scroll).tap()
            let alert = app.alerts["Couldn’t open link"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", explanation)).firstMatch.exists)
            alert.buttons["OK"].tap()
            XCTAssertTrue(app.navigationBars["Linked notes.md"].exists)
        }
        try revealDocumentLink("Open nested review", in: app, scroll: scroll).tap()
        XCTAssertTrue(app.navigationBars["Quarterly review.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["offline-copy-date"].exists)
        app.navigationBars.buttons["Linked notes.md"].tap()
        app.navigationBars.buttons["Reports"].tap()
        app.buttons["Saved folder actions"].tap(); app.buttons["Remove Offline Folder"].tap()
        // The removed snapshot stops presenting rows, while the live demo original stays intact.
        XCTAssertTrue(app.staticTexts["Saved folder unavailable"].waitForExistence(timeout: 5))
    }

    private func openDemoOfflineNavigationGuide() -> XCUIApplication {
        continueAfterFailure = false
        let app = launchDemoReader(filename: "Navigation guide.md")
        app.buttons["Document actions"].tap()
        if app.buttons["Remove Offline Copy"].exists {
            app.buttons["Remove Offline Copy"].tap()
            app.buttons["Document actions"].tap()
        }
        XCTAssertTrue(app.buttons["Keep Offline"].waitForExistence(timeout: 5))
        app.buttons["Keep Offline"].tap()
        // Disconnect uses the production cancel/drain path. Wait for commit before doing so.
        let saved = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.otherElements["offline-save-progress"])
        wait(for: [saved], timeout: 15)
        app.buttons["Document actions"].tap()
        XCTAssertTrue(app.buttons["Update Offline Copy"].waitForExistence(timeout: 5))
        app.buttons["Disconnect"].tap()
        let library = app.buttons["offline-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        let file = app.buttons["offline-file-Navigation guide.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        attachScreenshot("Offline library with saved file")
        file.tap()
        XCTAssertTrue(app.staticTexts["offline-copy-date"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Share Original"].exists)
        attachScreenshot("Offline Markdown copy after disconnect")
        return app
    }

    func testOfflineShareOriginalPresentsAndCancels() {
        let app = openDemoOfflineNavigationGuide()
        for _ in 0..<2 {
            app.buttons["Share Original"].tap()
            let popup = app.popovers.firstMatch
            XCTAssertTrue(popup.waitForExistence(timeout: 15), app.debugDescription)
            // A separate system process fills the sheet's activity list; it can start slowly on loaded runners.
            XCTAssertTrue(popup.cells["Save to Files"].waitForExistence(timeout: 30), app.debugDescription)
            let dismiss = app.otherElements["PopoverDismissRegion"].firstMatch
            XCTAssertTrue(dismiss.exists)
            attachScreenshot("Offline original native share sheet")
            dismiss.tap()
            XCTAssertTrue(popup.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.scrollViews["Rendered Markdown document"].firstMatch.waitForExistence(timeout: 15))
        }
    }

    func testOfflineCopyHeadingAndMissingDocumentLinks() throws {
        let app = openDemoOfflineNavigationGuide()
        let reader = app.scrollViews["Rendered Markdown document"].firstMatch
        try revealDocumentLink("Jump to marker 20", in: app, scroll: reader).tap()
        XCTAssertTrue(reader.staticTexts["Reading marker 20"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(reader.staticTexts["Reading marker 20"].firstMatch.isHittable)
        try revealDocumentLink("Open nested note", in: app, scroll: reader).tap()
        let missing = app.alerts["Couldn’t open link"]
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        XCTAssertTrue(missing.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "isn’t saved here")).firstMatch.exists)
        missing.buttons["OK"].tap()
    }

    func testOfflineCopyOpensAfterDisconnectAndRelaunchAndCanBeRemoved() throws {
        let app = openDemoOfflineNavigationGuide()
        let library = app.buttons["offline-library"]
        let file = app.buttons["offline-file-Navigation guide.md"]
        XCUIDevice.shared.press(.home)
        waitForBackground(app)
        app.activate()
        XCTAssertTrue(app.staticTexts["offline-copy-date"].waitForExistence(timeout: 10), "Return to the same offline reader")
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].firstMatch.waitForExistence(timeout: 15), "Reopen protected local bytes on activation")
        XCTAssertTrue(app.buttons["Share Original"].exists)

        app.terminate(); app.launch()
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        // The first read of the saved copy in a fresh process has no app deadline; give it a cold-start bound.
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        app.navigationBars.buttons["Offline Files"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.press(forDuration: 1)
        app.buttons["Remove Offline Copy"].tap()
        XCTAssertTrue(app.staticTexts["No offline files"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].tap()
        // Removing a local copy must leave the remote demo original readable.
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 10)); projects.tap()
        let original = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Navigation guide.md,")).firstMatch
        revealFolderRow(original, in: app).tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].firstMatch.waitForExistence(timeout: 15))
    }

    func testOfflineAudioPinnedFromFolderKeepsLocalPlaybackControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        let audio = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sample audio.m4a,")).firstMatch
        revealFolderRow(audio, in: app).press(forDuration: 1)
        if app.buttons["Remove Offline Copy"].exists {
            app.buttons["Remove Offline Copy"].tap()
            audio.press(forDuration: 1)
        }
        XCTAssertTrue(app.buttons["Keep Offline"].waitForExistence(timeout: 5)); app.buttons["Keep Offline"].tap()
        let saved = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.otherElements["offline-save-progress"])
        wait(for: [saved], timeout: 15)
        audio.tap()
        XCTAssertTrue(app.sliders["Playback position"].waitForExistence(timeout: 20))
        app.buttons["Document actions"].tap()
        XCTAssertTrue(app.buttons["Update Offline Copy"].waitForExistence(timeout: 5))
        app.buttons["Disconnect"].tap()
        let library = app.buttons["offline-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        let file = app.buttons["offline-file-Sample audio.m4a"]
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        XCTAssertTrue(app.staticTexts["offline-copy-date"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sliders["Playback position"].waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5)); app.buttons["Pause"].tap()
        attachScreenshot("Offline local audio playback")
        app.navigationBars.buttons["Offline Files"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.press(forDuration: 1)
        app.buttons["Remove Offline Copy"].tap()
    }

    func testAdaptiveWorkspaceKeepsLibraryFolderAndReaderOnIPad() throws {
        continueAfterFailure = false
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if isPad { XCUIDevice.shared.orientation = .portrait } }
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        // With no folder chosen the library opens itself, even where it has to overlay.
        waitUntilHittable(projects); projects.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        // Layout follows size classes, so an unfolded iPhone Duo shows the workspace too.
        let usesWorkspace = app.staticTexts["Choose a file"].waitForExistence(timeout: 2)
        if isPad { XCTAssertTrue(usesWorkspace, "A landscape iPad shows the split workspace") }
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest report")).firstMatch
        // An iPad window tiles all three columns; an unfolded iPhone Duo overlays the library,
        // which closes once it has opened the folder.
        if usesWorkspace && isPad { XCTAssertTrue(projects.isHittable, "A tiled library stays open") }
        if usesWorkspace && !isPad {
            let closed = expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: projects)
            closed.expectationDescription = "An overlaid library closes once it opens a folder"
            wait(for: [closed], timeout: 10)
        }
        revealFolderRow(report, in: app).tap()
        let reader = app.scrollViews["Rendered Markdown document"]
        XCTAssertTrue(reader.waitForExistence(timeout: 15))
        if usesWorkspace {
            waitUntilHittable(reader, "An overlaid folder closes once it opens a file")
            if isPad {
                XCTAssertTrue(projects.isHittable, "Library remains available alongside the reader")
                XCTAssertLessThan(projects.frame.midX, report.frame.midX)
            }
            // A portrait iPhone Duo overlays the folder too; elsewhere it stays beside the reader.
            if isPad { XCTAssertTrue(report.isHittable, "Opening a preview keeps its folder visible") }
            if report.isHittable { XCTAssertLessThan(report.frame.midX, reader.frame.midX) }
            attachScreenshot("Workspace library folder and reader")
            let reports = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reports, Folder")).firstMatch
            revealWorkspaceColumn(containing: app.navigationBars["Projects"], in: app)
            revealFolderRow(reports, in: app, searchingDown: false).tap()
            XCTAssertTrue(app.navigationBars["Reports"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Choose a file"].waitForExistence(timeout: 5), "Changing folders clears the old preview")
            app.buttons["Previous Folder"].tap()
            XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
            revealWorkspaceColumn(containing: projects, in: app); projects.tap()
            XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
        } else {
            app.navigationBars.buttons["Projects"].tap()
            XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
        }
    }

    func testFindAndSameDocumentHeadingLinkInReader() throws {
        continueAfterFailure = false
        let app = launchDemoReader(filename: "Navigation guide.md")
        let localHeading = try revealDocumentLink("Jump to marker 20", in: app, scroll: app.scrollViews["Rendered Markdown document"])
        localHeading.tap()
        XCTAssertTrue(app.staticTexts["Reading marker 20"].waitForExistence(timeout: 5) && app.staticTexts["Reading marker 20"].isHittable,
                      "A same-document heading link must reveal its heading without pushing another reader")
        app.buttons["Document actions"].tap(); app.buttons["Find in Document"].tap()
        let query = app.textFields["reader-find-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("Reading marker 20")
        let status = app.staticTexts["reader-find-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let matchFound = expectation(for: NSPredicate(format: "label == %@", "1 of 1"), evaluatedWith: status)
        wait(for: [matchFound], timeout: 10)
        app.buttons["Next result"].tap() // Dismiss keyboard and reveal the active match.
        XCTAssertTrue(app.staticTexts["Reading marker 20"].isHittable, app.debugDescription)
        attachScreenshot("Find matching rendered heading")
        app.buttons["Done"].tap()
    }

    func testHeadingOutlineAndLinkedDocumentHeadingInReader() throws {
        continueAfterFailure = false
        let app = launchDemoReader(filename: "Navigation guide.md")
        app.buttons["Document actions"].tap(); app.buttons["Headings"].tap()
        let outline = app.collectionViews.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        let last = outline.buttons["Navigation return marker, heading level 2"]
        for _ in 0..<10 { if last.exists && last.isHittable { break }; outline.swipeUp() }
        XCTAssertTrue(last.waitForExistence(timeout: 5) && last.isHittable, app.debugDescription); last.tap()
        let link = try revealDocumentLink("Heading link", in: app, scroll: app.scrollViews["Rendered Markdown document"])
        link.tap()
        XCTAssertTrue(app.navigationBars["Heading notes.md"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Details"].waitForExistence(timeout: 10) && app.staticTexts["Details"].isHittable, app.debugDescription)
        attachScreenshot("Linked document heading navigation")
    }

    func testWrapLinesToggleAndPreferenceSurviveReopeningSource() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        func openExample() {
            let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
            XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Example.swift,")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            revealFolderRow(row, in: app).tap()
            XCTAssertTrue(app.textViews["Bounded source text"].waitForExistence(timeout: 15))
        }
        let toggle = app.descendants(matching: .any).matching(identifier: "Wrap Lines").firstMatch
        openExample()
        let source = app.textViews["Bounded source text"]
        app.buttons["Document actions"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        // Native source keeps a fixed viewport; hosted tests verify the changing
        // text-container dimensions and actual horizontal scrolling.
        let initial = toggle.isSelected
        toggle.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let original = source.value as? String
        XCTAssertNotNil(original)
        attachScreenshot("Source after toggling line wrapping")
        app.buttons["Document actions"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let changed = toggle.isSelected
        XCTAssertNotEqual(changed, initial)
        dismissDocumentActions(in: app)
        app.terminate(); app.launch(); openExample()
        app.buttons["Document actions"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.isSelected, changed, "Preference must survive app relaunch")
        toggle.tap()
        XCTAssertEqual(source.value as? String, original)
    }

    func testHTMLRenderedSourceAndRefresh() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview.html,")).firstMatch
        revealFolderRow(row, in: app).tap()
        XCTAssertTrue(app.buttons["Source"].waitForExistence(timeout: 10))
        // Each render starts a new WebKit content process. Wait past the app's 30-second
        // rendering guard so a slow launch is judged by the app, not by a shorter test timeout.
        let rendering: TimeInterval = 35
        XCTAssertTrue(app.webViews.staticTexts["HTML preview"].waitForExistence(timeout: rendering), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["Sample table"].exists, app.debugDescription)
        attachScreenshot("HTML rendered page")
        app.buttons["Source"].tap()
        let source = app.textViews["Bounded source text"]
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue((source.value as? String ?? "").hasPrefix("<!doctype html>"))
        XCTAssertTrue((source.value as? String ?? "").contains("café 東京 🌍"))
        XCTAssertTrue((source.value as? String ?? "").hasSuffix("</body></html>"))
        attachScreenshot("HTML original highlighted source")
        app.buttons["Document actions"].tap(); app.buttons["Copy Source"].tap()
        app.buttons["Document actions"].tap()
        XCTAssertTrue(app.buttons["Source Copied"].waitForExistence(timeout: 5))
        dismissDocumentActions(in: app)
        app.buttons["Rendered"].tap()
        XCTAssertTrue(app.webViews.staticTexts["HTML preview"].waitForExistence(timeout: rendering), app.debugDescription)
        app.buttons["Document actions"].tap(); app.buttons["Refresh"].tap()
        XCTAssertTrue(app.webViews.staticTexts["HTML preview"].waitForExistence(timeout: rendering), app.debugDescription)
    }

    func testDemoAudioAndVideoHaveNativePlaybackControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        for filename in ["Sample audio.m4a", "Sample video.mp4"] {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
            revealFolderRow(row, in: app).tap()
            let video = filename.hasSuffix(".mp4")
            XCTAssertTrue(app.sliders["Playback position"].waitForExistence(timeout: 20), app.debugDescription)
            let play = app.buttons["Play"]
            XCTAssertTrue(play.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(play.isHittable, app.debugDescription)
            attachScreenshot(filename + " native controls")
            play.tap()
            XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5), app.debugDescription)
            app.buttons["Pause"].tap()
            if video {
                let fullscreen = app.buttons["Full Screen"]
                XCTAssertGreaterThanOrEqual(fullscreen.frame.minY, app.sliders["Playback position"].frame.maxY,
                                            "Fullscreen belongs with transport controls, outside the video")
                app.buttons["Full Screen"].tap()
                let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Done"])).firstMatch
                XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertFalse(app.sliders["Playback position"].exists, "Fullscreen must use native iOS transport controls")
                attachScreenshot("Native iOS fullscreen player")
                close.tap()
                XCTAssertTrue(app.buttons["Full Screen"].waitForExistence(timeout: 10), app.debugDescription)
                app.buttons["Full Screen"].tap()
                XCTAssertTrue(close.waitForExistence(timeout: 10), "Native dismissal must allow opening fullscreen again")
                close.tap()
            }
            app.buttons["Document actions"].tap(); app.buttons["Refresh"].tap()
            XCTAssertTrue(play.waitForExistence(timeout: 10), app.debugDescription)
            app.navigationBars.buttons["Projects"].tap()
        }
    }

    func testLongJSONAndSVGRenderedSourcePreview() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        let json = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Long lines.json,")).firstMatch
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        revealFolderRow(json, in: app).tap()
        let source = app.textViews["Bounded source text"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        XCTAssertTrue((source.value as? String)?.hasPrefix("{\n  \"version\": 1,") == true)
        XCTAssertTrue((source.value as? String)?.hasSuffix("\"ready\": true\n}\n") == true)
        attachScreenshot("Long JSON bounded source")
        app.buttons["Document actions"].tap(); app.buttons["Copy Source"].tap()
        app.buttons["Document actions"].tap()
        XCTAssertTrue(app.buttons["Source Copied"].waitForExistence(timeout: 5))
        dismissDocumentActions(in: app)
        app.navigationBars.buttons["Projects"].tap()
        let svg = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Icon.svg,")).firstMatch
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        // Back preserves the folder position at Long lines.json; Icon.svg is above it.
        revealFolderRow(svg, in: app, searchingDown: false).tap()
        let image = app.descendants(matching: .any).matching(identifier: "Rendered SVG image").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForNonExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(image.exists && image.isHittable, app.debugDescription)
        // WebKit can expose the element before its first paint, so sample until the SVG is visible.
        func purplePixels() throws -> Int {
            let pixels = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
            let width = pixels.width, height = pixels.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return stride(from: width * (height / 4) * 4, to: width * (height * 3 / 4) * 4, by: 4).filter {
                bytes[$0+2] > 180 && bytes[$0] > 60 && bytes[$0] < 180 && bytes[$0+1] < 120
            }.count
        }
        var purple = try purplePixels()
        let paintDeadline = Date().addingTimeInterval(10)
        while purple <= 5_000, Date() < paintDeadline {
            Thread.sleep(forTimeInterval: 0.25)
            purple = try purplePixels()
        }
        attachScreenshot("SVG rendered image")
        XCTAssertGreaterThan(purple, 5_000, "Wait for visible SVG pixels, not just a WebKit accessibility element")
        app.buttons["Source"].tap()
        let xml = app.textViews["Bounded source text"]
        XCTAssertTrue(xml.waitForExistence(timeout: 10))
        XCTAssertTrue((xml.value as? String ?? "").hasPrefix("<svg xmlns="))
        attachScreenshot("SVG original source")
        app.buttons["Rendered"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 10))
    }
    func testRecentSwipeRemovesOnlyEntryAndReaderDisconnectReturnsHome() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly review.md,")).firstMatch
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        revealFolderRow(report, in: app).tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15))
        app.buttons["Document actions"].tap(); app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.navigationBars["RemoteFiles"].waitForExistence(timeout: 10))
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recent-")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        if !recent.isHittable { app.swipeUp() }
        recent.swipeLeft()
        if app.buttons["Remove from Recents"].exists { app.buttons["Remove from Recents"].tap() }
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5))
        if !projects.isHittable { app.swipeDown() }; projects.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        revealFolderRow(report, in: app).tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15), "Remote document must still exist after recent removal")
    }
    func testDisconnectFromNestedFolderClearsStackAndReconnectsFromHome() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        let reports = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reports,")).firstMatch
        XCTAssertTrue(reports.waitForExistence(timeout: 10)); reports.tap()
        XCTAssertTrue(app.navigationBars["Reports"].waitForExistence(timeout: 10))
        app.buttons["Folder actions"].tap(); app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.navigationBars["RemoteFiles"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.buttons["Projects"].exists)
        XCTAssertTrue(projects.isHittable); projects.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.buttons["RemoteFiles"].exists)
    }
    func testSearchingSubfoldersFindsNestedNamesKeepsResultsAndSwitchesBack() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("review")
        let subfolders = app.buttons["Subfolders"]
        XCTAssertTrue(subfolders.waitForExistence(timeout: 5), app.debugDescription); subfolders.tap()

        let nested = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Quarterly review.md,")).firstMatch
        XCTAssertTrue(nested.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(nested.label.contains("In Reports/2026"), nested.label)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Weekly review.md,", "In Reports")).firstMatch.exists)
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Searched 6 folders")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Projects, its four folders and Reports/2026; the link to Reports is not followed")
        XCTAssertTrue(summary.isHittable, "The summary stays visible above the keyboard")
        search.typeText("\n")
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Subfolder search results"; capture.lifetime = .keepAlways; add(capture)

        // Tap the title itself: the combined accessibility row's center falls between its
        // two text lines on the physical iPhone and does not activate the link.
        let title = nested.staticTexts["Quarterly review.md"].firstMatch
        waitUntilHittable(title); title.tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars.buttons["Projects"].waitForExistence(timeout: 5)); app.navigationBars.buttons["Projects"].tap()
        // Searching again would show its status for at least the pause before listing.
        let searching = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Searching")).firstMatch
        for _ in 0..<20 {
            XCTAssertFalse(searching.exists, "Coming back shows the finished search instead of searching again")
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(nested.exists && summary.exists, "Results stay after opening one")

        app.buttons["This Folder"].tap()
        let filtered = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly review.md,")).firstMatch
        XCTAssertTrue(filtered.waitForExistence(timeout: 10))
        XCTAssertFalse(nested.exists, "This Folder filters only the folder's own names")
    }

    func testContentSearchShowsSourceSnippetsAndKeepsResultsWhenOpeningAFile() throws {
        continueAfterFailure = false
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if isPad { XCUIDevice.shared.orientation = .portrait } }
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        waitUntilHittable(projects); projects.tap()
        let reports = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reports, Folder")).firstMatch
        waitUntilHittable(reports); reports.tap()
        let usesWorkspace = app.staticTexts["Choose a file"].waitForExistence(timeout: 2)
        if isPad { XCTAssertTrue(usesWorkspace, "A landscape iPad shows the split workspace") }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("distance disappear")
        app.buttons["Contents"].tap()
        let nested = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Quarterly review.md,")).firstMatch
        XCTAssertTrue(nested.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(nested.label.contains("In 2026")); XCTAssertTrue(nested.label.contains("Line 13"))
        XCTAssertTrue(nested.label.contains("Good tools make the distance disappear."))
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Searched 2 folders. Checked 5 files.")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        search.typeText("\n")
        attachScreenshot("File contents search results")
        nested.tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15))
        if !usesWorkspace { app.navigationBars.buttons["Reports"].tap() }
        // A portrait iPhone Duo closes its folder overlay over the reader; bring it back.
        if usesWorkspace { revealWorkspaceColumn(containing: nested, in: app) }
        XCTAssertTrue(nested.exists && summary.exists, "The completed content search remains when its result opens")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Searching…")).firstMatch.exists)
        app.buttons["This Folder"].tap()
        XCTAssertTrue(app.staticTexts["No matching names"].waitForExistence(timeout: 5), "Contents are not file names")
    }

    func testSavedSearchIndexBuildsReopensWithTheSameSnapshotAndDeletes() throws {
        exerciseSavedSearchIndex(exportOriginal: false)
    }

    func testSavedSearchIndexReopenedResultExportsOriginal() throws {
        exerciseSavedSearchIndex(exportOriginal: true)
    }

    // Each journey creates and reopens its own snapshot. Keep the native Files picker
    // independent of deletion so both fit the unchanged per-method CI deadline.
    private func exerciseSavedSearchIndex(exportOriginal: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        let reports = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reports, Folder")).firstMatch
        func openReports() {
            waitUntilHittable(projects); projects.tap()
            revealFolderRow(reports, in: app).tap()
        }
        openReports()

        let indexList = app.collectionViews["saved-search-index-list"]
        let date = app.staticTexts["saved-search-index-date"]
        let build = app.buttons["Build Index"]
        let rebuild = app.buttons["Rebuild Index"]
        let delete = app.buttons["Delete Index"]
        let search = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", "Search saved contents")).firstMatch
        let result = app.buttons["saved-search-result-/Projects/Reports/2026/Quarterly review.md"]

        func openIndex() {
            let actions = app.buttons["Folder actions"]
            waitUntilHittable(actions); actions.tap()
            let saved = app.buttons["Saved Search Index"]
            XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
            XCTAssertTrue(app.navigationBars["Saved Search Index"].waitForExistence(timeout: 10))
            XCTAssertTrue(indexList.waitForExistence(timeout: 5), app.debugDescription)
        }
        func reveal(_ element: XCUIElement, down: Bool = true) {
            for _ in 0..<16 {
                let bottom = search.exists && search.frame.minY > indexList.frame.midY
                    ? min(indexList.frame.maxY, search.frame.minY - 12) : indexList.frame.maxY
                if element.exists, element.isHittable,
                   element.frame.minY >= indexList.frame.minY, element.frame.maxY <= bottom { return }
                let start = indexList.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: down ? 0.7 : 0.3))
                let end = indexList.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: down ? 0.3 : 0.7))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("Could not reveal saved-index control or result.\n" + app.debugDescription)
        }
        func closeIndex() {
            // iOS hides the sheet navigation bar while its search presentation is active.
            let closeSearch = app.buttons["close"]
            if closeSearch.exists { closeSearch.tap() }
            let done = app.navigationBars["Saved Search Index"].buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        }
        func querySavedContents() {
            XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
            search.tap(); search.typeText("distance disappear\n")
            reveal(result)
            XCTAssertTrue(result.label.contains("Line 13"), result.label)
            XCTAssertTrue(result.label.contains("Good tools make the distance disappear."), result.label)
        }

        openIndex()
        // Demo storage is persistent too; remove only this synthetic folder's previous run.
        if date.waitForExistence(timeout: 3) {
            reveal(delete); delete.tap()
            XCTAssertTrue(build.waitForExistence(timeout: 5))
        }
        reveal(build); build.tap()
        XCTAssertTrue(rebuild.waitForExistence(timeout: 45), "A completed build must expose rebuild and deletion.\n" + app.debugDescription)
        reveal(date, down: false)
        let savedDate = date.label
        XCTAssertTrue(savedDate.hasSuffix("5 files"), savedDate)
        querySavedContents()
        attachScreenshot("Persistent search index with saved source matches")
        closeIndex()

        app.terminate(); app.launch()
        openReports()
        openIndex()
        XCTAssertTrue(date.waitForExistence(timeout: 10))
        XCTAssertEqual(date.label, savedDate, "Relaunching loads the saved snapshot without rebuilding it")
        querySavedContents()
        result.tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15))
        if exportOriginal {
            let export = app.buttons["Save Original to Files"]
            XCTAssertTrue(export.waitForExistence(timeout: 5) && export.isEnabled)
            export.tap()
            XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 45),
                          "An indexed result inside the connection boundary must still export.\n" + app.debugDescription)
            attachScreenshot("Indexed original file native Save to Files picker")
            cancelOriginalExport(in: app)
            XCTAssertTrue(app.navigationBars["Quarterly review.md"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.scrollViews["Rendered Markdown document"].exists)
            let ready = expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: export)
            wait(for: [ready], timeout: 5)
            return
        }
        let back = app.navigationBars.buttons["Reports"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        openIndex(); querySavedContents()
        reveal(delete, down: false); delete.tap()
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        XCTAssertFalse(result.exists, "Deleting the index clears its extracted matches")
        closeIndex()
        openIndex()
        reveal(build)
        XCTAssertFalse(date.exists, "Deletion persists after reopening the sheet")
        XCTAssertFalse(rebuild.exists)
        XCTAssertFalse(delete.exists)
        closeIndex()
    }

    func testLivePDFAndOCRSearchFindsPagesWithExplicitOptions() throws {
        continueAfterFailure = false
        let app = launchDemoSearchSamples()

        func liveResult(_ filename: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
        }
        func searchContents() {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("INVOICE")
            let contents = app.buttons["Contents"]
            XCTAssertTrue(contents.waitForExistence(timeout: 5)); contents.tap()
            search.typeText("\n")
        }
        func closeLiveSearch() {
            // Navigation-bar search exposes "Close"; the index sheet uses "close".
            let close = app.navigationBars["Search samples"].buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
            XCTAssertTrue(app.navigationBars["Search samples"].waitForExistence(timeout: 5))
        }
        func enableLiveOption(_ title: String) {
            let actions = app.buttons["Folder actions"]
            waitUntilHittable(actions); actions.tap()
            let options = app.buttons["Search Options"]
            XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
            // Native menu toggles use button semantics; a switch is used in form presentations.
            let button = app.buttons[title]
            let option = button.waitForExistence(timeout: 2) ? button : app.switches[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        }

        searchContents()
        XCTAssertTrue(app.staticTexts["No matching contents"].waitForExistence(timeout: 15),
                      "PDFs and images are excluded until their extraction options are enabled")
        XCTAssertFalse(liveResult("Text sample.pdf").exists)
        XCTAssertFalse(liveResult("Scanned sample.pdf").exists)
        XCTAssertFalse(liveResult("Image sample.png").exists)
        closeLiveSearch()
        enableLiveOption("Include PDF Text")
        enableLiveOption("Recognize Text in Images and Scans")
        searchContents()
        let expected = [("Text sample.pdf", "Page 2"), ("Scanned sample.pdf", "Page 1"), ("Image sample.png", "Line 1")]
        for (filename, location) in expected {
            let result = liveResult(filename)
            XCTAssertTrue(result.waitForExistence(timeout: 45), "Missing live PDF/OCR result: \(filename).\n" + app.debugDescription)
            XCTAssertTrue(result.label.contains(location), result.label)
            XCTAssertTrue(result.label.localizedCaseInsensitiveContains("SEARCHABLE INVOICE"), result.label)
        }
        attachScreenshot("PDF and OCR live search on device")
        // The embedded-text match is on page 2; its result opens there rather than at page 1.
        liveResult("Text sample.pdf").tap()
        let indicator = app.staticTexts["PDF page indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 15), app.debugDescription)
        let onMatchPage = expectation(for: NSPredicate(format: "label == %@", "Page 2 of 2"), evaluatedWith: indicator)
        wait(for: [onMatchPage], timeout: 10)
        attachScreenshot("PDF search result opened at its matching page")
        let back = app.navigationBars.buttons["Search samples"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        XCTAssertTrue(liveResult("Text sample.pdf").waitForExistence(timeout: 10), "Completed results remain after returning")
        closeLiveSearch()
    }

    func testSavedPDFAndOCRIndexPersistsRecognizedContents() throws {
        continueAfterFailure = false
        let app = launchDemoSearchSamples()
        let expected = [("Text sample.pdf", "Page 2"), ("Scanned sample.pdf", "Page 1"), ("Image sample.png", "Line 1")]
        app.buttons["Folder actions"].tap()
        let saved = app.buttons["Saved Search Index"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(app.navigationBars["Saved Search Index"].waitForExistence(timeout: 10))
        let list = app.collectionViews["saved-search-index-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let search = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", "Search saved contents")).firstMatch
        func reveal(_ element: XCUIElement, down: Bool = true) {
            for _ in 0..<16 {
                let bottom = search.exists && search.frame.minY > list.frame.midY
                    ? min(list.frame.maxY, search.frame.minY - 12) : list.frame.maxY
                if element.exists, element.isHittable,
                   element.frame.minY >= list.frame.minY, element.frame.maxY <= bottom { return }
                let start = list.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: down ? 0.7 : 0.3))
                let end = list.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: down ? 0.3 : 0.7))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("Could not reveal PDF/OCR index control or result.\n" + app.debugDescription)
        }
        let date = app.staticTexts["saved-search-index-date"]
        let delete = app.buttons["Delete Index"]
        let build = app.buttons["Build Index"]
        if date.waitForExistence(timeout: 3) {
            // Only this synthetic folder's saved index is replaced or removed.
            reveal(delete); delete.tap()
            XCTAssertTrue(build.waitForExistence(timeout: 5))
        }
        let ocr = app.switches["Recognize Text in Images and Scans"]
        reveal(ocr)
        // SwiftUI exposes the entire labelled row as the switch; tap its actual thumb.
        ocr.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // SwiftUI's labelled row can publish the new value after the tap returns.
        let ocrEnabled = expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: ocr)
        wait(for: [ocrEnabled], timeout: 5)
        XCTAssertEqual(ocr.value as? String, "1")
        reveal(build); build.tap()
        XCTAssertTrue(app.buttons["Rebuild Index"].waitForExistence(timeout: 45), "The OCR index must finish within its bounded search")
        reveal(date, down: false)
        XCTAssertTrue(date.label.hasSuffix("3 files"), date.label)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("INVOICE\n")
        for (filename, location) in expected.reversed() {
            let result = app.buttons["saved-search-result-/Projects/Search samples/" + filename]
            reveal(result)
            XCTAssertTrue(result.label.contains(location), result.label)
            XCTAssertTrue(result.label.localizedCaseInsensitiveContains("SEARCHABLE INVOICE"), result.label)
        }
        attachScreenshot("Saved PDF and OCR search results")
        let pdfResult = app.buttons["saved-search-result-/Projects/Search samples/Text sample.pdf"]
        reveal(pdfResult); pdfResult.tap()
        let indicator = app.staticTexts["PDF page indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 15), "A saved PDF result opens its current remote preview")
        let onMatchPage = expectation(for: NSPredicate(format: "label == %@", "Page 2 of 2"), evaluatedWith: indicator)
        wait(for: [onMatchPage], timeout: 10)
        let back = app.navigationBars.buttons["Search samples"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        app.buttons["Folder actions"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("INVOICE\n")
        reveal(delete, down: false); delete.tap()
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        for (filename, _) in expected {
            XCTAssertFalse(app.buttons["saved-search-result-/Projects/Search samples/" + filename].exists)
        }
        let close = app.buttons["close"]
        if close.exists { close.tap() }
        let done = app.navigationBars["Saved Search Index"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
    }

    func testSourceSyntaxHighlightingAndMarkdownSource() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest()
        app.launchArguments = ["--demo"]
        app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.tap()
        let example = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Example.swift,")).firstMatch
        XCTAssertTrue(example.waitForExistence(timeout: 10))
        revealFolderRow(example, in: app).tap()
        let highlighted = app.textViews["Bounded source text"]
        XCTAssertTrue(highlighted.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue((highlighted.value as? String ?? "").contains("// Keep remote files within reach. 東京 ✨"))
        XCTAssertTrue((highlighted.value as? String ?? "").contains("let fileLimit = 2_097_152"))
        attachScreenshot("Syntax highlighted Swift source")
        app.buttons["Document actions"].tap()
        app.buttons["Copy Source"].tap()
        app.buttons["Document actions"].tap()
        XCTAssertTrue(app.buttons["Source Copied"].waitForExistence(timeout: 5))
        // Dismiss the native menu before navigating back.
        dismissDocumentActions(in: app)
        app.navigationBars.buttons["Projects"].tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekly review.md,")).firstMatch
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        revealFolderRow(report, in: app).tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 15))
        app.buttons["Source"].tap()
        XCTAssertTrue(highlighted.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue((highlighted.value as? String ?? "").hasPrefix("# A little closer to home"))
        app.swipeUp()
        attachScreenshot("Syntax highlighted Markdown source")
        let originalSource = highlighted.value as? String
        XCUIDevice.shared.press(.home)
        waitForBackground(app)
        app.activate()
        XCTAssertTrue(highlighted.waitForExistence(timeout: 15))
        XCTAssertEqual(highlighted.value as? String, originalSource, "Foreground re-prepares the original source after releasing inactive parsed content")
        app.buttons["Rendered"].tap()
        XCTAssertTrue(app.scrollViews["Rendered Markdown document"].waitForExistence(timeout: 5))
    }

    func testLargeFolderKeepsScrollPositionAfterOpeningFile() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest()
        app.launchArguments = ["--demo"]
        app.launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch.tap()
        let largeFolder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Thousand files,")).firstMatch
        XCTAssertTrue(largeFolder.waitForExistence(timeout: 10))
        largeFolder.tap()
        XCTAssertTrue(app.navigationBars["Thousand files"].waitForExistence(timeout: 10))
        for _ in 0..<5 { app.swipeUp() }
        let visibleReport = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report "))
            .allElementsBoundByIndex.first(where: { $0.isHittable }))
        let label = visibleReport.label
        visibleReport.tap()
        XCTAssertTrue(app.navigationBars.buttons["Thousand files"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Thousand files"].tap()
        let restored = app.buttons[label]
        XCTAssertTrue(restored.waitForExistence(timeout: 5) && restored.isHittable,
                      "Returning from a file should preserve the folder's scroll position")
        XCTAssertFalse(app.staticTexts["Showing cached folder · refreshing…"].exists,
                       "Back navigation should not refetch a cached listing")
    }

    func testLinkedFolderOpensInOneTapAndSortBySizeReordersFiles() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); projects.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        let linked = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Current reports,")).firstMatch
        let row = revealFolderRow(linked, in: app)
        XCTAssertTrue(row.label.contains("Link to folder"), row.label)
        attachScreenshot("Linked folder sorted with folders")
        row.tap()
        XCTAssertTrue(app.navigationBars["Reports"].waitForExistence(timeout: 10), "A resolved folder link opens without a lookup")
        app.navigationBars.buttons["Projects"].tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        let fileLink = revealFolderRow(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest report,")).firstMatch, in: app)
        XCTAssertTrue(fileLink.label.contains("Link to file"), fileLink.label)
        let broken = revealFolderRow(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Old notes,")).firstMatch, in: app)
        XCTAssertTrue(broken.label.contains("Broken link"), broken.label)
        attachScreenshot("File link and broken link")
        app.buttons["Folder actions"].tap()
        app.buttons["Sort By"].tap()
        app.buttons["Size"].tap()
        // Too large.md (3 MB) now leads the files, ahead of Archive.zip (805 KB), which sorts before it by name.
        let largest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Too large.md,")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Archive.zip,")).firstMatch
        // The list is scrolled down to Old notes; the largest file now sits near the top.
        revealFolderRow(largest, in: app, searchingDown: false)
        XCTAssertTrue(second.waitForExistence(timeout: 5) && largest.frame.minY < second.frame.minY, app.debugDescription)
        attachScreenshot("Folder sorted by size")
    }

    func testBrowseReadRefreshAndReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest()
        app.launchArguments = ["--demo"]
        // Profiling attaches to a freshly launched process before XCTest drives the journey.
        // Normal test runs still own launch; only the explicit profiling harness reuses it.
        if ProcessInfo.processInfo.environment["REMOTEFILES_PROFILE_EXISTING_APP"] == "1" {
            app.activate()
        } else {
            app.launch()
        }

        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.tap()
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest report")).firstMatch
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        revealFolderRow(report, in: app).tap()
        let rendered = app.scrollViews["Rendered Markdown document"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 15))
        attachScreenshot("Physical reader")

        app.buttons["Source"].tap()
        XCTAssertTrue(app.textViews["Bounded source text"].waitForExistence(timeout: 5))
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
        let app = XCUIApplication.underTest()
        app.launch()
        let add = app.buttons["Add Connection"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        XCTAssertTrue(add.isHittable)
        XCTAssertLessThan(add.frame.height, 150, "The setup action must not expand into an unreadable vertical capsule.")
        attachScreenshot("Physical normal Home")
        add.tap()
        XCTAssertTrue(app.textFields["Hostname or IP address"].waitForExistence(timeout: 5))
        let jump = app.switches["Use Jump Host"]
        // XCTest can report this row as hittable while its switch is below the
        // screen. Reveal the whole row before tapping its trailing switch control.
        let safeViewport = app.frame.insetBy(dx: 0, dy: 44)
        for _ in 0..<5 {
            if jump.exists && jump.isHittable && safeViewport.contains(jump.frame) { break }
            app.swipeUp()
        }
        XCTAssertTrue(jump.exists && jump.isHittable && safeViewport.contains(jump.frame))
        jump.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(jump.value as? String, "1", "Enable routing before checking its fields")
        let hopHost = app.textFields["Jump hostname or IP address"]
        for _ in 0..<4 { if hopHost.exists && hopHost.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(hopHost.exists && hopHost.isHittable)
        let hopAccount = app.textFields["Jump account username"]
        for _ in 0..<4 { if hopAccount.exists && hopAccount.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(hopAccount.exists && hopAccount.isHittable)
        XCTAssertFalse(app.buttons["Save"].isEnabled, "An incomplete routed connection cannot be saved")
        attachScreenshot("Jump host connection setup")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    func testImportRSAAndECDSAKeysShowsTheirAlgorithmsAndPublicKeys() throws {
        continueAfterFailure = false
        for fixture in try ImportedIdentityUIFixture.make() {
            // Fail before interacting with the app if this device generated an invalid fixture.
            let imported = try OpenSSHIdentityParser.parse(fixture.privateText, passphrase: nil)
            XCTAssertEqual(String(openSSHPublicKey: imported.key.nioPrivateKey.publicKey), fixture.publicKey)
            let app = XCUIApplication.underTest()
            app.launch()
            app.buttons["Settings"].tap()
            app.buttons["SSH Keys"].tap()
            app.buttons["Import Key"].tap()
            let name = app.textFields["Identity name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap(); name.typeText("UI test " + fixture.name)
            fixture.copyPrivateText(to: .general)
            // On a physical device the background UI-test runner can't write the general
            // pasteboard (PBErrorDomain 10/11), so the app would paste stale text and rightly
            // reject it. IdentitySecKeyFixtureTests covers these keys on the device instead.
            // Simulators allow the write and must still run the paste. (A runtime check:
            // the acceptance inventory parser rejects compile-time conditionals here.)
            let physicalDevice = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil
            if physicalDevice, UIPasteboard.general.string != fixture.privateText {
                app.terminate()
                throw XCTSkip("The UI-test runner can't write the clipboard on a physical device; key parsing is covered by IdentitySecKeyFixtureTests")
            }
            // XCTAssertEqual would disclose private text on failure.
            XCTAssertTrue(UIPasteboard.general.string == fixture.privateText, "Clipboard changed before native paste")
            defer { UIPasteboard.general.string = "" }
            let paste = app.buttons["Paste Private Key"]
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: paste)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
            paste.tap()
            XCTAssertTrue(app.staticTexts["Private key pasted"].waitForExistence(timeout: 5))
            XCTAssertTrue(UIPasteboard.general.string == fixture.privateText, "Clipboard changed during native paste")
            if fixture.name == "RSA" { attachScreenshot("Import RSA key with native paste control") }
            let save = app.buttons["Validate & Import"]
            for _ in 0..<3 where !save.isHittable { app.swipeUp() }
            save.tap()
            let algorithm = app.staticTexts["Algorithm, " + fixture.name]
            XCTAssertTrue(algorithm.waitForExistence(timeout: 10), app.debugDescription)
            let publicKey = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.algorithm + " AAAA")).firstMatch
            XCTAssertTrue(publicKey.exists, app.debugDescription)
            XCTAssertEqual(publicKey.label, fixture.publicKey)
            attachScreenshot("Imported " + fixture.name + " key details")
            let delete = app.buttons["Delete Identity"]
            for _ in 0..<6 where !delete.isHittable { app.swipeUp() }
            delete.tap()
            try XCTUnwrap(app.buttons.matching(identifier: "Delete Identity").allElementsBoundByIndex.last).tap()
            XCTAssertTrue(publicKey.waitForNonExistence(timeout: 10))
            app.terminate()
        }
    }

    func testKeyDetailsShowFingerprintAndPublicKeyWithoutAddedHyphens() throws {
        continueAfterFailure = false
        let app = XCUIApplication.underTest()
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons["SSH Keys"].tap()
        let generate = try XCTUnwrap(app.buttons.matching(identifier: "Generate Key").allElementsBoundByIndex.first(where: { $0.isHittable }))
        XCTAssertTrue(generate.isEnabled, "Key generation is unavailable; the app may still be in Demo")
        generate.tap()
        let name = app.textFields["Identity name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("UI test fingerprint wrap")
        try XCTUnwrap(app.buttons.matching(identifier: "Generate Key").allElementsBoundByIndex.first(where: { $0.isHittable })).tap()

        let fingerprintPrefix = "SHA-256 fingerprint, SHA256:"
        let fingerprint = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", fingerprintPrefix)).firstMatch
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 10), app.debugDescription)
        let digest = String(fingerprint.label.dropFirst(fingerprintPrefix.count))
        XCTAssertEqual(digest.count, 43, "Unpadded base64 SHA-256 digest: \(digest)")
        XCTAssertFalse(digest.contains("-"), "Fingerprint must not contain hyphens: \(digest)")
        XCTAssertGreaterThan(fingerprint.frame.height, 20, "The fingerprint should wrap at this width, exercising the line break")
        let publicKey = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 AAAA")).firstMatch
        XCTAssertTrue(publicKey.exists, app.debugDescription)
        let blob = publicKey.label.split(separator: " ")[1]
        XCTAssertFalse(blob.contains("-"), "Public key data must not contain hyphens: \(blob)")
        attachScreenshot("Key details with wrapped fingerprint")

        let delete = app.buttons["Delete Identity"]
        for _ in 0..<5 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons.matching(identifier: "Delete Identity").allElementsBoundByIndex.last
        try XCTUnwrap(confirm).tap()
        XCTAssertTrue(fingerprint.waitForNonExistence(timeout: 10), "The test identity must be removed")
    }

    func testRelativeDocumentNavigationKeepsBackReadingPosition() throws {
        continueAfterFailure = false
        let app = launchDemoReader(filename: "Navigation guide.md")
        let rendered = app.scrollViews["Rendered Markdown document"]
        let nested = try revealDocumentLink("Open nested note", in: app, scroll: rendered)
        let before = nested.frame
        let marker = app.staticTexts["Navigation return marker"]
        XCTAssertTrue(marker.isHittable, "The return marker should be on screen beside the selected link")
        let markerY = marker.frame.minY
        nested.tap()
        XCTAssertTrue(app.navigationBars["Linked notes.md"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Linked note marker"].waitForExistence(timeout: 10))

        // Exercise the actual native Back button, not another link to a new copy of the guide.
        let back = app.navigationBars.buttons["Navigation guide.md"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(app.navigationBars["Navigation guide.md"].waitForExistence(timeout: 5))
        let restored = documentLink("Open nested note", in: rendered)
        XCTAssertTrue(restored.waitForExistence(timeout: 5) && restored.isHittable,
                      "Back should return to the selected link without scrolling from the top")
        XCTAssertEqual(restored.frame.minY, before.minY, accuracy: 4,
                       "Back should preserve the link's vertical reading position")
        XCTAssertTrue(marker.isHittable)
        XCTAssertEqual(marker.frame.minY, markerY, accuracy: 4)
        XCTAssertFalse(app.staticTexts["Previously loaded copy · refreshing…"].exists,
                       "Returning to an unchanged reader should not refetch it")
        attachScreenshot("Relative document native Back position")

        // The nested document may reach its parent within the connection's starting folder.
        restored.tap()
        XCTAssertTrue(app.navigationBars["Linked notes.md"].waitForExistence(timeout: 10))
        let parent = try revealDocumentLink("Open parent guide", in: app,
                                            scroll: app.scrollViews["Rendered Markdown document"])
        parent.tap()
        XCTAssertTrue(app.navigationBars["Navigation guide.md"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Navigation guide"].waitForExistence(timeout: 10))
    }

    func testRelativeDocumentErrorsKeepCurrentReaderAndExplainRecovery() throws {
        continueAfterFailure = false
        let app = launchDemoReader(filename: "Navigation guide.md")
        let scroll = app.scrollViews["Rendered Markdown document"]
        for (label, explanation) in [
            ("Missing heading", "could not be found"),
            ("Missing file", "could not be found"),
            ("Outside starting folder", "leaves the connection’s starting folder"),
            ("Unsupported archive", "isn’t a supported document, image, or PDF")
        ] {
            let link = try revealDocumentLink(label, in: app, scroll: scroll)
            link.tap()
            let alert = app.alerts["Couldn’t open link"]
            XCTAssertTrue(alert.waitForExistence(timeout: 10), "Expected an actionable error for \(label).\n" + app.debugDescription)
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", explanation)).firstMatch.exists,
                          "The link error should explain how to recover: \(label)")
            alert.buttons["OK"].tap()
            XCTAssertTrue(app.navigationBars["Navigation guide.md"].exists)
            XCTAssertTrue(documentLink(label, in: scroll).isHittable,
                          "Dismissing the error should retain the current document and reading position")
        }
        attachScreenshot("Relative document errors retain reader")
    }

    func testOriginalExportSystemPickerCancellationKeepsReaderUsable() throws {
        continueAfterFailure = false
        let app = launchDemoReader(filename: "Example.swift", markdown: false)
        let export = app.buttons["Save Original to Files"]
        XCTAssertTrue(export.waitForExistence(timeout: 5) && export.isEnabled)
        for _ in 0..<2 {
            export.tap()
            XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 45),
                          "The original should prepare and open the system Save to Files picker.\n" + app.debugDescription)
            attachScreenshot("Original file native Save to Files picker")
            cancelOriginalExport(in: app)
            XCTAssertTrue(app.navigationBars["Example.swift"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textViews["Bounded source text"].exists)
            let ready = expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: export)
            wait(for: [ready], timeout: 5)
        }
        app.buttons["Document actions"].tap()
        XCTAssertTrue(app.buttons["Copy Source"].waitForExistence(timeout: 5),
                      "Cancelling export should leave the reader's existing actions usable")
    }

    private func cancelOriginalExport(in app: XCUIApplication) {
        let cancel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            // This Files version retains a hidden Cancel accessibility element.
            // Dismiss the real native page sheet through its header gesture.
            let header = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            let start = header.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.25))
            let end = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.8))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: app.buttons["Save"])
        wait(for: [gone], timeout: 10)
    }

    private func dismissDocumentActions(in app: XCUIApplication) {
        // The trailing-anchored native menu can cover the title and screen centre.
        // Its left margin remains outside the menu; assert dismissal before proceeding.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        XCTAssertFalse(app.buttons["Source Copied"].exists, "The native actions menu must be dismissed before navigating or changing reading mode")
        XCTAssertFalse(app.buttons["Copy Source"].exists)
    }

    private func launchDemoSearchSamples() -> XCUIApplication {
        let app = XCUIApplication.underTest(); app.launchArguments = ["--demo"]; app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        waitUntilHittable(projects); projects.tap()
        let samples = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search samples, Folder")).firstMatch
        revealFolderRow(samples, in: app).tap()
        XCTAssertTrue(app.navigationBars["Search samples"].waitForExistence(timeout: 10))
        return app
    }

    private func launchDemoReader(filename: String, markdown: Bool = true) -> XCUIApplication {
        let app = XCUIApplication.underTest()
        app.launchArguments = ["--demo"]
        app.launch()
        let projects = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Projects, Studio Server")).firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 15))
        projects.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
        revealFolderRow(file, in: app).tap()
        XCTAssertTrue(app.navigationBars[filename].waitForExistence(timeout: 10))
        XCTAssertTrue((markdown ? app.scrollViews["Rendered Markdown document"] : app.textViews["Bounded source text"]).waitForExistence(timeout: 15))
        return app
    }

    /// List virtualizes off-screen rows, so existence is checked while revealing. XCTest also
    /// reports a row under the bottom search bar as hittable while the bar takes its tap, so
    /// drag in short, momentum-free steps until the whole row lies inside the list and above it.
    @discardableResult
    private func revealFolderRow(_ row: XCUIElement, in app: XCUIApplication,
                                 searchingDown: Bool = true) -> XCUIElement {
        // iPad keeps a separate sidebar list and puts search above the folder. Scroll
        // the folder's own viewport; only a bottom search bar obscures its lower rows.
        let list = app.collectionViews.matching(NSPredicate(format: "identifier != %@", "workspace-library")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<16 {
            let search = app.searchFields.firstMatch
            let bottomSearch = search.exists && search.frame.minY > list.frame.midY
            let top = search.exists && !bottomSearch ? max(list.frame.minY, search.frame.maxY + 16) : list.frame.minY
            let bottom = bottomSearch ? min(list.frame.maxY, search.frame.minY - 16) : list.frame.maxY
            if row.exists, row.isHittable, row.frame.minY >= top, row.frame.maxY <= bottom { return row }
            let down = row.exists ? row.frame.maxY > bottom : searchingDown
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.65 : 0.35))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.65))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTFail("Could not reveal folder row clear of the bars.\n" + app.debugDescription)
        return row
    }

    private func documentLink(_ label: String, in reader: XCUIElement) -> XCUIElement {
        // Offline readers are presented above the library. App-wide queries also
        // traverse that underlying hierarchy and can exhaust XCTest's query timeout.
        let link = reader.links[label].firstMatch
        if link.exists { return link }
        // Native attributed Text may expose a single-link paragraph as static text.
        return reader.staticTexts[label].firstMatch
    }

    private func revealDocumentLink(_ label: String, in app: XCUIApplication,
                                    scroll: XCUIElement) throws -> XCUIElement {
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        for _ in 0..<24 {
            let link = documentLink(label, in: scroll)
            // XCTest can report links under the Home indicator as hittable.
            // Tap only after the whole link lies within the reading viewport.
            let safeViewport = scroll.frame.insetBy(dx: 0, dy: 44)
            if link.exists && link.isHittable && safeViewport.contains(link.frame) { return link }
            scroll.swipeUp(velocity: .fast)
        }
        let link = documentLink(label, in: scroll)
        XCTAssertTrue(link.exists && link.isHittable, "Could not reach the Demo link: \(label).\n" + app.debugDescription)
        return link
    }

    private func waitForBackground(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Use native application-state observation, then validate the final state.
        // A fast suspension can skip the transient running-background state.
        _ = app.wait(for: .runningBackground, timeout: 5)
        let state = app.state
        XCTAssertTrue(state == .runningBackground || state == .runningBackgroundSuspended,
                      "Expected a live background app, got \(state)", file: file, line: line)
    }

    private func waitUntilHittable(_ element: XCUIElement, _ message: String = "", timeout: TimeInterval = 15) {
        // XCTest can expose launch-time elements before their window has geometry.
        // Asking for hittability at an infinite/empty frame throws instead of waiting.
        let hittable = expectation(for: NSPredicate { _, _ in
            guard element.exists else { return false }
            let frame = element.frame
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else { return false }
            return element.isHittable
        }, evaluatedWith: element)
        hittable.expectationDescription = message.isEmpty ? element.description : message
        wait(for: [hittable], timeout: timeout)
    }
    /// A narrow workspace, such as an unfolded iPhone Duo, closes its library and folder overlays
    /// after a selection. Each sidebar button tap brings back one more column.
    private func revealWorkspaceColumn(containing element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<2 {
            if element.waitForExistence(timeout: 2), element.isHittable { return }
            let toggle = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "ToggleSidebar", ["Show Sidebar", "Hide Sidebar"]))
                .allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(toggle, app.debugDescription); toggle?.tap()
        }
        waitUntilHittable(element)
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
        let app = XCUIApplication.underTest()
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
        let app = XCUIApplication.underTest()
        app.launch()
        let connectionName = "My MacBook"
        let connection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", connectionName + ",")).firstMatch
        if !connection.waitForExistence(timeout: 2) {
            app.buttons["Add Connection"].tap()
            for (label, value) in [("Display name", connectionName), ("Hostname or IP address", host), ("Account username", username), ("Starting directory (optional)", directory)] {
                let field = app.textFields[label]
                if !field.isHittable { app.swipeUp() }
                field.tap(); field.typeText(value)
            }
            let tailscale = app.switches["Show Tailscale Setup Tips"]
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
        XCTAssertTrue(app.textViews["Bounded source text"].waitForExistence(timeout: 5))
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
        let app = XCUIApplication.underTest()
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
        // The lazy folder list only creates rows near the screen; scroll until the report row exists.
        for _ in 0..<10 where !report.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(report.exists, app.debugDescription)
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
        let app = XCUIApplication.underTest(); app.launch()
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
        XCTAssertTrue(app.staticTexts.matching(identifier: "PDF page indicator").matching(NSPredicate(format: "label == %@", "Page 1 of 1")).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        let pdf = XCTAttachment(screenshot: app.screenshot()); pdf.name = "Real SFTP PDF preview"; pdf.lifetime = .keepAlways; add(pdf)
        back()

        open("sample.csv")
        XCTAssertTrue(app.textViews["Bounded source text"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "name,count")).firstMatch.exists)
    }
}

extension RealServerUITests {
    func testAuditRemoteInlineImages() throws {
        try enabled()
        let app = XCUIApplication.underTest(); app.launch()
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
        let app = XCUIApplication.underTest(); app.launch()
        let connection = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Image checks,")).firstMatch
        if !connection.waitForExistence(timeout: 2) {
            let add = app.buttons["Add Connection"]
            if !add.isHittable { app.swipeUp() }
            add.tap()
            for (label, value) in [("Display name", "Image checks"), ("Hostname or IP address", "100.125.79.6"), ("Account username", "iris"), ("Starting directory (optional)", "/Users/iris/Developer/RemoteFiles/.test-server/remote-images")] {
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
        let app = XCUIApplication.underTest(); app.launch()
        let readme = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "README.md,")).firstMatch
        XCTAssertTrue(readme.waitForExistence(timeout: 10), app.debugDescription)
        if !readme.isHittable { app.swipeUp() }
        readme.tap()
        let heading = app.staticTexts["Build and run"]
        XCTAssertTrue(heading.waitForExistence(timeout: 12), "Image-free README must render visible content, not merely an empty scroll view.\n" + app.debugDescription)
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "README rendered"; initial.lifetime = .keepAlways; add(initial)
        app.buttons["Source"].tap()
        XCTAssertTrue(app.textViews["Bounded source text"].waitForExistence(timeout: 5))
        app.buttons["Rendered"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        app.buttons["Document actions"].tap(); app.buttons["Refresh"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
    }
}

extension RealServerUITests {
    func testBackgroundReconnectsToChangedRealServerDocument() throws {
        try enabled()
        let app = XCUIApplication.underTest()
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
        let app = XCUIApplication.underTest()
        app.launch()
        let localProfile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Local network check,")).firstMatch
        if !localProfile.waitForExistence(timeout: 2) {
            let add = app.buttons["Add Connection"]
            if !add.isHittable { app.swipeUp() }
            add.tap()
            for (label, value) in [("Display name", "Local network check"),
                                   ("Hostname or IP address", host),
                                   ("Account username", "iris"),
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
