import XCTest
@testable import RemoteFilesCore

@MainActor
final class TransferManagerTests: XCTestCase {
    private let profile = ConnectionProfile(name: "Destination", host: "destination.invalid", username: "writer", identityID: UUID(), startingDirectory: "/srv")
    private let other = ConnectionProfile(name: "Source", host: "source.invalid", username: "reader", identityID: UUID(), startingDirectory: "/data")
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("transfer-tests-" + UUID().uuidString) }
    /// A file the queue may take, as a picker's copy is.
    private func file(_ name: String, _ bytes: Data = Data("contents".utf8)) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-sources-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for transfers")
    }

    func testAnUploadTakesItsFileSendsItAndKeepsNothingOnceItIsThere() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture()
        let manager = try TransferManager(directory: directory)
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let picked = try file("Report final.pdf", bytes)
        var completed: [ManagedTransfer] = []
        let id = try manager.enqueueUpload(consuming: picked, named: "Report final.pdf", to: profile, directory: "/srv/inbox",
                                           service: service, onCompletion: { completed.append($0) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.path), "The queue takes the copy it was given")
        XCTAssertEqual(manager.items.first?.expectedBytes, UInt64(bytes.count))
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.completed])
        XCTAssertEqual(manager.items.first?.sentBytes, UInt64(bytes.count))
        XCTAssertNil(manager.items.first?.partialVersion)
        XCTAssertEqual(completed.map(\.id), [id])
        XCTAssertEqual(manager.arrivals(on: profile.id, in: "/srv/inbox"), 1, "Counted for every window showing the folder")
        XCTAssertEqual(manager.arrivals(on: profile.id, in: "/srv"), 0)
        let received = await service.received["Report final.pdf"]
        XCTAssertEqual(received, bytes)
        let request = try await XCTUnwrapAsync(await service.requests.first)
        XCTAssertEqual(request.request.directory, "/srv/inbox")
        XCTAssertEqual(request.request.conflict, .fail)
        XCTAssertEqual(request.request.partialName, UploadRequest.partialName(for: id))
        XCTAssertEqual(request.request.limit, TransferManager.maximumUploadBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path), "The staged copy goes once it has been sent")
        try await wait { await service.sessionCloses == 1 }
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 0, "Finishing must not lock keys browsing still uses")
    }

    func testABatchSharesItsConnectionsUntilTheQueueIsEmpty() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["c.txt"])
        let manager = try TransferManager(directory: directory)
        for name in ["a.txt", "b.txt", "c.txt"] {
            try manager.enqueueUpload(consuming: try file(name), named: name, to: profile, directory: "/srv", service: service)
        }
        try await wait { await service.waiting == ["c.txt"] }
        XCTAssertEqual(manager.items.map(\.state), [.completed, .completed, .transferring])
        var closes = await service.sessionCloses
        XCTAssertEqual(closes, 0, "A connection with more work queued for it stays open between files")
        await service.release("c.txt")
        try await wait { manager.activeID == nil }
        try await wait { await service.sessionCloses == 1 }
        closes = await service.sessionCloses
        XCTAssertEqual(closes, 1)
    }

    /// The queue closes its connections when it has nothing left for them. A transfer queued at that moment
    /// must not start on a connection that is being closed under it.
    func testATransferQueuedWhileItsConnectionsCloseWaitsForThemToClose() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(holdsClose: true)
        let manager = try TransferManager(directory: directory)
        try manager.enqueueUpload(consuming: try file("first.txt"), named: "first.txt", to: profile, directory: "/srv", service: service)
        try await wait { await service.closing }
        try manager.enqueueUpload(consuming: try file("second.txt"), named: "second.txt", to: profile, directory: "/srv", service: service)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.items.map(\.state), [.completed, .queued])
        var started = await service.requests.count
        XCTAssertEqual(started, 1, "Nothing starts until the close has finished")
        await service.finishClose()
        try await wait { manager.items.last?.state == .completed }
        started = await service.requests.count
        XCTAssertEqual(started, 2)
    }

    func testAnInterruptedTransferKeepsWhatWasSentAndRetryContinuesFromThatVersion() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(failures: ["video.mov": [RemoteFileError.connectionEnded]])
        let manager = try TransferManager(directory: directory)
        var failures: [String] = []
        let id = try manager.enqueueUpload(consuming: try file("video.mov", Data(repeating: 9, count: 5_000)), named: "video.mov",
                                           to: profile, directory: "/srv", service: service, onFailure: { error, _ in failures.append("\(error)") })
        try await wait { manager.activeID == nil }
        let failed = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.message, RemoteFileError.connectionEnded.localizedDescription)
        XCTAssertEqual(failures.count, 1)
        let version = try XCTUnwrap(failed.partialVersion)
        XCTAssertEqual(version.size, 5_000)
        XCTAssertTrue(failed.keepsPartialBytes)
        var removed = await service.removedPartials
        XCTAssertEqual(removed, [], "A lost connection leaves the partial copy for Retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).appendingPathComponent("video.mov").path))

        // A relaunch keeps the staged file and the version, and Retry hands the version back.
        let reopened = try TransferManager(directory: directory)
        XCTAssertEqual(reopened.items.first?.partialVersion, version)
        try reopened.retry(id, profiles: [profile], service: service)
        try await wait { reopened.activeID == nil }
        XCTAssertEqual(reopened.items.map(\.state), [.completed])
        let resumed = await service.requests.last?.request.resumeVersion
        XCTAssertEqual(resumed, version)
        removed = await service.removedPartials
        XCTAssertEqual(removed, [])
    }

    func testATakenNameKeepsTheBytesOnTheServerUntilItIsAnswered() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(failures: ["notes.txt": [RemoteUploadError.destinationExists("notes.txt")]], published: ["notes.txt": "notes 2.txt"])
        let manager = try TransferManager(directory: directory)
        let id = try manager.enqueueUpload(consuming: try file("notes.txt"), named: "notes.txt", to: profile, directory: "/srv", service: service)
        try await wait { manager.activeID == nil }
        var item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertTrue(item.nameTaken)
        XCTAssertNotNil(item.partialVersion, "Only the name is undecided")
        var removed = await service.removedPartials
        XCTAssertEqual(removed, [])

        try manager.retry(id, profiles: [profile], conflict: .keepBoth, service: service)
        try await wait { manager.activeID == nil }
        item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertFalse(item.nameTaken)
        XCTAssertEqual(item.filename, "notes 2.txt", "The list shows the name the file was given")
        let last = try await XCTUnwrapAsync(await service.requests.last)
        XCTAssertEqual(last.request.conflict, .keepBoth)
        XCTAssertEqual(last.request.name, "notes.txt")
        XCTAssertNotNil(last.request.resumeVersion)
        removed = await service.removedPartials
        XCTAssertEqual(removed, [])
    }

    func testCancellingAndRefusalsRemoveThePartialCopyFromTheServer() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["held.bin"], failures: ["denied.bin": [RemoteFileError.permissionDenied]])
        let manager = try TransferManager(directory: directory)
        let held = try manager.enqueueUpload(consuming: try file("held.bin"), named: "held.bin", to: profile, directory: "/srv", service: service)
        let denied = try manager.enqueueUpload(consuming: try file("denied.bin"), named: "denied.bin", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["held.bin"] }
        manager.cancel(held)
        XCTAssertEqual(manager.activeID, held, "A cancelled transfer keeps its slot until it has drained")
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.cancelled, .failed])
        XCTAssertNil(manager.items[0].partialVersion)
        XCTAssertNil(manager.items[1].partialVersion, "A refusal Retry would only repeat keeps nothing")
        XCTAssertEqual(manager.items[1].message, RemoteFileError.permissionDenied.localizedDescription)
        let removed = await service.removedPartials
        XCTAssertEqual(Set(removed), [UploadRequest.partialName(for: held), UploadRequest.partialName(for: denied)])
        // A cancelled upload can be sent again: its staged file is still there.
        try manager.retry(held, profiles: [profile], service: service)
        await service.release("held.bin")
        try await wait { manager.items[0].state == .completed }
        // Removing one that kept bytes asks the server to drop them.
        let lost = UploadFixture(failures: ["lost.bin": [RemoteFileError.timedOut]])
        let id = try manager.enqueueUpload(consuming: try file("lost.bin"), named: "lost.bin", to: profile, directory: "/srv", service: lost)
        try await wait { manager.activeID == nil && manager.items.last?.state == .failed }
        manager.remove(id, service: lost)
        XCTAssertNil(manager.items.first { $0.id == id })
        try await wait { await lost.removedPartials == [UploadRequest.partialName(for: id)] }
    }

    /// Clear Finished takes a cancelled transfer out of the list. One cancelled a moment ago still has the
    /// worker's slot, and it is the worker that asks the server to drop the partial copy.
    func testClearingFinishedTransfersLeavesOneStillStoppingToRemoveItsPartialCopy() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["held.bin"])
        let manager = try TransferManager(directory: directory)
        let held = try manager.enqueueUpload(consuming: try file("held.bin"), named: "held.bin", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["held.bin"] }
        manager.cancel(held)
        XCTAssertEqual(manager.activeID, held)
        manager.removeFinished()
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.id), [], "It goes from the list once it has stopped")
        let removed = await service.removedPartials
        XCTAssertEqual(removed, [UploadRequest.partialName(for: held)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(held.uuidString).path))

        // One that has finished and is closing its connection goes too, and the transfer after it stays.
        let slow = UploadFixture(holdsClose: true)
        let done = try manager.enqueueUpload(consuming: try file("done.bin"), named: "done.bin", to: profile, directory: "/srv", service: slow)
        try await wait { await slow.closing }
        XCTAssertEqual(manager.items.map(\.state), [.completed])
        XCTAssertEqual(manager.activeID, done)
        manager.removeFinished()
        let next = try manager.enqueueUpload(consuming: try file("next.bin"), named: "next.bin", to: profile, directory: "/srv", service: slow)
        await slow.finishClose()
        try await wait { manager.activeID == nil && manager.items.first?.state == .completed }
        XCTAssertEqual(manager.items.map(\.id), [next])
    }

    /// A folder's list may be some time old when a file is copied from it. What is sent is the file as it is
    /// when the copy starts, and the progress and the time asked of iOS are measured by that.
    func testACopyWhoseSourceHasGrownSinceItWasListedIsMeasuredByWhatIsSent() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let service = UploadFixture(held: ["grown.log"], remoteFiles: ["/data/grown.log": bytes])
        let manager = try TransferManager(directory: directory)
        let listed = RemoteEntry(name: "grown.log", path: "/data/grown.log", kind: .file, size: 1_000)
        try manager.enqueueCopy(of: listed.selectedForTransfer, from: other, to: profile, directory: "/srv", service: service)
        XCTAssertEqual(manager.items.first?.expectedBytes, 1_000)
        try await wait { await service.waiting == ["grown.log"] }
        XCTAssertEqual(manager.items.first?.expectedBytes, UInt64(bytes.count))
        await service.release("grown.log")
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .completed)
        XCTAssertEqual(manager.items.first?.progress.totalBytes, UInt64(bytes.count))
    }

    func testACopyReadsFromItsSourceConnectionAndIsBoundedByTheFolderItWasChosenFrom() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let service = UploadFixture(remoteFiles: ["/data/exports/dump.sql": bytes])
        let manager = try TransferManager(directory: directory)
        let entry = RemoteEntry(name: "dump.sql", path: "/data/exports/dump.sql", kind: .file, size: UInt64(bytes.count))
        let id = try manager.enqueueCopy(of: entry.selectedForTransfer, from: other, to: profile, directory: "/srv/backups", service: service)
        let queued = try XCTUnwrap(manager.items.first)
        XCTAssertTrue(queued.isCopy)
        XCTAssertEqual(queued.source, .remote(profile: other, path: "/data/exports/dump.sql", canonicalRoot: "/data/exports"))
        XCTAssertEqual(queued.profiles, [profile, other])
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.first?.state, .completed)
        let received = await service.received["dump.sql"]
        XCTAssertEqual(received, bytes)
        let request = try await XCTUnwrapAsync(await service.requests.first)
        XCTAssertEqual(request.profile, profile)
        XCTAssertEqual(request.request.limit, TransferManager.maximumCopyBytes)
        let streamed = await service.streamed
        XCTAssertEqual(streamed.map(\.profile), [other])
        XCTAssertEqual(streamed.map(\.root), ["/data/exports"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).path), "A copy stores nothing on this device")
        // A folder, an oversized file and a transport that can't read a source are refused when asked.
        XCTAssertThrowsError(try manager.enqueueCopy(of: .init(name: "folder", path: "/data/folder", kind: .directory), from: other, to: profile, directory: "/srv", service: service))
        XCTAssertThrowsError(try manager.enqueueCopy(of: .init(name: "huge.img", path: "/data/huge.img", kind: .file, size: TransferManager.maximumCopyBytes + 1),
                                                     from: other, to: profile, directory: "/srv", service: service))
        XCTAssertThrowsError(try manager.enqueueCopy(of: entry, from: other, to: profile, directory: "/srv", service: UploadOnlyFixture()))
    }

    /// Editing, removing or forgetting the host key of one connection stops only the transfers that use it,
    /// as either end. Others keep running or start once the stopped one drains.
    /// iOS may suspend the app the moment it gives back its background time, so by the time `interruptNow`
    /// returns the list, in memory and as saved, must already say what happened. Only the connection closing
    /// is left to wait for.
    func testAnInterruptionIsInTheSavedListBeforeItsConnectionHasClosed() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["held.bin"])
        let manager = try TransferManager(directory: directory)
        _ = try manager.enqueueUpload(consuming: try file("held.bin"), named: "held.bin", to: profile, directory: "/srv", service: service)
        _ = try manager.enqueueUpload(consuming: try file("queued.bin"), named: "queued.bin", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["held.bin"] }
        let draining = manager.interruptNow(reason: "Stopped by the test")
        // Nothing has been awaited since the call.
        XCTAssertEqual(manager.items.map(\.state), [.interrupted, .interrupted])
        let saved = String(decoding: try Data(contentsOf: directory.appendingPathComponent(TransferManager.listName)), as: UTF8.self)
        XCTAssertEqual(saved.components(separatedBy: "Stopped by the test").count - 1, 2, "Both rows are saved as interrupted.")
        await service.release("held.bin")
        await draining.value
        try await wait { manager.activeID == nil }
        XCTAssertEqual(manager.items.map(\.state), [.interrupted, .interrupted])
        let sent = await service.requests.map(\.request.name)
        XCTAssertEqual(sent, ["held.bin"], "The queued transfer never started.")
    }

    func testInterruptingOneConnectionsTransfersLeavesOthersRunning() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let third = ConnectionProfile(name: "Third", host: "third.invalid", username: "writer", identityID: UUID(), startingDirectory: "/srv")
        let service = UploadFixture(held: ["held.bin", "third-held.bin"], remoteFiles: ["/data/copy.bin": Data([1, 2, 3])])
        let manager = try TransferManager(directory: directory)
        let running = try manager.enqueueUpload(consuming: try file("third-held.bin"), named: "third-held.bin", to: third, directory: "/srv", service: service)
        let copy = try manager.enqueueCopy(of: .init(name: "copy.bin", path: "/data/copy.bin", kind: .file, size: 3), from: other, to: profile, directory: "/srv", service: service)
        let queued = try manager.enqueueUpload(consuming: try file("queued.bin"), named: "queued.bin", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["third-held.bin"] }

        // A copy is stopped by its source connection as well as its destination.
        await manager.interrupt(reason: "Changed", where: { $0.profiles.contains { $0.id == self.other.id } })
        XCTAssertEqual(manager.items.map(\.state), [.transferring, .interrupted, .queued])
        XCTAssertEqual(manager.items[1].message, "Changed")
        XCTAssertEqual(manager.activeID, running)
        var closes = await service.sessionCloses
        XCTAssertEqual(closes, 0)

        await manager.interrupt(reason: "Removed", where: { $0.profiles.contains { $0.id == third.id } })
        XCTAssertEqual(manager.items[0].state, .interrupted)
        closes = await service.sessionCloses
        XCTAssertGreaterThanOrEqual(closes, 1, "The active transfer's connections close so that it drains")
        // The queue isn't stopped: the next transfer starts and finishes.
        try await wait { manager.items.first { $0.id == queued }?.state == .completed }
        XCTAssertEqual(manager.items.first { $0.id == copy }?.state, .interrupted)
        let disconnects = await service.disconnects
        XCTAssertEqual(disconnects, 0, "Stopping some transfers must not lock keys the others use")

        // A transfer can't be retried over a connection that has changed since it was queued.
        var edited = other; edited.host = "elsewhere.invalid"
        XCTAssertThrowsError(try manager.retry(copy, profiles: [profile, edited], service: service))
        XCTAssertThrowsError(try manager.retry(copy, profiles: [profile], service: service))
        try manager.retry(copy, profiles: [other, profile], service: service)
        try await wait { manager.items.first { $0.id == copy }?.state == .completed }
    }

    func testDisconnectStopsEverythingAndNothingStartsInTheBackground() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["held.bin"])
        let manager = try TransferManager(directory: directory)
        let scene = UUID()
        manager.setForeground(true, sceneID: scene)
        let held = try manager.enqueueUpload(consuming: try file("held.bin"), named: "held.bin", to: profile, directory: "/srv", service: service)
        let queued = try manager.enqueueUpload(consuming: try file("queued.bin"), named: "queued.bin", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["held.bin"] }
        await manager.interrupt(reason: "Transfer interrupted. Retry to continue.")
        XCTAssertEqual(manager.items.map(\.state), [.interrupted, .interrupted])
        XCTAssertNil(manager.activeID)
        let disconnects = await service.disconnects
        XCTAssertGreaterThanOrEqual(disconnects, 1, "Disconnect locks keys, as it does for downloads")
        // Retried in the background, a transfer waits for the foreground, where its prompts can be shown.
        manager.setForeground(false, sceneID: scene)
        await service.release("held.bin")
        try manager.retry(queued, profiles: [profile], service: service)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.items.first { $0.id == queued }?.state, .queued)
        XCTAssertNil(manager.activeID)
        manager.setForeground(true, sceneID: scene)
        try await wait { manager.items.first { $0.id == queued }?.state == .completed }
        XCTAssertEqual(manager.items.first { $0.id == held }?.state, .interrupted)
    }

    func testRelaunchInterruptsPendingTransfersAndFailsAnUploadWhoseStagedFileIsGone() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["first.bin"])
        let manager = try TransferManager(directory: directory)
        let first = try manager.enqueueUpload(consuming: try file("first.bin"), named: "first.bin", to: profile, directory: "/srv", service: service)
        let second = try manager.enqueueUpload(consuming: try file("second.bin"), named: "second.bin", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["first.bin"] }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(second.uuidString))
        let stray = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        // A file that was being copied in when the app stopped was never queued.
        let incoming = directory.appendingPathComponent(TransferManager.incomingFolderName).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("half copied".utf8).write(to: incoming.appendingPathComponent("video.mov"))

        let reopened = try TransferManager(directory: directory)
        XCTAssertEqual(reopened.items.map(\.state), [.interrupted, .failed])
        XCTAssertEqual(reopened.items[1].message, RemoteUploadError.sourceUnavailable.localizedDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(first.uuidString).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "A folder no transfer owns is removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(TransferManager.incomingFolderName).path),
                       "Nothing owns what was being copied in for an upload that was never queued")
        XCTAssertThrowsError(try reopened.retry(second, profiles: [profile], service: service))
        manager.cancel(first)
        try await wait { manager.activeID == nil }
    }

    /// The partial copy is on the server, so what the list shows after the app was closed mid-transfer is what
    /// it had saved: progress is saved while a transfer runs, not only when it stops.
    func testATransferTheAppWasClosedOnStillShowsWhatWasSent() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["large.bin"], confirmsBeforeHolding: true)
        let manager = try TransferManager(directory: directory)
        manager.progressSaveInterval = .zero
        let source = try file("large.bin", Data(repeating: 7, count: 4_000))
        let id = try manager.enqueueUpload(consuming: source, named: "large.bin", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["large.bin"] }
        try await wait { manager.items.first?.sentBytes == 1_000 }

        // The app is closed: nothing tells the queue, and the next launch reads what was saved.
        let reopened = try TransferManager(directory: directory)
        let kept = try XCTUnwrap(reopened.items.first)
        XCTAssertEqual(kept.state, .interrupted)
        XCTAssertEqual(kept.sentBytes, 1_000)
        XCTAssertTrue(kept.keepsPartialBytes, "Transfers says how much was sent and that Retry continues from there")
        XCTAssertNotNil(kept.partialVersion)
        manager.cancel(id)
        try await wait { manager.activeID == nil }
    }

    /// The saved list can't be written while the device is locked. What a transfer did then is kept in memory
    /// and written when the app is back, so closing the app afterwards doesn't forget it.
    func testAListThatCouldNotBeSavedIsSavedWhenTheAppReturns() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["report.txt"])
        let manager = try TransferManager(directory: directory)
        manager.setForeground(true)
        _ = try manager.enqueueUpload(consuming: try file("report.txt"), named: "report.txt", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["report.txt"] }
        // As while locked: nothing can be written in the queue's folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        await service.release("report.txt")
        try await wait { manager.items.first?.state == .completed && manager.activeID == nil }
        XCTAssertNotNil(manager.persistenceError)
        // Read as a file: on iOS a queue can't even be opened on a folder it can't write to.
        let manifest = directory.appendingPathComponent("transfers.json")
        let saved = try XCTUnwrap(TransferManager.readList(manifest)).items
        XCTAssertNotEqual(saved.first?.state, .completed, "The saved list doesn't yet say it finished")

        // Coming to the front tries again, and on a device with a passcode that can still be too early.
        manager.setForeground(false)
        manager.setForeground(true)
        XCTAssertNotNil(manager.persistenceError)
        // Then iOS says protected files can be reached, with no change of scene and no progress to prompt a save.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        manager.saveIfUnsaved()
        XCTAssertNil(manager.persistenceError)
        XCTAssertEqual(try TransferManager(directory: directory).items.first?.state, .completed)

        // And coming to the front saves it when that is the first chance.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        manager.removeFinished()
        XCTAssertNotNil(manager.persistenceError)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        manager.setForeground(false)
        manager.setForeground(true)
        XCTAssertNil(manager.persistenceError)
        XCTAssertTrue(try TransferManager(directory: directory).items.isEmpty)
    }

    /// A transfer can finish while the device is locked, and the app can be closed before it is unlocked. On an
    /// iPhone that left the copy listed as interrupted part-way though the server held all of it, and Retry
    /// would have sent it again. What couldn't be saved to the list is written beside it and read at the next launch.
    func testATransferThatFinishedWhileTheListCouldNotBeSavedIsListedAsFinishedAtTheNextLaunch() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture(held: ["report.txt"], confirmsBeforeHolding: true)
        let manager = try TransferManager(directory: directory)
        manager.progressSaveInterval = .zero
        _ = try manager.enqueueUpload(consuming: try file("report.txt", Data(repeating: 7, count: 4_000)), named: "report.txt", to: profile, directory: "/srv", service: service)
        try await wait { await service.waiting == ["report.txt"] }
        // The device locks: the list can no longer be rewritten.
        struct Locked: Error {}
        manager.writeList = { _, _ in throw Locked() }
        await service.release("report.txt")
        try await wait { manager.items.first?.state == .completed && manager.activeID == nil }
        XCTAssertNotNil(manager.persistenceError)
        let list = directory.appendingPathComponent(TransferManager.listName), unsaved = directory.appendingPathComponent(TransferManager.unsavedListName)
        let saved = try XCTUnwrap(TransferManager.readList(list)).items
        XCTAssertEqual(saved.first?.state, .transferring, "The list itself still has the transfer under way")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsaved.path))

        // The app is closed and opened again, the device unlocked by then.
        let reopened = try TransferManager(directory: directory)
        XCTAssertEqual(reopened.items.map(\.state), [.completed])
        XCTAssertNil(reopened.items.first?.partialVersion)
        XCTAssertNil(reopened.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsaved.path), "Once the list is saved, the copy beside it goes")
        XCTAssertEqual(try TransferManager(directory: directory).items.map(\.state), [.completed])

        // Something beside the list that this didn't write is not believed over it.
        for bytes in ["[]", "not a list"] {
            try Data(bytes.utf8).write(to: unsaved)
            XCTAssertEqual(try TransferManager(directory: directory).items.map(\.state), [.completed], bytes)
        }
    }

    /// The list and the copy beside it can both be there, the copy having outlived a save: its removal failed,
    /// or the app ended between the two. Which was saved later is read from the count each carries and not
    /// from the files' dates, so an older one is never opened, to sweep the staged file of an upload queued
    /// since and then be saved over the newer.
    func testOfTheListAndTheCopyBesideItTheLaterSaveIsOpenedWhateverTheirDatesSay() async throws {
        let template = directory(); defer { try? FileManager.default.removeItem(at: template) }
        let service = UploadFixture(held: ["first.txt", "second.txt"])
        let manager = try TransferManager(directory: template)
        _ = try manager.enqueueUpload(consuming: try file("first.txt"), named: "first.txt", to: profile, directory: "/srv", service: service)
        let earlier = TransferManager.SavedList(revision: 40, items: manager.items)
        _ = try manager.enqueueUpload(consuming: try file("second.txt"), named: "second.txt", to: profile, directory: "/srv", service: service)
        let later = TransferManager.SavedList(revision: 41, items: manager.items)
        let second = try XCTUnwrap(manager.items.first { $0.filename == "second.txt" })
        await manager.interrupt(reason: "Stopped for the test.")

        let now = Date(), before = now.addingTimeInterval(-3_600)
        func opened(list: TransferManager.SavedList, copy: TransferManager.SavedList, listDated: Date, copyDated: Date,
                    copyReadable: Bool = true) throws -> (directory: URL, manager: Result<TransferManager, Error>) {
            let fresh = directory()
            addTeardownBlock {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fresh.appendingPathComponent(TransferManager.unsavedListName).path)
                try? FileManager.default.removeItem(at: fresh)
            }
            try FileManager.default.copyItem(at: template, to: fresh)
            for (name, saved, date) in [(TransferManager.listName, list, listDated), (TransferManager.unsavedListName, copy, copyDated)] {
                let url = fresh.appendingPathComponent(name)
                try JSONEncoder().encode(saved).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            if !copyReadable {
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fresh.appendingPathComponent(TransferManager.unsavedListName).path)
            }
            return (fresh, Result { try TransferManager(directory: fresh) })
        }
        func staged(in directory: URL) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(second.id.uuidString).appendingPathComponent("second.txt").path)
        }
        for (dates, listDated, copyDated) in [("the list dated later", now, before), ("both dated alike", now, now), ("the copy dated later", before, now)] {
            for (which, list, copy) in [("the list saved later", later, earlier), ("the copy saved later", earlier, later)] {
                let what = which + ", " + dates
                let (folder, result) = try opened(list: list, copy: copy, listDated: listDated, copyDated: copyDated)
                let reopened = try result.get()
                XCTAssertEqual(reopened.items.map(\.filename), ["first.txt", "second.txt"], what)
                XCTAssertTrue(staged(in: folder), "The upload queued since keeps its staged file: " + what)
                XCTAssertNil(reopened.persistenceError, what)
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(TransferManager.unsavedListName).path), what)
                let saved = try XCTUnwrap(TransferManager.readList(folder.appendingPathComponent(TransferManager.listName)))
                XCTAssertEqual(saved.items.map(\.filename), ["first.txt", "second.txt"], what)
                XCTAssertGreaterThan(saved.revision, later.revision, "The next save counts on from the later of the two: " + what)
            }
        }
        // A copy that can't be read, as on a device still locked, may be the later: nothing is opened on the
        // list alone, so nothing of the later one is swept or saved over.
        let (folder, result) = try opened(list: earlier, copy: later, listDated: now, copyDated: before, copyReadable: false)
        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(staged(in: folder))
        XCTAssertEqual(try XCTUnwrap(TransferManager.readList(folder.appendingPathComponent(TransferManager.listName))).revision, earlier.revision)
        // Nor is a file that can't even be looked at taken for one that isn't there.
        let closed = directory()
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closed.path)
            try? FileManager.default.removeItem(at: closed)
        }
        try JSONEncoder().encode(later).write(to: closed.appendingPathComponent(TransferManager.unsavedListName))
        XCTAssertNil(try TransferManager.readList(closed.appendingPathComponent(TransferManager.listName)))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        XCTAssertThrowsError(try TransferManager.readList(closed.appendingPathComponent(TransferManager.unsavedListName)))
    }

    func testOnlyOrdinaryNamesAndRegularFilesAreQueuedAndFinishedTransfersCanBeCleared() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadFixture()
        let manager = try TransferManager(directory: directory)
        let source = try file("fine.txt")
        for name in ["", ".", "..", "a/b", "nul\u{0}", ".rf-upload-x", "tab\tname"] {
            XCTAssertThrowsError(try manager.enqueueUpload(consuming: source, named: name, to: profile, directory: "/srv", service: service), name.debugDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "A refused file is left where it was")
        XCTAssertThrowsError(try manager.enqueueUpload(consuming: source.deletingLastPathComponent(), named: "folder", to: profile, directory: "/srv", service: service))
        XCTAssertTrue(manager.items.isEmpty)
        try manager.enqueueUpload(consuming: source, named: "fine.txt", to: profile, directory: "/srv", service: service)
        try await wait { manager.activeID == nil }
        manager.removeFinished()
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(try TransferManager(directory: directory).items.isEmpty, "The cleared list is what is saved")
    }

    func testNumberedNamesKeepTheExtensionAndPartialNamesAreOnlyTheAppsOwn() {
        XCTAssertEqual(Array(UploadRequest.numberedNames(for: "notes.txt").prefix(3)), ["notes.txt", "notes 2.txt", "notes 3.txt"])
        XCTAssertEqual(Array(UploadRequest.numberedNames(for: "archive.tar.gz").prefix(2)), ["archive.tar.gz", "archive.tar 2.gz"])
        XCTAssertEqual(Array(UploadRequest.numberedNames(for: ".profile").prefix(2)), [".profile", ".profile 2"])
        XCTAssertEqual(Array(UploadRequest.numberedNames(for: "Makefile").prefix(2)), ["Makefile", "Makefile 2"])
        XCTAssertEqual(UploadRequest.numberedNames(for: "notes.txt").count, 100)
        // A name at the length limit has no room for a number: those candidates are left out.
        let long = String(repeating: "n", count: 251) + ".txt"
        XCTAssertEqual(UploadRequest.numberedNames(for: long), [long])
        let id = UUID()
        XCTAssertTrue(UploadRequest.isPartialName(UploadRequest.partialName(for: id)))
        for name in ["notes.txt", ".rf-upload-.part", ".rf-upload-not-a-uuid.part", UploadRequest.partialName(for: id) + ".txt", "x" + UploadRequest.partialName(for: id)] {
            XCTAssertFalse(UploadRequest.isPartialName(name), name)
        }
        XCTAssertFalse(UploadRequest.isValidName(UploadRequest.partialName(for: id)), "A person's file is never given a partial copy's name")
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let unwrapped = await value()
    return try XCTUnwrap(unwrapped, file: file, line: line)
}

