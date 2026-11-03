import SwiftUI
import RemoteFilesUI

@main
struct RemoteFilesApp: App {
    @UIApplicationDelegateAdaptor(RemoteFilesAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { RemoteFilesRootView() }
            .commands { RemoteFilesCommands() }
    }
}
