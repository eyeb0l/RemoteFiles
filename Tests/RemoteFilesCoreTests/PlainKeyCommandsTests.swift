#if os(iOS)
import XCTest
import UIKit
import SwiftUI
@testable import RemoteFilesUI

@MainActor final class PlainKeyCommandsTests: XCTestCase {
    // A hosted focus wait returned after 14 seconds with the required state. These tests
    // assert responder ownership, not a five-second performance target. See docs/CI_HISTORY.md.
    private let focusTimeout: TimeInterval = 30

    func testArrowsMoveSelectionAndStopAtEitherEnd() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(FolderKeyboardSelection.moved(nil, by: 1, in: ids), "a", "Down starts at the top")
        XCTAssertEqual(FolderKeyboardSelection.moved(nil, by: -1, in: ids), "c", "Up starts at the bottom")
        XCTAssertEqual(FolderKeyboardSelection.moved("a", by: 1, in: ids), "b")
        XCTAssertEqual(FolderKeyboardSelection.moved("b", by: -1, in: ids), "a")
        XCTAssertEqual(FolderKeyboardSelection.moved("c", by: 1, in: ids), "c")
        XCTAssertEqual(FolderKeyboardSelection.moved("a", by: -1, in: ids), "a")
        XCTAssertEqual(FolderKeyboardSelection.moved("gone", by: 1, in: ids), "a", "A filtered-out selection starts again")
        XCTAssertNil(FolderKeyboardSelection.moved("a", by: 1, in: []))
    }

    func testCommandsAreInstalledOnceWithPriority() {
        let keys = PlainKeyCommands(), root = UIViewController()
        keys.attach(root)
        keys.attach(root)
        let commands = root.keyCommands ?? []
        XCTAssertEqual(commands.compactMap(\.input).sorted(),
                       ["\t", "\t", "\r", UIKeyCommand.inputDownArrow, UIKeyCommand.inputEscape, UIKeyCommand.inputUpArrow].sorted())
        XCTAssertEqual(commands.filter { $0.input == "\t" }.map(\.modifierFlags), [[], .shift])
        XCTAssertTrue(commands.allSatisfy { $0.modifierFlags.isEmpty || $0.input == "\t" })
        // The iPad focus engine and text fields would otherwise take these keys first.
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))
        XCTAssertEqual(Set(commands.map(\.title)), ["", "Select Next", "Select Previous", "Open Selection", "Close Find"])
    }

    func testKeysActOnlyForAvailableActionsInTheFrontmostContent() {
        let keys = PlainKeyCommands(), root = UIViewController()
        XCTAssertFalse(keys.canPerform(next), "Nothing acts before a window attaches")
        keys.attach(root)
        XCTAssertFalse(keys.canPerform(next), "No folder is published yet")
        XCTAssertFalse(keys.canPerform(escape))

        keys.folder = folder(move: true, open: false)
        XCTAssertTrue(keys.canPerform(next))
        XCTAssertTrue(keys.canPerform(previous))
        XCTAssertFalse(keys.canPerform(open), "Return waits for a selection")
        XCTAssertFalse(keys.canPerform(escape), "Escape waits for an open Find")
        keys.folder = folder(move: true, open: true); keys.closeFind = {}
        XCTAssertTrue(keys.canPerform(open))
        XCTAssertTrue(keys.canPerform(escape))
        XCTAssertFalse(keys.canPerform(#selector(RemoteFilesAppDelegate.noticeTab(_:))))

        // With nothing presented, Escape closes the root's reader's Find, never Offline Files'.
        var closed = ""
        keys.closeFind = { closed = "root" }
        keys.setOfflineReader(UUID(), ReaderCommandActions(context: "offline", closeFind: { closed = "offline" }), in: UUID())
        keys.frontmostCloseFind?()
        XCTAssertEqual(closed, "root")
        keys.closeFind = nil
        XCTAssertNil(keys.frontmostCloseFind)
        XCTAssertFalse(keys.canPerform(escape))

    }

    func testFocusMovedWithTabKeepsArrowsAndReturnButNotRestoredFocus() {
        let keys = PlainKeyCommands(), root = UIViewController()
        keys.attach(root)
        keys.folder = folder(move: true, open: true); keys.closeFind = {}

        // Focus the system restores after an alert, or an arrow that reached the focus engine while
        // the folder loaded, leaves the arrows with the folder.
        keys.focusMoved(to: true)
        XCTAssertTrue(keys.canPerform(next) && keys.canPerform(open))

        // Focus moved with Tab, or then with the arrows, keeps them until it leaves; Escape still closes Find.
        keys.tabPressed()
        keys.focusMoved(to: true)
        XCTAssertFalse(keys.canPerform(next) || keys.canPerform(previous) || keys.canPerform(open))
        XCTAssertTrue(keys.canPerform(escape))
        keys.focusMoved(to: true)
        XCTAssertFalse(keys.canPerform(next))
        keys.focusMoved(to: false)
        XCTAssertTrue(keys.canPerform(next) && keys.canPerform(open))
    }

    func testTextFieldsBeingEditedKeepArrowsAndReturnAndSearchFieldsKeepEscape() {
        let keys = PlainKeyCommands(), root = UIViewController()
        keys.attach(root)
        keys.folder = folder(move: true, open: true); keys.closeFind = {}
        func edit(_ field: UITextField, _ name: Notification.Name) { NotificationCenter.default.post(name: name, object: field) }

        let find = UITextField()
        edit(find, UITextField.textDidBeginEditingNotification)
        XCTAssertFalse(keys.canPerform(next) || keys.canPerform(previous) || keys.canPerform(open), "The Find field keeps the arrows and Return")
        XCTAssertTrue(keys.canPerform(escape), "Escape closes Find from its own field")
        edit(find, UITextField.textDidEndEditingNotification)
        XCTAssertTrue(keys.canPerform(next) && keys.canPerform(open))

        let search = UISearchTextField()
        edit(search, UITextField.textDidBeginEditingNotification)
        XCTAssertFalse(keys.canPerform(escape) || keys.canPerform(next) || keys.canPerform(open), "The folder's search field keeps its keys")
        edit(find, UITextField.textDidEndEditingNotification)
        XCTAssertFalse(keys.canPerform(escape), "Another field ending doesn't end this one")
        edit(search, UITextField.textDidEndEditingNotification)
        XCTAssertTrue(keys.canPerform(escape) && keys.canPerform(next))
    }

    /// Nothing published inside the Offline Files sheet reaches the scene's commands, so its keys
    /// are key commands on the sheet, installed while it shows and declined while unavailable.
    func testOfflineFilesSheetTakesItsKeysWhileItShows() {
        let keys = PlainKeyCommands(), root = UIViewController(), sheet = UIViewController()
        let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene).map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        keys.attach(root)
        present(sheet, from: root)
        XCTAssertTrue(root.presentedViewController === sheet)
        let scope = UUID()
        keys.attachOfflineFiles(sheet, in: scope)
        let titles = { Set(sheet.keyCommands?.map(\.title) ?? []) }
        XCTAssertEqual(titles(), ["Close Find", "Back", "Find", "Find Next", "Find Previous", "Show Source", "Headings…"], "The sheet's keys are installed as soon as it shows")
        XCTAssertTrue(sheet.keyCommands?.allSatisfy(\.wantsPriorityOverSystemBehavior) == true)
        XCTAssertFalse(keys.canPerform(find) || keys.canPerform(escape) || keys.canPerform(back), "Nothing to act on, so every key declines")

        var ran = ""
        keys.setOfflineBack({ ran = "back" }, in: scope)
        XCTAssertTrue(keys.canPerform(back))
        keys.frontmostOfflineBack?(); XCTAssertEqual(ran, "back")

        // The system Find items act on the sheet's reader while it is in front, else the scene's.
        let sceneReader = SystemFindRouter.shared.reader
        defer { SystemFindRouter.shared.reader = sceneReader }
        SystemFindRouter.shared.reader = ReaderCommandActions(context: "scene", find: { ran = "scene" })
        XCTAssertNil(keys.frontmostReader, "The sheet in front with no reader hides the scene's")

        let reader = UUID()
        var actions = ReaderCommandActions(context: "offline|a", find: { ran = "find" }, toggleSource: { ran = "source" })
        keys.setOfflineReader(reader, actions, in: scope)
        XCTAssertEqual(sheet.keyCommands?.count, 7, "Handing over keeps each key installed once")
        XCTAssertTrue(keys.canPerform(find) && keys.canPerform(toggleSource))
        XCTAssertFalse(keys.canPerform(findNext) || keys.canPerform(escape), "Keys for actions the reader lacks decline; Escape waits for Find")
        keys.frontmostOfflineReader?.find?(); XCTAssertEqual(ran, "find")
        keys.frontmostReader?.find?(); XCTAssertEqual(ran, "find")

        actions.findNext = {}; actions.closeFind = { ran = "close" }; actions.showsSource = true
        keys.setOfflineReader(reader, actions, in: scope)
        XCTAssertTrue(titles().contains("Show Rendered") && !titles().contains("Show Source"), "The source key's title follows the reader")
        XCTAssertTrue(keys.canPerform(escape) && keys.canPerform(findNext))
        keys.frontmostCloseFind?(); XCTAssertEqual(ran, "close")

        // Something presented over the sheet keeps the keys.
        let headings = UIViewController()
        present(headings, from: sheet)
        XCTAssertTrue(sheet.presentedViewController === headings)
        XCTAssertFalse(keys.canPerform(find) || keys.canPerform(escape) || keys.canPerform(back))
        XCTAssertNil(keys.frontmostOfflineReader)
        XCTAssertNil(keys.frontmostReader, "A covering sheet must not restore the scene's Find actions")
        dismiss(headings)
        XCTAssertNil(sheet.presentedViewController)
        XCTAssertTrue(keys.canPerform(find) && keys.canPerform(back))

        // A reader pushed over another keeps its commands when the first hands over nil after it.
        let second = UUID()
        keys.setOfflineReader(second, ReaderCommandActions(context: "offline|b", find: { ran = "second" }), in: scope)
        keys.setOfflineReader(reader, nil, in: scope)
        keys.frontmostOfflineReader?.find?(); XCTAssertEqual(ran, "second")

        // A reader leaving the screen leaves the keys declining; the sheet closing removes them.
        keys.setOfflineReader(second, nil, in: scope)
        XCTAssertFalse(keys.canPerform(find))
        XCTAssertEqual(sheet.keyCommands?.count, 7)
        keys.removeOfflineFiles(scope)
        XCTAssertEqual(sheet.keyCommands ?? [], [])
        keys.frontmostReader?.find?(); XCTAssertEqual(ran, "scene", "With the sheet gone, the Find items act on the scene's reader")
        dismiss(sheet)
        XCTAssertNil(root.presentedViewController)
    }
    func testOfflineCommandsFollowTheirWindowAndInstallAfterActionsArrive() {
        let keys = PlainKeyCommands()
        let first = UIViewController(), second = UIViewController()
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let windows = [first, second].map { root in
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = root
            window.makeKeyAndVisible()
            return window
        }
        defer { windows.forEach { $0.isHidden = true } }
        let firstSheet = UIViewController(), secondSheet = UIViewController()
        present(firstSheet, from: first)
        present(secondSheet, from: second)
        let firstScope = UUID(), secondScope = UUID(), reader = UUID()
        var ran = ""
        // SwiftUI can publish actions before the presentation appears, with another root active.
        keys.attach(second)
        keys.setOfflineReader(reader, ReaderCommandActions(context: "first", find: { ran = "first find" },
                                                          closeFind: { ran = "first close" }), in: firstScope)
        keys.attachOfflineFiles(firstSheet, in: firstScope)
        XCTAssertEqual(firstSheet.keyCommands?.count, 7)
        XCTAssertFalse(keys.offlineFilesShows, "Another window's offline sheet does not cover this one")
        XCTAssertFalse(keys.canPerform(find) || keys.canPerform(escape))
        keys.attach(first)
        XCTAssertTrue(keys.canPerform(find) && keys.canPerform(escape))
        keys.frontmostCloseFind?(); XCTAssertEqual(ran, "first close")

        keys.setOfflineReader(reader, ReaderCommandActions(context: "second", find: { ran = "second find" }), in: secondScope)
        keys.attachOfflineFiles(secondSheet, in: secondScope)
        keys.attach(second)
        keys.frontmostReader?.find?(); XCTAssertEqual(ran, "second find")
        XCTAssertFalse(keys.canPerform(escape), "The other window's open Find cannot consume Escape here")
        keys.attach(first)
        keys.frontmostReader?.find?(); XCTAssertEqual(ran, "first find")
        XCTAssertTrue(keys.canPerform(escape))
        keys.removeOfflineFiles(secondScope)
        XCTAssertTrue(keys.canPerform(find) && keys.canPerform(escape), "Closing another sheet preserves this one's actions")
        XCTAssertEqual(firstSheet.keyCommands?.count, 7)
        keys.removeOfflineFiles(firstScope)
    }

    func testFindRelinquishesFocusWhenCoveredAndCanBeFocusedAgain() throws {
        let navigation = ReaderNavigationState()
        navigation.startFind()
        navigation.query = "paragraph"
        let host = UIHostingController(rootView: ReaderFindBar(navigation: navigation, inSource: false, isCovered: false))
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func findField(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            return view.subviews.lazy.compactMap { findField(in: $0) }.first
        }
        func cancelResponder(in view: UIView) -> FindCancelResponder.KeyView? {
            if let responder = view as? FindCancelResponder.KeyView { return responder }
            return view.subviews.lazy.compactMap { cancelResponder(in: $0) }.first
        }
        func awaitFocus(_ expected: Bool, covered: Bool = false, phase: String) {
            let started = ProcessInfo.processInfo.systemUptime
            func record(_ point: String) {
                let field = findField(in: host.view)
                print("Find focus \(phase) \(point): elapsed=\(ProcessInfo.processInfo.systemUptime - started), "
                      + "field=\(field != nil), attached=\(field?.window != nil), "
                      + "firstResponder=\(String(describing: field?.isFirstResponder)), "
                      + "keyWindow=\(window.isKeyWindow), request=\(navigation.findFocusRequest), "
                      + "cancelEnabled=\(String(describing: cancelResponder(in: host.view)?.canBecomeFirstResponder))")
            }
            XCTContext.runActivity(named: phase) { _ in
                record("start")
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    findField(in: host.view)?.isFirstResponder == expected
                        && cancelResponder(in: host.view)?.canBecomeFirstResponder == !covered
                }, object: nil)
                changed.expectationDescription = "\(phase): Find field first responder == \(expected), covered == \(covered)"
                wait(for: [changed], timeout: focusTimeout)
                record("end")
            }
        }
        awaitFocus(true, phase: "Initial Find focus")
        host.rootView = ReaderFindBar(navigation: navigation, inSource: false, isCovered: true)
        awaitFocus(false, covered: true, phase: "Headings relinquishes Find focus")
        XCTAssertTrue(navigation.isFinding, "Covering Find keeps the bar and query for its return")
        XCTAssertEqual(navigation.query, "paragraph")
        host.rootView = ReaderFindBar(navigation: navigation, inSource: false, isCovered: false)
        // Uncovering starts dismissal; the reader requests focus only when it completes.
        awaitFocus(false, phase: "Uncovered Find waits for an editing request")
        navigation.startFind()
        awaitFocus(true, phase: "Explicit Find request restores editing focus")
        XCTAssertEqual(try XCTUnwrap(findField(in: host.view)).text, "paragraph")
    }

    func testFindRestoresANativeEscapeResponderAfterHeadings() throws {
        let navigation = ReaderNavigationState()
        navigation.startFind()
        navigation.query = "paragraph"
        let host = UIHostingController(rootView: ReaderFindBar(navigation: navigation, inSource: false, isCovered: false))
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func responder(in view: UIView) -> FindCancelResponder.KeyView? {
            if let keyView = view as? FindCancelResponder.KeyView { return keyView }
            return view.subviews.lazy.compactMap { responder(in: $0) }.first
        }
        func findField(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            return view.subviews.lazy.compactMap { findField(in: $0) }.first
        }
        host.loadViewIfNeeded()
        let attached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            responder(in: host.view)?.window != nil && findField(in: host.view)?.isFirstResponder == true
        }, object: nil)
        attached.expectationDescription = "Find is attached and its initial editing focus has arrived"
        wait(for: [attached], timeout: focusTimeout)
        host.rootView = ReaderFindBar(navigation: navigation, inSource: false, isCovered: true)
        // Assigning rootView only schedules a SwiftUI update. Wait for that update and the
        // initial text-field focus to settle before starting the presentation lifecycle.
        let covered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            responder(in: host.view)?.canBecomeFirstResponder == false
                && findField(in: host.view)?.isFirstResponder == false
        }, object: nil)
        covered.expectationDescription = "Covered Find has relinquished editing and cancel focus"
        wait(for: [covered], timeout: focusTimeout)
        let headings = UIViewController()
        present(headings, from: host)
        dismiss(headings)
        host.rootView = ReaderFindBar(navigation: navigation, inSource: false, isCovered: false)
        let uncovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            responder(in: host.view)?.canBecomeFirstResponder == true
                && findField(in: host.view)?.isFirstResponder == false
        }, object: nil)
        uncovered.expectationDescription = "Uncovered Find has applied its enabled state before restoration"
        wait(for: [uncovered], timeout: focusTimeout)
        navigation.restoreFindKeyboard()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            responder(in: host.view)?.isFirstResponder == true
        }, object: nil)
        restored.expectationDescription = "Headings dismissal restores Find's native Escape responder"
        wait(for: [restored], timeout: focusTimeout)
        XCTAssertEqual(navigation.query, "paragraph")
        let key = try XCTUnwrap(responder(in: host.view)?.keyCommands?.first)
        XCTAssertEqual(key.input, UIKeyCommand.inputEscape)
        let action = try XCTUnwrap(key.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil, from: key, for: nil))
        XCTAssertFalse(navigation.isFinding, "Escape reaches Find through the restored responder chain")
        XCTAssertTrue(window.rootViewController === host, "Cancelling Find preserves the reader")
    }

    private func present(_ controller: UIViewController, from presenter: UIViewController) {
        // presentedViewController is set before UIKit attaches the view to a window. Production
        // registers in viewDidAppear, so exercise the same completed presentation lifecycle.
        let completed = expectation(description: "Presentation completed")
        presenter.present(controller, animated: false) { completed.fulfill() }
        wait(for: [completed], timeout: 5)
        XCTAssertNotNil(controller.viewIfLoaded?.window, "Commands register after the sheet is in its window")
    }

    private func dismiss(_ controller: UIViewController) {
        let completed = expectation(description: "Dismissal completed")
        controller.dismiss(animated: false) { completed.fulfill() }
        wait(for: [completed], timeout: 5)
    }

    func testAppDelegateDeclinesTabSoItStillMovesFocus() {
        XCTAssertFalse(RemoteFilesAppDelegate().responds(to: #selector(RemoteFilesAppDelegate.noticeTab(_:))))
        XCTAssertTrue(RemoteFilesAppDelegate().responds(to: #selector(UIResponder.find(_:))))
    }

    private let escape = #selector(RemoteFilesAppDelegate.closeReaderFind(_:))
    private let next = #selector(RemoteFilesAppDelegate.selectNextFolderRow(_:))
    private let previous = #selector(RemoteFilesAppDelegate.selectPreviousFolderRow(_:))
    private let open = #selector(RemoteFilesAppDelegate.openSelectedFolderRow(_:))
    private let find = #selector(RemoteFilesAppDelegate.findInOfflineReader(_:))
    private let findNext = #selector(RemoteFilesAppDelegate.findNextInOfflineReader(_:))
    private let toggleSource = #selector(RemoteFilesAppDelegate.toggleOfflineReaderSource(_:))
    private let back = #selector(RemoteFilesAppDelegate.goBackInOfflineFiles(_:))
    private func folder(move: Bool, open: Bool) -> FolderCommandActions {
        FolderCommandActions(context: "test", refresh: {}, search: {}, toggleHidden: {}, showsHidden: false,
                             moveSelection: move ? { _ in } : nil, openSelection: open ? {} : nil)
    }
}
#endif