/// A destination that takes whatever its source sends, with failures and holds a test asks for.
private actor UploadFixture: RemoteFileUploading, RemoteFileStreaming, RemoteFileService, RemoteFileSessionClosing {
    struct Request { let profile: ConnectionProfile; let request: UploadRequest }
    struct Stream { let profile: ConnectionProfile; let path: String; let root: String }
    private(set) var requests: [Request] = []
    private(set) var received: [String: Data] = [:]
    private(set) var removedPartials: [String] = []
    private(set) var waiting: [String] = []
    private(set) var streamed: [Stream] = []
    private(set) var sessionCloses = 0, disconnects = 0
    private var held: Set<String>
    /// Errors to throw, in turn, once the transfer has started.
    private var failures: [String: [Error]]
    /// The name a file is given when it isn't the one asked for.
    private let published: [String: String]
    private let remoteFiles: [String: Data]
    /// Whether closing waits to be told to finish, as closing a real connection takes a moment.
    private var holdsClose: Bool
    private(set) var closing = false

    /// Whether a held transfer has had some of its bytes confirmed before it stops moving.
    private let confirmsBeforeHolding: Bool

    init(held: Set<String> = [], failures: [String: [Error]] = [:], published: [String: String] = [:], remoteFiles: [String: Data] = [:],
         holdsClose: Bool = false, confirmsBeforeHolding: Bool = false) {
        self.held = held; self.failures = failures; self.published = published; self.remoteFiles = remoteFiles
        self.holdsClose = holdsClose; self.confirmsBeforeHolding = confirmsBeforeHolding
    }
    func finishClose() { holdsClose = false }
    func release(_ name: String) { held.remove(name) }
    private func isHeld(_ name: String) -> Bool { held.contains(name) }
    private func nextFailure(_ name: String) -> Error? {
        guard var queue = failures[name], !queue.isEmpty else { return nil }
        let error = queue.removeFirst()
        failures[name] = queue
        return error
    }
    private func append(_ data: Data, to name: String) { received[name, default: Data()].append(data) }

    func uploadFile(profile: ConnectionProfile, request: UploadRequest, source: any TransferSource,
                    started: @escaping UploadStartHandler, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        requests.append(.init(profile: profile, request: request))
        let version = try await source.describe()
        await started(version, 0)
        if isHeld(request.name) {
            if confirmsBeforeHolding { await progress(.init(receivedBytes: min(1_000, version.size), totalBytes: version.size)) }
            waiting.append(request.name)
            while isHeld(request.name) { try await Task.sleep(for: .milliseconds(5)) }
        }
        if let failure = nextFailure(request.name) {
            // Some of it arrived before the failure.
            await progress(.init(receivedBytes: min(1_000, version.size), totalBytes: version.size))
            throw failure
        }
        received[request.name] = Data()
        try await source.send(from: 0, expecting: version) { [self] chunk in
            await append(chunk, to: request.name)
            await progress(.init(receivedBytes: UInt64(await received[request.name]?.count ?? 0), totalBytes: version.size))
        }
        try Task.checkCancellation()
        let name = request.conflict == .keepBoth ? published[request.name] ?? request.name : request.name
        return RemoteEntry(name: name, path: request.directory + "/" + name, kind: .file, size: version.size, modifiedAt: version.modifiedAt)
    }
    func removePartialUpload(profile: ConnectionProfile, directory: String, partialName: String, restoring name: String?) async throws { removedPartials.append(partialName) }

    func transferVersion(profile: ConnectionProfile, path: String, canonicalRoot: String) async throws -> TransferSourceVersion {
        guard let bytes = remoteFiles[path] else { throw RemoteFileError.notFound }
        return TransferSourceVersion(size: UInt64(bytes.count), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }
    func readFileRange(profile: ConnectionProfile, path: String, canonicalRoot: String, offset: UInt64, count: Int) async throws -> Data {
        guard let bytes = remoteFiles[path] else { throw RemoteFileError.notFound }
        return bytes.subdata(in: Int(offset)..<Int(offset) + count)
    }
    func streamFile(profile: ConnectionProfile, path: String, canonicalRoot: String, from offset: UInt64,
                    expecting version: TransferSourceVersion, consume: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard let bytes = remoteFiles[path] else { throw RemoteFileError.notFound }
        streamed.append(.init(profile: profile, path: path, root: canonicalRoot))
        for start in stride(from: Int(offset), to: bytes.count, by: 16_384) {
            try await consume(bytes.subdata(in: start..<min(bytes.count, start + 16_384)))
        }
    }

    func closeSessionPreservingUnlockedIdentities() async {
        closing = true
        while holdsClose { try? await Task.sleep(for: .milliseconds(5)) }
        closing = false
        sessionCloses += 1
    }
    func disconnect() async { disconnects += 1 }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { throw RemoteFileError.unsupportedFile }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { throw RemoteFileError.unsupportedFile }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry { throw RemoteFileError.unsupportedFile }
}

/// A transport that can write and can't read a file from another server.
private struct UploadOnlyFixture: RemoteFileUploading {
    func uploadFile(profile: ConnectionProfile, request: UploadRequest, source: any TransferSource,
                    started: @escaping UploadStartHandler, progress: @escaping DownloadProgressHandler) async throws -> RemoteEntry {
        throw RemoteFileError.unsupportedFile
    }
    func removePartialUpload(profile: ConnectionProfile, directory: String, partialName: String, restoring name: String?) async throws {}
}
