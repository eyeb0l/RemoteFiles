#if os(iOS)
import BackgroundTasks
import RemoteFilesCore
import UIKit

/// What the coordinator asks of a queue that runs one SSH transfer at a time: the download queue, or the
/// queue of uploads and copies between servers.
@MainActor protocol BackgroundTransferQueue: AnyObject {
    var isForeground: Bool { get }
    var activeID: UUID? { get }
    /// The transfer `id` if it is running now, for the system's progress display.
    func runningTransfer(_ id: UUID) -> BackgroundTransferProgress?
    func transferSucceeded(_ id: UUID) -> Bool
    /// Marks what is pending interrupted, tells the transfer under way to stop and saves the list, all
    /// before it returns; the task returned is the connection closing and the worker draining.
    @discardableResult func interruptNow(reason: String) -> Task<Void, Never>
    /// Words for this queue's status lines: "download", "downloading" and "Downloads".
    var wording: (one: String, doing: String, all: String) { get }
}

struct BackgroundTransferProgress {
    let title: String
    let detail: String
    let completed: UInt64
    let total: UInt64
    /// What is still to be moved, where the file's size is known.
    let remaining: UInt64?
}

extension DownloadManager: BackgroundTransferQueue {
    func runningTransfer(_ id: UUID) -> BackgroundTransferProgress? {
        guard let item = items.first(where: { $0.id == id }), item.state == .downloading else { return nil }
        return .init(title: "Downloading file", detail: item.progress.sizeLabel(), completed: item.receivedBytes,
                     total: item.expectedBytes ?? UInt64(DownloadManager.maximumFileBytes),
                     remaining: item.expectedBytes.map { $0 > item.receivedBytes ? $0 - item.receivedBytes : 0 })
    }
    /// A download whose bytes have all arrived has done what its task was for. On a locked device the file
    /// can't yet be secured, and the row waits for the unlock to say completed, but iOS is not told that the
    /// transfer failed.
    func transferSucceeded(_ id: UUID) -> Bool {
        let state = items.first { $0.id == id }?.state
        return state == .completed || state == .pendingFinalization
    }
    var wording: (one: String, doing: String, all: String) { ("download", "downloading", "Downloads") }
}

extension TransferManager: BackgroundTransferQueue {
    func runningTransfer(_ id: UUID) -> BackgroundTransferProgress? {
        guard let item = items.first(where: { $0.id == id }), item.state == .transferring else { return nil }
        return .init(title: item.isCopy ? "Copying file" : "Uploading file", detail: item.progress.transferLabel(),
                     completed: item.sentBytes, total: item.expectedBytes ?? max(item.sentBytes, 1),
                     remaining: item.expectedBytes.map { $0 > item.sentBytes ? $0 - item.sentBytes : 0 })
    }
    func transferSucceeded(_ id: UUID) -> Bool { items.first { $0.id == id }?.state == .completed }
    var wording: (one: String, doing: String, all: String) { ("transfer", "transferring", "Transfers") }
}

