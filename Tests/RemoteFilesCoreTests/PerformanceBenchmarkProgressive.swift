import Foundation
@testable import RemoteFilesCore
@testable import RemoteFilesUI

extension PerformanceBenchmarkTests {
    /// When the first rows are ready to show: through the same gate the folder screen uses, or, for a
    /// folder that never needs it, once the whole listing is prepared.
    func measureFirstRows(_ scenario: String, path: String, profile: ConnectionProfile, service: SFTPRemoteFileService,
                          recorder: BenchmarkRecorder) async throws {
        let gate = PartialListingGate()
        let started = ContinuousClock.now
        let shown = FirstRowsBox()
        let snapshot = try await service.listDirectory(profile: profile, path: path) { snapshot in
            guard !shown.isSet, gate.shouldShow(count: snapshot.entries.count) else { return }
            blackHole(FolderListing(snapshot).visible(query: "", showHidden: false, order: .name).count)
            shown.set(started.elapsedMilliseconds)
        }
        let listing = await Task.detached(priority: .userInitiated) { FolderListing(snapshot) }.value
        blackHole(listing.visible(query: "", showHidden: false, order: .name).count)
        recorder.add(scenario + ".rows", value: shown.value ?? started.elapsedMilliseconds)
    }
}

private final class FirstRowsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double?
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return stored != nil }
    var value: Double? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Double) { lock.lock(); stored = value; lock.unlock() }
}
