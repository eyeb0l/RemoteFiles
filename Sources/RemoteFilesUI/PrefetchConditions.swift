#if os(iOS)
import Foundation
import Network
import os

/// Work done ahead of need waits when someone has asked the device to go easy: Low Power Mode, or a
/// network with Low Data Mode on.
final class PrefetchConditions: Sendable {
    static let shared = PrefetchConditions()
    private let constrained = OSAllocatedUnfairLock(initialState: false)
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { [constrained] path in constrained.withLock { $0 = path.isConstrained } }
        monitor.start(queue: DispatchQueue(label: "dev.iris.RemoteFiles.prefetch-conditions", qos: .utility))
    }
    var discouraged: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || constrained.withLock { $0 } }
}
#endif
