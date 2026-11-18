import Foundation

/// One spelling for a local file or folder that a process-wide registry shares between windows.
///
/// `standardizedFileURL` is not enough: Foundation drops a leading `/private` only when the
/// shorter path exists. On a device a library under `/private/var/…` is therefore spelt one way
/// before its file or folder is created and another way after, and a second window then opens a
/// separate store over the same files. The Simulator's paths have no `/private` alias, so this
/// shows only on hardware (or under `/private/tmp` on a Mac).
enum LocalStoreKey {
    /// Dot components are removed lexically, then only the deepest existing ancestor is resolved,
    /// since resolving a path that doesn't exist yet leaves its symlink ancestors unresolved.
    /// The final component stays unresolved, so a store still sees, and can refuse, a link there.
    static func path(of url: URL) -> String {
        var components: [String] = []
        for component in url.absoluteURL.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(String(component)) }
        }
        guard let leaf = components.popLast() else { return "/" }
        var suffix = [leaf]
        var parent = URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
        while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) {
            suffix.insert(parent.lastPathComponent, at: 0)
            parent.deleteLastPathComponent()
        }
        return suffix.reduce(parent.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
}
