#if os(iOS)
import BackgroundTasks
import RemoteFilesCore

/// Each request describes one foreground-initiated SSH transfer. iOS owns its
/// visible progress/cancel UI and may expire it; it never relaunches SSH silently.
@MainActor @Observable
final class BackgroundDownloadCoordinator {
    private static var coordinators: [ObjectIdentifier: BackgroundDownloadCoordinator] = [:]
    static func shared(for manager: DownloadManager) -> BackgroundDownloadCoordinator {
        let key = ObjectIdentifier(manager)
        if let value = coordinators[key] { return value }
        let value = BackgroundDownloadCoordinator(); coordinators[key] = value; return value
    }
    private(set) var status = "Downloads continue while the app is open."
    private var requestIdentifier: String?
    private var transferID: UUID?
    private var backgroundTask: BGContinuedProcessingTask?
    private weak var manager: DownloadManager?
    var canContinue: Bool { backgroundTask != nil }

    func update(_ manager: DownloadManager) {
        self.manager = manager
        if transferID != manager.activeID {
            finish(success: transferID.flatMap { id in manager.items.first { $0.id == id }?.state } == .completed)
            guard manager.isForeground, let id = manager.activeID,
                  manager.items.first(where: { $0.id == id })?.state == .downloading else { return }
            transferID = id
            let identifier = "dev.iris.RemoteFiles.download." + UUID().uuidString
            requestIdentifier = identifier
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in
                    guard let self, self.manager?.isForeground == true, self.requestIdentifier == identifier, self.manager?.activeID == id else {
                        continued.setTaskCompleted(success: false); return
                    }
                    self.backgroundTask = continued
                    continued.expirationHandler = { [weak self] in
                        Task { @MainActor in await self?.expire(identifier: identifier) }
                    }
                    self.status = "This transfer can continue in the background. iOS may stop it if resources are needed."
                    self.reportProgress()
                }
            }
            guard registered else { status = "Background processing is unavailable. Keep the app open to finish downloading."; return }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Downloading file", subtitle: "Preparing SSH transfer")
            request.strategy = .fail
            Task { [weak self] in
                do { try await BGTaskScheduler.shared.submitTaskRequest(request) }
                catch {
                    guard self?.requestIdentifier == identifier else { return }
                    self?.status = "Background processing is unavailable. Keep the app open to finish downloading."
                }
            }
        }
        reportProgress()
    }

    private func reportProgress() {
        guard let task = backgroundTask, let manager, let id = transferID,
              let item = manager.items.first(where: { $0.id == id }) else { return }
        task.progress.totalUnitCount = Int64(item.expectedBytes ?? UInt64(DownloadManager.maximumFileBytes))
        task.progress.completedUnitCount = Int64(item.receivedBytes)
        task.updateTitle("Downloading file", subtitle: item.progress.sizeLabel())
    }
    private func expire(identifier: String) async {
        guard requestIdentifier == identifier else { return }
        status = "iOS stopped the background transfer. Retry the interrupted download when ready."
        finish(success: false)
        await manager?.interrupt(reason: "iOS stopped this background transfer. Retry to start again.")
    }
    func finish(success: Bool) {
        if let identifier = requestIdentifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        if success, let task = backgroundTask { task.progress.completedUnitCount = task.progress.totalUnitCount }
        backgroundTask?.setTaskCompleted(success: success)
        backgroundTask = nil; requestIdentifier = nil; transferID = nil
    }
}
#endif
