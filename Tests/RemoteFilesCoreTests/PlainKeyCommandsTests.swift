#if os(iOS)
import XCTest
import UIKit
@testable import RemoteFilesUI

@MainActor final class PlainKeyCommandsTests: XCTestCase {
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
        keys.closeFind = { closed = "root" }; keys.offlineFilesShows = true
        keys.setOfflineReader(UUID(), ReaderCommandActions(context: "offline", closeFind: { closed = "offline" }))
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
        root.present(sheet, animated: false)
        settle { root.presentedViewController === sheet }
        XCTAssertTrue(root.presentedViewController === sheet)
        keys.offlineFilesShows = true
        let titles = { Set(sheet.keyCommands?.map(\.title) ?? []) }
        XCTAssertEqual(titles(), ["Close Find", "Back", "Find", "Find Next", "Find Previous", "Show Source", "Headings…"], "The sheet's keys are installed as soon as it shows")
        XCTAssertTrue(sheet.keyCommands?.allSatisfy(\.wantsPriorityOverSystemBehavior) == true)
        XCTAssertFalse(keys.canPerform(find) || keys.canPerform(escape) || keys.canPerform(back), "Nothing to act on, so every key declines")

        var ran = ""
        keys.offlineBack = { ran = "back" }
        XCTAssertTrue(keys.canPerform(back))
        keys.frontmostOfflineBack?(); XCTAssertEqual(ran, "back")

        // The system Find items act on the sheet's reader while it is in front, else the scene's.
        let sceneReader = SystemFindRouter.shared.reader
        defer { SystemFindRouter.shared.reader = sceneReader }
        SystemFindRouter.shared.reader = ReaderCommandActions(context: "scene", find: { ran = "scene" })
        XCTAssertNil(keys.frontmostReader, "The sheet in front with no reader hides the scene's")

        let reader = UUID()
        var actions = ReaderCommandActions(context: "offline|a", find: { ran = "find" }, toggleSource: { ran = "source" })
        keys.setOfflineReader(reader, actions)
        XCTAssertEqual(sheet.keyCommands?.count, 7, "Handing over keeps each key installed once")
        XCTAssertTrue(keys.canPerform(find) && keys.canPerform(toggleSource))
        XCTAssertFalse(keys.canPerform(findNext) || keys.canPerform(escape), "Keys for actions the reader lacks decline; Escape waits for Find")
        keys.frontmostOfflineReader?.find?(); XCTAssertEqual(ran, "find")
        keys.frontmostReader?.find?(); XCTAssertEqual(ran, "find")

        actions.findNext = {}; actions.closeFind = { ran = "close" }; actions.showsSource = true
        keys.setOfflineReader(reader, actions)
        XCTAssertTrue(titles().contains("Show Rendered") && !titles().contains("Show Source"), "The source key's title follows the reader")
        XCTAssertTrue(keys.canPerform(escape) && keys.canPerform(findNext))
        keys.frontmostCloseFind?(); XCTAssertEqual(ran, "close")

        // Something presented over the sheet keeps the keys.
        let headings = UIViewController()
        sheet.present(headings, animated: false)
        settle { sheet.presentedViewController === headings }
        XCTAssertTrue(sheet.presentedViewController === headings)
        XCTAssertFalse(keys.canPerform(find) || keys.canPerform(escape) || keys.canPerform(back))
        XCTAssertNil(keys.frontmostOfflineReader)
        XCTAssertNil(keys.frontmostReader, "A covering sheet must not restore the scene's Find actions")
        headings.dismiss(animated: false)
        settle { sheet.presentedViewController == nil }
        XCTAssertTrue(keys.canPerform(find) && keys.canPerform(back))

        // A reader pushed over another keeps its commands when the first hands over nil after it.
        let second = UUID()
        keys.setOfflineReader(second, ReaderCommandActions(context: "offline|b", find: { ran = "second" }))
        keys.setOfflineReader(reader, nil)
        keys.frontmostOfflineReader?.find?(); XCTAssertEqual(ran, "second")

        // A reader leaving the screen leaves the keys declining; the sheet closing removes them.
        keys.setOfflineReader(second, nil)
        XCTAssertFalse(keys.canPerform(find))
        XCTAssertEqual(sheet.keyCommands?.count, 7)
        keys.offlineFilesShows = false
        XCTAssertEqual(sheet.keyCommands ?? [], [])
        keys.frontmostReader?.find?(); XCTAssertEqual(ran, "scene", "With the sheet gone, the Find items act on the scene's reader")
        sheet.dismiss(animated: false)
        settle { root.presentedViewController == nil }
    }
    private func settle(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
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