/// Each request describes one foreground-initiated SSH transfer. iOS owns its
/// visible progress/cancel UI and may expire it; it never relaunches SSH silently.
///
/// iOS shows a continued processing task in its own way for as long as it runs, and for some seconds after.
/// On an iPad that is a banner across the top of the screen, over a folder's title and buttons, until it is
/// swiped away. So a transfer that will be over in a moment asks for none: it holds the short time iOS gives
/// any app to finish what it is doing when it leaves the screen, which shows nothing. A transfer with more
/// to move, or of unknown size, asks as it starts, while the app is in front: iOS refuses a request made
/// once the screen has begun to lock, and a transfer left running then would stop. A short transfer that
/// turns out slow asks once that is plain.
///
/// What that costs: a short transfer that the app is locked on, or left, before iOS has handed it a task
/// has only the short time. That is so before its first look, after looks that found it near its end, and
/// after a look that asked where iOS has not yet answered or has refused: a task that arrives with the app
/// away is turned down. Nothing can be asked for while the app is away, so if the transfer is slow or stops
/// moving and the short time runs out, it is interrupted and takes a Retry, where a task asked for as it
/// started could have carried it. iOS does not say how long the short time is; `backgroundTimeRemaining`
/// reports it once the app is in the background.
@MainActor @Observable
final class BackgroundDownloadCoordinator {
    private static var coordinators: [ObjectIdentifier: BackgroundDownloadCoordinator] = [:]
    static func shared(for queue: any BackgroundTransferQueue) -> BackgroundDownloadCoordinator {
        let key = ObjectIdentifier(queue)
        if let value = coordinators[key] { return value }
        let value = BackgroundDownloadCoordinator(wording: queue.wording); coordinators[key] = value; return value
    }
    /// What the queue's screen says of the background. It speaks of the transfer under way, and goes back to
    /// `idle` as that ends, unless iOS ended it, which stays said until the next transfer starts.
    private(set) var status: String
    private var idle: String { "\(wording.all) continue while the app is open." }
    private let wording: (one: String, doing: String, all: String)
    private var requestIdentifier: String?
    private var transferID: UUID?
    private var backgroundTask: BGContinuedProcessingTask?
    private weak var queue: (any BackgroundTransferQueue)?
    private var shortTime: UIBackgroundTaskIdentifier?
    private var slowWatch: Task<Void, Never>?
    var canContinue: Bool { backgroundTask != nil || shortTime != nil }

