# iPad workspace

<img src="screenshots/ipad/workspace.png" width="840" alt="RemoteFiles on iPad with the library, folder list and reader visible together">

*Passing iPad Pro simulator UI journey using bundled demo files.*

In a regular-width iPad window, RemoteFiles uses three native split-view columns:

- **Library:** connections, favourites and recents, with the existing settings and connection actions.
- **Folder:** the selected folder, with search, sorting, breadcrumbs and a Previous Folder button for nested navigation.
- **Reader:** the selected file, including the existing rendered/source controls, Find, document links and export actions.

Opening another file replaces the preview while keeping its folder mounted. Selecting a new folder clears the old preview. Opening a recent file shows its containing folder alongside it. The sidebar toggle and native column sizing let the system accommodate smaller windows; narrow size classes use the existing stack navigation. Both layouts use the same route state, retaining the current folder/file when the window changes size.

Editing or deleting the visible connection clears its selected routes so old-server content is not shown under changed settings. Disconnect returns all columns to their initial state. Backgrounding retains location while closing connections and clearing unlocked keys. Demo uses the same workspace without contacting a server.

Automated navigation regressions cover route projection, preview replacement, folder history, recents and disconnect. The adaptive UI journey runs on iPhone and additionally verifies side-by-side library, folder and reader on an iPad simulator. Simulator results do not claim physical iPad or Stage Manager acceptance.
