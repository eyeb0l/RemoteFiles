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
    var showsSource = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context == rhs.context && lhs.showsSource == rhs.showsSource
            && available([lhs.refresh, lhs.find, lhs.findNext, lhs.findPrevious, lhs.headings, lhs.toggleSource])
            == available([rhs.refresh, rhs.find, rhs.findNext, rhs.findPrevious, rhs.headings, rhs.toggleSource])
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
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.context == rhs.context && lhs.showsHidden == rhs.showsHidden
            && available([lhs.enclosingFolder]) == available([rhs.enclosingFolder])
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
/// is in front. Views covered by a stacked view, a sheet or a presented list publish nil.
extension FocusedValues {
    @Entry var readerCommands: ReaderCommandActions?
    @Entry var folderCommands: FolderCommandActions?
    @Entry var navigationCommands: NavigationCommandActions?
}

/// Hardware-keyboard shortcuts, listed in the iPad menu bar and the ⌘ shortcut overlay.
public struct RemoteFilesCommands: Commands {
    @FocusedValue(\.readerCommands) private var reader
    @FocusedValue(\.folderCommands) private var folder
    @FocusedValue(\.navigationCommands) private var navigation
    public init() {}

    public var body: some Commands {
        // Find, Find Next and Find Previous are the system's own Edit › Find items (⌘F, ⌘G, ⇧⌘G);
        // RemoteFilesAppDelegate answers them for this reader.
        let _ = SystemFindRouter.shared.reader = reader
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

/// UIKit's Edit › Find items own ⌘F, ⌘G and ⇧⌘G, so UIKit drops SwiftUI commands that use those
/// keys. The items send `find:`, `findNext:` and `findPrevious:` up the responder chain, which
/// ends at the app delegate; SwiftUI's delegate passes them on to this adaptor. Install it with
/// `@UIApplicationDelegateAdaptor`.
public final class RemoteFilesAppDelegate: UIResponder, UIApplicationDelegate {
    override public func find(_ sender: Any?) { SystemFindRouter.shared.reader?.find?() }
    override public func findNext(_ sender: Any?) { SystemFindRouter.shared.reader?.findNext?() }
    override public func findPrevious(_ sender: Any?) { SystemFindRouter.shared.reader?.findPrevious?() }
}
#endif
