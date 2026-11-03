#if os(iOS)
import SwiftUI
import UIKit

/// Focused values hold closures, which SwiftUI can only compare byte by byte: a new closure on
/// every render looks like a new value and re-renders the publisher without end. Each action set
/// is therefore equal when its context, titles and available actions are. The closures act on
/// `@State` storage and stable models, so an equal older copy still acts on the current state.
private func available(_ actions: [(() -> Void)?]) -> [Bool] { actions.map { $0 != nil } }

/// What the visible reader can do from the menu bar or a hardware keyboard. A nil action is
/// unavailable, so its menu item is disabled and its shortcut does nothing.
struct ReaderCommandActions: Equatable {
    /// Identifies the document the closures act on.
    var context: String
    var refresh: (() -> Void)?
    var find: (() -> Void)?
    var findNext: (() -> Void)?
    var findPrevious: (() -> Void)?
    var headings: (() -> Void)?
    var toggleSource: (() -> Void)?
    /// Closes an open Find bar, whether or not its field has focus.
    var closeFind: (() -> Void)?
    var showsSource = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context == rhs.context && lhs.showsSource == rhs.showsSource
            && available([lhs.refresh, lhs.find, lhs.findNext, lhs.findPrevious, lhs.headings, lhs.toggleSource, lhs.closeFind])
            == available([rhs.refresh, rhs.find, rhs.findNext, rhs.findPrevious, rhs.headings, rhs.toggleSource, rhs.closeFind])
    }
}

/// What the visible folder can do from the menu bar or a hardware keyboard.
struct FolderCommandActions: Equatable {
    /// Identifies the folder the closures act on.
    var context: String
    var refresh: () -> Void
    var search: () -> Void
    var toggleHidden: () -> Void
    var showsHidden: Bool
    var enclosingFolder: (() -> Void)?
    /// Moves the keyboard selection through the rows on screen: +1 is down, -1 is up.
    var moveSelection: ((Int) -> Void)?
    /// Opens the selected row, as tapping it would.
    var openSelection: (() -> Void)?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context == rhs.context && lhs.showsHidden == rhs.showsHidden
            && available([lhs.enclosingFolder, lhs.openSelection]) == available([rhs.enclosingFolder, rhs.openSelection])
            && (lhs.moveSelection == nil) == (rhs.moveSelection == nil)
    }
}

/// Back, and the library's own destinations, for whichever navigation is in front.
struct NavigationCommandActions: Equatable {
    /// Identifies the navigation the closures act on.
    var context: String
    var back: (() -> Void)?
    var downloads: (() -> Void)?
    var offlineFiles: (() -> Void)?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context == rhs.context
            && available([lhs.back, lhs.downloads, lhs.offlineFiles]) == available([rhs.back, rhs.downloads, rhs.offlineFiles])
    }
}

/// Each value is published by at most one view at a time: the reader, folder or navigation that
/// is in front. Views covered by a stacked view or a library sheet publish nil.
extension FocusedValues {
    @Entry var readerCommands: ReaderCommandActions?
    @Entry var folderCommands: FolderCommandActions?
    @Entry var navigationCommands: NavigationCommandActions?
}

extension FocusedValues {
    /// Set by sheets and full-screen covers a reader or folder presents itself.
    @Entry var keyboardCommandsCovered: Bool?
}

extension View {
    /// Marks a sheet or cover presented from a reader or folder. While it shows, the reader,
    /// folder and navigation beneath ignore shortcuts, since they stay published behind it.
    func coversKeyboardCommands() -> some View { focusedSceneValue(\.keyboardCommandsCovered, true) }
}

/// Hardware-keyboard shortcuts, listed in the iPad menu bar and the ⌘ shortcut overlay.
public struct RemoteFilesCommands: Commands {
    @FocusedValue(\.readerCommands) private var publishedReader
    @FocusedValue(\.folderCommands) private var publishedFolder
    @FocusedValue(\.navigationCommands) private var publishedNavigation
    @FocusedValue(\.keyboardCommandsCovered) private var covered
    private var reader: ReaderCommandActions? { covered == true ? nil : publishedReader }
    private var folder: FolderCommandActions? { covered == true ? nil : publishedFolder }
    private var navigation: NavigationCommandActions? { covered == true ? nil : publishedNavigation }
    public init() {}

