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
        keys.closeFind = { closed = "root" }; keys.offlineFilesShows = true; keys.offlineCloseFind = { closed = "offline" }
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

    func testAppDelegateDeclinesTabSoItStillMovesFocus() {
        XCTAssertFalse(RemoteFilesAppDelegate().responds(to: #selector(RemoteFilesAppDelegate.noticeTab(_:))))
        XCTAssertTrue(RemoteFilesAppDelegate().responds(to: #selector(UIResponder.find(_:))))
    }

    private let escape = #selector(RemoteFilesAppDelegate.closeReaderFind(_:))
    private let next = #selector(RemoteFilesAppDelegate.selectNextFolderRow(_:))
    private let previous = #selector(RemoteFilesAppDelegate.selectPreviousFolderRow(_:))
    private let open = #selector(RemoteFilesAppDelegate.openSelectedFolderRow(_:))
    private func folder(move: Bool, open: Bool) -> FolderCommandActions {
        FolderCommandActions(context: "test", refresh: {}, search: {}, toggleHidden: {}, showsHidden: false,
                             moveSelection: move ? { _ in } : nil, openSelection: open ? {} : nil)
    }
}
#endif
