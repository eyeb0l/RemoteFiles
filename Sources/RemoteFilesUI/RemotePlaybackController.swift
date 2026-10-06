#if os(iOS)
import AVKit
import Observation
import RemoteFilesCore

/// A player owns a stable local file: cache eviction/refresh must not unlink bytes it still needs.
@MainActor @Observable
final class RemotePlaybackController {
    private(set) var player: AVPlayer?
    private(set) var failure: String?
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    @ObservationIgnored private var file: PlaybackFile?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var playbackObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var failedToEnd: NSObjectProtocol?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var playbackID = UUID()

    isolated deinit {
        if let failedToEnd { NotificationCenter.default.removeObserver(failedToEnd) }
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        player?.pause()
    }

    func prepare(_ source: URL, filename: String) async throws {
        let token = UUID(); requestID = token
        // Linking/copying up to 128 MiB must not block scrolling or navigation.
        let local = try await Task.detached(priority: .userInitiated) {
            try PlaybackFile(source: source, filename: filename)
        }.value
        try Task.checkCancellation()
        guard token == requestID else { throw CancellationError() }
        let asset = AVURLAsset(url: local.url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        do {
            let playable = try await withTaskCancellationHandler {
                try await asset.load(.isPlayable)
            } onCancel: { asset.cancelLoading() }
            guard playable else { throw PlaybackError.unplayable }
        } catch is CancellationError { throw CancellationError() }
        catch { throw PlaybackError.unplayable }
        try Task.checkCancellation()
        guard token == requestID else { throw CancellationError() }

        let seconds: Double
        do { seconds = try await asset.load(.duration).seconds }
        catch { try Task.checkCancellation(); throw PlaybackError.unplayable }
        try Task.checkCancellation()
        guard token == requestID else { throw CancellationError() }

        stop(deactivateAudioSession: false)
        requestID = token
        playbackID = token
        file = local
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item) // The user starts playback with the native controls.
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        playbackObservation = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor [weak self] in
                guard self?.playbackID == token else { return }
                self?.isPlaying = playing
            }
        }
        timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard self?.playbackID == token, time.seconds.isFinite else { return }
                self?.elapsed = max(0, time.seconds)
            }
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in self?.playbackFailed(token: token) }
        }
        failedToEnd = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.playbackFailed(token: token) }
            }
    }

    func pause() { player?.pause() }
    func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() }
        else {
            if duration > 0 && player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, min(seconds, duration))
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func stop(deactivateAudioSession: Bool = true) {
        let hadPlayer = player != nil
        requestID = UUID()
        playbackID = UUID()
        observation = nil
        playbackObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let failedToEnd { NotificationCenter.default.removeObserver(failedToEnd) }
        failedToEnd = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        file = nil
        failure = nil
        isPlaying = false; elapsed = 0; duration = 0
        if deactivateAudioSession && hadPlayer {
            AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation) { _, _ in }
        }
    }

    private func playbackFailed(token: UUID) {
        guard playbackID == token else { return }
        stop()
        failure = PlaybackError.unplayable.localizedDescription
    }
}

enum PlaybackError: LocalizedError {
    case unplayable
    var errorDescription: String? {
        "This file can’t be played on this device. Its codec may be unsupported, or the file may be damaged. You can save the original to Files to open it in another app."
    }
}

/// A hard link retains the downloaded inode without another large allocation. A copy is the
/// fallback across volumes. The resolver always replaces cache files rather than editing them.
private final class PlaybackFile: @unchecked Sendable {
    let directory: URL
    let url: URL
    init(source: URL, filename: String) throws {
        guard source.isFileURL else { throw PlaybackError.unplayable }
        let fm = FileManager.default
        directory = fm.temporaryDirectory.appendingPathComponent("RemotePlayback-" + UUID().uuidString, isDirectory: true)
        let suffix = (filename as NSString).pathExtension.lowercased()
        url = directory.appendingPathComponent("media").appendingPathExtension(suffix)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            do { try fm.linkItem(at: source, to: url) }
            catch { try fm.copyItem(at: source, to: url) }
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var folder = directory; try folder.setResourceValues(values)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
#endif