    public var body: some Commands {
        // Find, Find Next and Find Previous are the system's own Edit › Find items (⌘F, ⌘G, ⇧⌘G);
        // RemoteFilesAppDelegate answers them for this reader.
        let _ = SystemFindRouter.shared.reader = reader
        // Escape, Up, Down and Return are UIKit key commands instead; see PlainKeyCommands.
        let _ = PlainKeyCommands.shared.folder = folder
        let _ = PlainKeyCommands.shared.closeFind = reader?.closeFind
        CommandGroup(after: .textEditing) {
            Button("Search Folder", systemImage: "folder.badge.questionmark") { folder?.search() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(folder == nil)
        }
        CommandGroup(after: .toolbar) {
            Button(reader?.showsSource == true ? "Show Rendered" : "Show Source", systemImage: "chevron.left.forwardslash.chevron.right") { reader?.toggleSource?() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(reader?.toggleSource == nil)
            Button(folder?.showsHidden == true ? "Hide Hidden Files" : "Show Hidden Files", systemImage: "eye") { folder?.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(folder == nil)
            Divider()
            Button("Refresh Document", systemImage: "arrow.clockwise") { reader?.refresh?() }
                .keyboardShortcut("r")
                .disabled(reader?.refresh == nil)
            Button("Refresh Folder", systemImage: "arrow.clockwise") { folder?.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(folder == nil)
        }
        CommandMenu("Go") {
            Button("Back", systemImage: "chevron.left") { navigation?.back?() }
                .keyboardShortcut("[")
                .disabled(navigation?.back == nil)
            Button("Enclosing Folder", systemImage: "arrow.up") { folder?.enclosingFolder?() }
                .keyboardShortcut(.upArrow)
                .disabled(folder?.enclosingFolder == nil)
            Button("Headings…", systemImage: "list.bullet.indent") { reader?.headings?() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(reader?.headings == nil)
            Divider()
            Button("Downloads", systemImage: "arrow.down.circle") { navigation?.downloads?() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(navigation?.downloads == nil)
            Button("Offline Files", systemImage: "pin") { navigation?.offlineFiles?() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(navigation?.offlineFiles == nil)
        }
    }
}

/// The reader the system Find items act on: the commands' focused value, kept here because the
/// app delegate that answers those items is outside SwiftUI's view hierarchy.
@MainActor final class SystemFindRouter {
    static let shared = SystemFindRouter()
    var reader: ReaderCommandActions?
}

/// Keys without modifiers: Escape closes Find, Up and Down move the folder's keyboard selection,
/// and Return opens it. They are UIKit key commands on the scene's root view controller rather
/// than menu commands, for two reasons. On iPad the focus engine takes arrow keys before any menu
/// command, to focus the library sidebar, so these ask for priority over system behaviour. And
/// each decides as its key arrives whether to act (see `RemoteFilesAppDelegate.responds(to:)`);
/// declining passes the key on, so text fields being edited, items focused with Tab, and alerts,
/// menus, pickers or sheets presented over the content keep their keys. Their titles list them in
/// the ⌘ overlay.
@MainActor final class PlainKeyCommands: NSObject {
    static let shared = PlainKeyCommands()
    private weak var root: UIViewController?
    /// Set while the Offline Files sheet shows. Focused values from inside the sheet don't reach
    /// the scene's commands, so its reader hands over closing Find directly while Find is open.
    /// The sheet takes Escape to dismiss itself before the root sees it, so while that reader's
    /// Find is open, Escape is installed on the sheet too; otherwise Escape still dismisses it.
    var offlineFilesShows = false { didSet { installOnOfflineFiles() } }
    var offlineCloseFind: (() -> Void)? { didSet { installOnOfflineFiles() } }
    private let sheetEscape = command("Close Find", UIKeyCommand.inputEscape, [], #selector(RemoteFilesAppDelegate.closeReaderFind(_:)))
    private weak var sheet: UIViewController?
    private func installOnOfflineFiles() {
        sheet?.removeKeyCommand(sheetEscape); sheet = nil
        guard offlineFilesShows, offlineCloseFind != nil, let presented = root?.presentedViewController else { return }
        presented.addKeyCommand(sheetEscape); sheet = presented
    }
    /// Set while the scene's commands update.
    var folder: FolderCommandActions?
    var closeFind: (() -> Void)?
    let escape = command("Close Find", UIKeyCommand.inputEscape, [], #selector(RemoteFilesAppDelegate.closeReaderFind(_:)))
    let next = command("Select Next", UIKeyCommand.inputDownArrow, [], #selector(RemoteFilesAppDelegate.selectNextFolderRow(_:)))
    let previous = command("Select Previous", UIKeyCommand.inputUpArrow, [], #selector(RemoteFilesAppDelegate.selectPreviousFolderRow(_:)))
    let open = command("Open Selection", "\r", [], #selector(RemoteFilesAppDelegate.openSelectedFolderRow(_:)))
    /// Tab and Shift-Tab, noticed and then declined, so they still move focus.
    let tabs = [UIKeyModifierFlags(), .shift].map { command(nil, "\t", $0, #selector(RemoteFilesAppDelegate.noticeTab(_:))) }
    private static func command(_ title: String?, _ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
        let command = title.map { UIKeyCommand(title: $0, action: action, input: input, modifierFlags: modifiers) }
            ?? UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)), name: UIWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)), name: UIFocusSystem.didUpdateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged(_:)), name: UITextField.textDidBeginEditingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editingChanged(_:)), name: UITextField.textDidEndEditingNotification, object: nil)
    }
    /// The text field being edited keeps the arrows and Return; a search field keeps Escape too,
    /// while Escape still closes Find from the Find field itself.
    private(set) weak var editingField: UITextField?
    @objc private func editingChanged(_ notification: Notification) {
        guard let field = notification.object as? UITextField else { return }
        if notification.name == UITextField.textDidBeginEditingNotification { editingField = field }
        else if editingField === field { editingField = nil }
    }
    @objc private func windowBecameKey(_ notification: Notification) {
        if let root = (notification.object as? UIWindow)?.rootViewController { attach(root) }
    }
    /// Installs the commands on the key window's root view controller once.
    func attach(_ root: UIViewController) {
        guard root !== self.root else { return }
        self.root = root
        for command in tabs + [escape, next, previous, open] where root.keyCommands?.contains(command) != true {
            root.addKeyCommand(command)
        }
    }

    /// Closes Find in the reader in front: the root's, or Offline Files' while that sheet is in front.
    var frontmostCloseFind: (() -> Void)? {
        guard let root else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        if top === root { return closeFind }
        return offlineFilesShows && top.presentingViewController === root ? offlineCloseFind : nil
    }

    /// Whether the key for `action` acts now, checked as it arrives.
    func canPerform(_ action: Selector) -> Bool {
        if action == escape.action || action == sheetEscape.action { return frontmostCloseFind != nil && !(editingField is UISearchTextField) }
        guard let root, root.presentedViewController == nil else { return false }
        guard editingField == nil, !userMovedFocus else { return false }
        if action == next.action || action == previous.action { return folder?.moveSelection != nil }
        if action == open.action { return folder?.openSelection != nil }
        return false
    }

    /// The user moved keyboard focus with Tab, into the library sidebar say, so the arrows and
    /// Return keep acting on it until focus leaves. Only Tab starts this: focus the system restores
    /// after an alert, or an arrow that reached the focus engine while a folder loaded, doesn't.
    private(set) var userMovedFocus = false
    private var lastTab = Date.distantPast
    func tabPressed() { lastTab = .now }
    @objc private func focusChanged(_ notification: Notification) {
        let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
        focusMoved(to: context?.nextFocusedItem != nil)
    }
    func focusMoved(to item: Bool) {
        if !item { userMovedFocus = false }
        else if Date.now.timeIntervalSince(lastTab) < 1 { userMovedFocus = true }
    }
}

/// UIKit's Edit › Find items own ⌘F, ⌘G and ⇧⌘G, so UIKit drops SwiftUI commands that use those
/// keys. The items send `find:`, `findNext:` and `findPrevious:` up the responder chain, which
/// ends at the app delegate; SwiftUI's delegate passes them on to this adaptor. Install it with
/// `@UIApplicationDelegateAdaptor`.
public final class RemoteFilesAppDelegate: UIResponder, UIApplicationDelegate {
    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = PlainKeyCommands.shared // Watches for the window that becomes key.
        return true
    }
    @objc func closeReaderFind(_ sender: Any?) { PlainKeyCommands.shared.frontmostCloseFind?() }
    @objc func selectNextFolderRow(_ sender: Any?) { PlainKeyCommands.shared.folder?.moveSelection?(1) }
    @objc func selectPreviousFolderRow(_ sender: Any?) { PlainKeyCommands.shared.folder?.moveSelection?(-1) }
    @objc func openSelectedFolderRow(_ sender: Any?) { PlainKeyCommands.shared.folder?.openSelection?() }
    @objc func noticeTab(_ sender: Any?) {}
    /// UIKit asks whether a key command's action has a target as its key arrives, and SwiftUI's
    /// delegate asks this adaptor. Answering no lets the key go on to the system: Tab moves focus,
    /// and an alert or menu over the window keeps Escape, Return and the arrows.
    override public func responds(to aSelector: Selector!) -> Bool {
        let keys = PlainKeyCommands.shared
        if aSelector == #selector(noticeTab(_:)) { keys.tabPressed(); return false }
        if [keys.escape, keys.next, keys.previous, keys.open].contains(where: { $0.action == aSelector }) {
            return keys.canPerform(aSelector)
        }
        return super.responds(to: aSelector)
    }
    override public func find(_ sender: Any?) { SystemFindRouter.shared.reader?.find?() }
    override public func findNext(_ sender: Any?) { SystemFindRouter.shared.reader?.findNext?() }
    override public func findPrevious(_ sender: Any?) { SystemFindRouter.shared.reader?.findPrevious?() }
}
#endif
