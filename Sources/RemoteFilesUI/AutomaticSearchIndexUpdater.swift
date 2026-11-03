#if os(iOS)
import Foundation
import Observation
import RemoteFilesCore

/// Updates saved search indexes that are set to update automatically, when their folder opens
/// while the app is in the foreground and connected. Each update is an ordinary Update Index:
/// it uses the index's own hidden-file and extraction choices and keeps unchanged files.
/// Nothing runs while the app is in the background, since the session ends there.
@MainActor @Observable
final class AutomaticSearchIndexUpdater {
    /// Progress of updates that are running now, by index.
    private(set) var progress: [String: RemoteFolderSearch.Update] = [:]
    /// What the last automatic update of an index did, or why it failed.
    private(set) var outcomes: [String: Outcome] = [:]
    /// Changes when an automatic update saves a new snapshot.
    private(set) var savedRevision = 0
    /// How old an index must be before opening its folder updates it.
    var interval = SearchIndexSnapshot.automaticUpdateInterval

    struct Outcome: Equatable {
        let message: String
        let failed: Bool
    }

    @ObservationIgnored private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// When an update last started, so a failing index waits a full interval before trying again.
    @ObservationIgnored private var attempts: [String: Date] = [:]
    @ObservationIgnored private var checking: Set<String> = []
    /// Advanced by every cancellation, so a check suspended across it cannot start an update afterwards.
    @ObservationIgnored private var epoch = 0

    nonisolated static func key(_ profile: ConnectionProfile, root: String) -> String { profile.id.uuidString + "|" + root }

    func isUpdating(_ profile: ConnectionProfile, root: String) -> Bool { tasks[Self.key(profile, root: root)] != nil }

    /// Starts an update of the index for exactly this folder if it is set to update automatically
    /// and is older than the interval. Returns whether an update started.
    @discardableResult
    func updateIfDue(_ profile: ConnectionProfile, root: String, model: AppModel, now: Date = Date()) async -> Bool {
        let key = Self.key(profile, root: root)
        guard canRun(profile, model: model), tasks[key] == nil, !checking.contains(key) else { return false }
        if let attempt = attempts[key], now.timeIntervalSince(attempt) >= 0, now.timeIntervalSince(attempt) < interval { return false }
        checking.insert(key); defer { checking.remove(key) }
        let revision = model.sessionRevision, service = model.searchService, epoch = epoch
        let store = await model.searchIndexStore()
        let saved: SearchIndexSnapshot
        do {
            guard try await store.updatesAutomatically(profile: profile, root: root),
                  let snapshot = try await store.load(profile: profile, root: root),
                  snapshot.isDueForAutomaticUpdate(at: now, interval: interval) else { return false }
            saved = snapshot
        } catch { return false }
        guard canRun(profile, model: model), model.sessionRevision == revision, self.epoch == epoch, tasks[key] == nil else { return false }
        attempts[key] = now
        progress[key] = .init()
        let token = UUID()
        let task = Task { [weak self, weak model] in
            guard let self, let model else { return }
            await self.run(saved, profile: profile, root: root, key: key, token: token, revision: revision,
                           store: store, service: service, model: model)
        }
        tasks[key] = (token, task)
        return true
    }

    /// Stops a running automatic update, for example because a manual build or deletion replaces it.
    /// The next opening of the folder may start a new one.
    func cancel(_ profile: ConnectionProfile, root: String) {
        let key = Self.key(profile, root: root)
        epoch += 1
        tasks.removeValue(forKey: key)?.task.cancel()
        progress.removeValue(forKey: key); attempts.removeValue(forKey: key)
    }

    /// Ends every update when the session closes. Cancelled updates save nothing and run again
    /// when their folder next opens.
    func cancelAll() {
        epoch += 1
        for (_, entry) in tasks { entry.task.cancel() }
        tasks.removeAll(); progress.removeAll(); attempts.removeAll()
    }

    func outcome(_ profile: ConnectionProfile, root: String) -> Outcome? { outcomes[Self.key(profile, root: root)] }
    func clearOutcome(_ profile: ConnectionProfile, root: String) { outcomes.removeValue(forKey: Self.key(profile, root: root)) }

    private func canRun(_ profile: ConnectionProfile, model: AppModel) -> Bool {
        model.isForeground && !model.isDisconnecting && model.profile(profile.id) == profile
    }

    private func run(_ saved: SearchIndexSnapshot, profile: ConnectionProfile, root: String, key: String, token: UUID,
                     revision: Int, store: SearchIndexStore, service: any RemoteFileService, model: AppModel) async {
        var final = RemoteFolderSearch.Update()
        do {
            let generation = try await store.beginBuild(profile: profile, root: root)
            let snapshot = try await RemoteFolderSearch.buildIndex(below: root, profile: profile, service: service,
                includeHidden: saved.includeHidden, extraction: saved.extraction, reusing: saved) { update in
                final = update
                Task { @MainActor [weak self] in
                    guard let self, self.tasks[key]?.token == token else { return }
                    self.progress[key] = update
                }
            }
            try Task.checkCancellation()
            guard tasks[key]?.token == token, canRun(profile, model: model), model.sessionRevision == revision else {
                finish(key, token: token, outcome: nil); return
            }
            try await store.save(snapshot, profile: profile, root: root, generation: generation)
            try Task.checkCancellation()
            let read = final.filesSearched - final.reusedFiles
            finish(key, token: token, outcome: .init(
                message: "Updated automatically. Read \(read) new or changed \(read == 1 ? "file" : "files") and kept \(final.reusedFiles) unchanged.",
                failed: false))
            savedRevision += 1
            return
        } catch is CancellationError {
        } catch SearchIndexError.superseded {
            // A manual build or deletion replaced this update; it reports its own result.
        } catch {
            if !Task.isCancelled, tasks[key]?.token == token {
                finish(key, token: token, outcome: .init(message: "Automatic update failed: " + error.localizedDescription, failed: true))
                return
            }
        }
        finish(key, token: token, outcome: nil)
    }

    private func finish(_ key: String, token: UUID, outcome: Outcome?) {
        guard tasks[key]?.token == token else { return }
        tasks.removeValue(forKey: key); progress.removeValue(forKey: key)
        if let outcome { outcomes[key] = outcome } else { attempts.removeValue(forKey: key) }
    }
}
#endif