    /// A transfer with less than this left holds the short time and asks for no task as it starts. These
    /// three are choices and not measurements: small enough that an ordinary connection moves it in a few
    /// seconds, looked at soon enough that few locks come first, and near enough its end to be worth no banner.
    static let shortBytes: UInt64 = 8 * 1024 * 1024
    /// How near its end a short transfer must be, at the rate it has kept, to go on without a task.
    static let nearlyDone: TimeInterval = 10
    /// How long a short transfer runs before it is looked at, and between looks.
    static let grace: Duration = .seconds(2)
    /// Time as the looks see it. Replaced in tests.
    @ObservationIgnored var pause: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored var now: @MainActor () -> ContinuousClock.Instant = { .now }
    /// The short time iOS gives an app to finish work as it leaves the screen. Replaced in tests.
    @ObservationIgnored var beginShortTime: (_ name: String, _ expired: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier = { name, expired in
        UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { expired() } }
    }
    @ObservationIgnored var endShortTime: (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    /// Told of each continued processing task asked for. Set in tests.
    @ObservationIgnored var askedForTask: ((UUID) -> Void)?

    init(wording: (one: String, doing: String, all: String) = ("download", "downloading", "Downloads")) {
        self.wording = wording
        status = "\(wording.all) continue while the app is open."
        assert(status == idle)
    }

    func update(_ queue: any BackgroundTransferQueue) {
        self.queue = queue
        if transferID != queue.activeID {
            finish(success: transferID.map(queue.transferSucceeded) ?? false)
            guard queue.isForeground, let id = queue.activeID, let running = queue.runningTransfer(id) else { return }
            transferID = id
            if let remaining = running.remaining, remaining < Self.shortBytes { holdShortTime(for: id, running) }
            else { requestTask(for: id, title: running.title) }
        }
        reportProgress()
    }

    /// For a transfer expected to be over in a moment: no task, so nothing for iOS to show. If it is still
    /// running after `grace` and not nearly done, it is slow, and asks for a task then.
    private func holdShortTime(for id: UUID, _ running: BackgroundTransferProgress) {
        let held = beginShortTime("RemoteFiles " + wording.one) { [weak self] in self?.shortTimeExpired(for: id) }
        guard held != .invalid else { requestTask(for: id, title: running.title); return }
        shortTime = held
        status = "This \(wording.one) has a short time to finish in the background."
        let pause = pause
        slowWatch = Task { [weak self, clock = now] in
            // The rate is the one kept since the last look, so a transfer that has stopped moving is slow.
            var looked = clock(), done = running.completed
            while true {
                do { try await pause(Self.grace) } catch { return }
                guard let self, !Task.isCancelled, self.transferID == id, self.requestIdentifier == nil else { return }
                guard let queue = self.queue, let now = queue.runningTransfer(id) else { continue }
                let seconds = max((clock() - looked) / .seconds(1), 0.001)
                let rate = Double(now.completed > done ? now.completed - done : 0) / seconds
                looked = clock(); done = now.completed
                // A request made while the app is away would be refused.
                guard queue.isForeground else { continue }
                if let left = now.remaining, rate > 0, Double(left) / rate < Self.nearlyDone { continue }
                self.requestTask(for: id, title: now.title)
                return
            }
        }
    }
    private func releaseShortTime() {
        slowWatch?.cancel(); slowWatch = nil
        if let held = shortTime { shortTime = nil; endShortTime(held) }
    }
    /// iOS is about to suspend the app with the transfer unfinished and no task to carry it. The app may be
    /// suspended as soon as the short time is given back, so the list is put right first: the transfer is
    /// marked interrupted, told to stop, and saved, and only then is the time given back.
    private func shortTimeExpired(for id: UUID) {
        guard transferID == id, shortTime != nil else { return }
        guard backgroundTask == nil else { releaseShortTime(); return }
        queue?.interruptNow(reason: "iOS stopped this background transfer. Retry to continue.")
        finish(success: false)
        status = "iOS stopped the background transfer. Retry the interrupted \(wording.one) when ready."
    }

    private func requestTask(for id: UUID, title: String) {
        askedForTask?(id)
        // One permitted prefix covers every queue; see BGTaskSchedulerPermittedIdentifiers.
        let identifier = "dev.iris.RemoteFiles.download." + UUID().uuidString
        requestIdentifier = identifier
        let unavailable = "Background processing is unavailable. Keep the app open to finish \(wording.doing)."
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                guard let self, self.queue?.isForeground == true, self.requestIdentifier == identifier, self.queue?.activeID == id else {
                    continued.setTaskCompleted(success: false); return
                }
                self.backgroundTask = continued
                self.releaseShortTime()
                continued.expirationHandler = { [weak self] in
                    Task { @MainActor in await self?.expire(identifier: identifier) }
                }
                self.status = "This transfer can continue in the background. iOS may stop it if resources are needed."
                self.reportProgress()
            }
        }
        guard registered else { status = unavailable; return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Preparing SSH transfer")
        request.strategy = .fail
        Task { [weak self] in
            do { try await BGTaskScheduler.shared.submitTaskRequest(request) }
            catch {
                guard self?.requestIdentifier == identifier else { return }
                self?.status = unavailable
            }
        }
    }

    private func reportProgress() {
        guard let task = backgroundTask, let queue, let id = transferID, let running = queue.runningTransfer(id) else { return }
        task.progress.totalUnitCount = Int64(clamping: running.total)
        task.progress.completedUnitCount = Int64(clamping: running.completed)
        task.updateTitle(running.title, subtitle: running.detail)
    }
    private func expire(identifier: String) async {
        guard requestIdentifier == identifier else { return }
        // As in `shortTimeExpired`: the list is put right before the task is given back.
        let draining = queue?.interruptNow(reason: "iOS stopped this background transfer. Retry to continue.")
        finish(success: false)
        status = "iOS stopped the background transfer. Retry the interrupted \(wording.one) when ready."
        await draining?.value
    }
    func finish(success: Bool) {
        releaseShortTime()
        if let identifier = requestIdentifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        if success, let task = backgroundTask { task.progress.completedUnitCount = task.progress.totalUnitCount }
        backgroundTask?.setTaskCompleted(success: success)
        if transferID != nil { status = idle }
        backgroundTask = nil; requestIdentifier = nil; transferID = nil
    }
}
#endif
