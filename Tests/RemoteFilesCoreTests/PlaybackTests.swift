#if os(iOS)
import XCTest
import AVKit
import SwiftUI
import RemoteFilesCore
@testable import RemoteFilesUI

@MainActor @Observable private final class NativeVideoState { var presented = false }
private struct NativeVideoFixture: View {
    let playback: RemotePlaybackController
    @Bindable var state: NativeVideoState
    var body: some View {
        Color.clear.background {
            NativeVideoPlayerPresentation(player: playback.player, isPresented: $state.presented)
                .frame(width: 0, height: 0)
        }
    }
}

@MainActor final class PlaybackTests: XCTestCase {
    func testFullscreenPresentsNativeControllerAndRestoresSamePlayer() async throws {
        let source = try await downloaded("Sample video.mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let playback = RemotePlaybackController()
        defer { playback.stop() }
        try await playback.prepare(source, filename: "clip.mp4")
        let player = try XCTUnwrap(playback.player)
        await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let state = NativeVideoState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NativeVideoFixture(playback: playback, state: state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        func native(_ root: UIViewController) -> AVPlayerViewController? {
            if let value = root as? AVPlayerViewController { return value }
            if let presented = root.presentedViewController, let value = native(presented) { return value }
            return root.children.lazy.compactMap(native).first
        }
        state.presented = true
        try await waitUntil { native(window.rootViewController!)?.view.window != nil }
        let fullscreen = try XCTUnwrap(native(window.rootViewController!))
        XCTAssertEqual(fullscreen.modalPresentationStyle, .fullScreen)
        XCTAssertTrue(fullscreen.showsPlaybackControls)
        XCTAssertFalse(fullscreen.allowsPictureInPicturePlayback)
        XCTAssertTrue(fullscreen.player === player)
        XCTAssertEqual(player.currentTime().seconds, 0.5, accuracy: 0.1)
        try await waitUntil { !fullscreen.isBeingPresented }
        fullscreen.dismiss(animated: false)
        try await waitUntil { !state.presented }
        XCTAssertTrue(playback.player === player)
        XCTAssertNotNil(player.currentItem)
        XCTAssertNil(fullscreen.player, "Dismissal must release the fullscreen attachment, not the playback session")
        state.presented = true
        try await waitUntil { native(window.rootViewController!)?.view.window != nil }
        let reopened = try XCTUnwrap(native(window.rootViewController!))
        try await waitUntil { !reopened.isBeingPresented }
        playback.stop()
        try await waitUntil { !state.presented }
        XCTAssertNil(native(window.rootViewController!))
        XCTAssertNil(player.currentItem)
    }

    private func downloaded(_ name: String) async throws -> URL {
        let profile = ConnectionProfile(name: "Playback fixture", host: "fixture.invalid", username: "fixture", identityID: UUID())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".resource")
        _ = try await DemoRemoteFileService(delayNanoseconds: 0).downloadFile(profile: profile,
            path: "/Projects/" + name, allowedRoot: "/Projects", destination: url, limit: 128 * 1024 * 1024)
        return url
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for playback state")
    }
    private func checkPlayback(_ name: String, mediaType: AVMediaType) async throws {
        let source = try await downloaded(name)
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = RemotePlaybackController()
        defer { controller.stop() }
        try await controller.prepare(source, filename: name)
        let player = try XCTUnwrap(controller.player)
        let item = try XCTUnwrap(player.currentItem)
        let asset = try XCTUnwrap(item.asset as? AVURLAsset)
        XCTAssertTrue(asset.url.isFileURL)
        XCTAssertEqual(asset.url.pathExtension, (name as NSString).pathExtension)
        XCTAssertEqual(asset.referenceRestrictions, .forbidAll)
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        XCTAssertFalse(tracks.isEmpty)
        try await waitUntil { item.status != .unknown }
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertEqual(player.rate, 0, "Opening a preview must not autoplay")

        // The player must survive the resource cache unlinking/replacing its copy.
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path))
        await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        try await waitUntil { player.currentTime().seconds > 0.75 }
        controller.pause()
        XCTAssertEqual(player.rate, 0)
        controller.stop()
        XCTAssertNil(controller.player)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.url.deletingLastPathComponent().path))
    }
    func testMP4VideoPlaybackSeekingAndCleanup() async throws {
        try await checkPlayback("Sample video.mp4", mediaType: .video)
    }
    func testM4AAudioPlaybackSeekingAndCleanup() async throws {
        try await checkPlayback("Sample audio.m4a", mediaType: .audio)
    }
    func testMP3WAVFLACAIFFAndAACPlayback() async throws {
        for ext in ["mp3", "wav", "flac", "aiff", "aac"] {
            try await checkPlayback("Sample audio." + ext, mediaType: .audio)
        }
    }
    func testMOVVideoPlayback() async throws {
        try await checkPlayback("Sample video.mov", mediaType: .video)
    }
    func testAudioControlsPublishTimeSeekPauseAndReplay() async throws {
        let source = try await downloaded("Sample audio.m4a")
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = RemotePlaybackController()
        defer { controller.stop() }
        try await controller.prepare(source, filename: "audio.m4a")
        XCTAssertGreaterThan(controller.duration, 3)
        XCTAssertFalse(controller.isPlaying)
        controller.seek(to: 1)
        try await waitUntil { controller.elapsed >= 0.9 }
        controller.togglePlayback()
        try await waitUntil { controller.isPlaying && controller.elapsed > 1.2 }
        controller.togglePlayback()
        try await waitUntil { !controller.isPlaying }
        controller.seek(to: controller.duration)
        try await waitUntil { (controller.player?.currentTime().seconds ?? 0) >= controller.duration - 0.05 }
        controller.togglePlayback()
        try await waitUntil { controller.isPlaying && controller.elapsed < 1 }
    }
    func testCorruptRefreshPreservesPreviousPlayerAndReportsCodecError() async throws {
        let source = try await downloaded("Sample audio.m4a")
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: corrupt) }
        try Data("damaged media".utf8).write(to: corrupt)
        let controller = RemotePlaybackController()
        defer { controller.stop() }
        try await controller.prepare(source, filename: "recording.m4a")
        let previous = controller.player
        do {
            try await controller.prepare(corrupt, filename: "recording.m4a")
            XCTFail("Damaged media must not produce a player")
        } catch {
            XCTAssertTrue(error is PlaybackError)
            XCTAssertTrue(error.localizedDescription.contains("codec"))
        }
        XCTAssertTrue(controller.player === previous)
    }
    func testStopDuringPreparationCannotPublishAPlayer() async throws {
        let source = try await downloaded("Sample video.mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = RemotePlaybackController()
        let task = Task { try await controller.prepare(source, filename: "clip.mp4") }
        await Task.yield()
        controller.stop()
        task.cancel()
        do { try await task.value; XCTFail("Cancelled preparation must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(controller.player)
    }
    func testRuntimePlaybackFailureRemovesPlayerAndLocalCopy() async throws {
        let source = try await downloaded("Sample video.mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = RemotePlaybackController()
        try await controller.prepare(source, filename: "clip.mp4")
        let item = try XCTUnwrap(controller.player?.currentItem)
        let url = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
        try await waitUntil { controller.failure != nil }
        XCTAssertNil(controller.player)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(controller.failure?.contains("save the original") == true)
    }
    func testMediaViewStopsWhenAppBackgrounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, fileService: DemoRemoteFileService(delayNanoseconds: 0))
        let profile = ConnectionProfile(name: "Playback UI", host: "fixture.invalid", username: "fixture", identityID: UUID())
        let entry = RemoteEntry(name: "Sample video.mp4", path: "/Projects/Sample video.mp4", kind: .file)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RemoteMediaView(model: model, profile: profile,
            entry: entry, kind: .video, refreshID: 0).environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        func players(_ controller: UIViewController) -> [AVPlayerViewController] {
            (controller as? AVPlayerViewController).map { [$0] } ?? controller.children.flatMap(players)
        }
        try await waitUntil { players(window.rootViewController!).first?.player != nil }
        let player = try XCTUnwrap(players(window.rootViewController!).first?.player)
        player.play()
        model.isForeground = false
        try await waitUntil { player.currentItem == nil }
        XCTAssertEqual(player.rate, 0)
        await model.disconnect()
    }
}
#endif
