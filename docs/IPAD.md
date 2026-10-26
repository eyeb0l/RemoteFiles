# iPad workspace

<img src="screenshots/ipad/workspace.png" width="840" alt="RemoteFiles on iPad with the library, folder list and reader visible together">

*Passing iPad Pro simulator UI journey using bundled demo files.*

When both size classes are regular — an iPad window or an unfolded iPhone Duo — RemoteFiles uses three native split-view columns:

- **Library:** connections, favourites and recents, with the existing settings and connection actions.
- **Folder:** the selected folder, with search, sorting, breadcrumbs and a Previous Folder button for nested navigation.
- **Reader:** the selected file, including the existing rendered/source controls, Find, document links and export actions.

Opening another file replaces the preview while keeping its folder mounted. Selecting a new folder clears the old preview. Opening a recent file shows its containing folder alongside it. The sidebar toggle and native column sizing let the system accommodate smaller windows.

A window too narrow for three columns, such as an unfolded iPhone Duo, slides the library — and in portrait the folder too — over the reader. While no folder is chosen the library opens itself, so the window never starts on two empty placeholders. Choosing a folder closes a library overlay and leaves the folder; opening a file closes the overlays covering the reader. Columns that sit side by side are never closed. The app detects overlays by comparing column frames, since SwiftUI’s requested visibility does not tell it whether a column is tiled or overlaid. When the window widens again, the columns closed this way come back if they fit.

A compact width or height, such as a folded iPhone Duo or a landscape iPhone, uses the existing stack navigation. The layout follows size classes, not the device idiom. Both layouts use the same route state, so the current folder and file stay put when the window changes size or the device folds or unfolds.

Editing or deleting the visible connection clears its selected routes so old-server content is not shown under changed settings. Disconnect returns all columns to their initial state. Backgrounding retains location while closing connections and clearing unlocked keys. Demo uses the same workspace without contacting a server.

Automated navigation tests cover route projection, preview replacement, folder history, recents, disconnect and the size-class layout decision. Simulator UI journeys include assertions for the workspace and adaptive overlays; consult their results for the build being tested. Simulator results do not establish physical iPad, iPhone Duo or Stage Manager behavior.
