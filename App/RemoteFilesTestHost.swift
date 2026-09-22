import SwiftUI

// A minimal test host keeps the app's UI dependencies out of the core test process.
@main
struct RemoteFilesTestHost: App {
    var body: some Scene { WindowGroup { Text("RemoteFiles core tests") } }
}
