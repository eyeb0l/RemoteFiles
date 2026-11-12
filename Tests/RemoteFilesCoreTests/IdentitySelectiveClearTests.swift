import XCTest
import Foundation
@testable import RemoteFilesCore

/// A biometric store whose loads can be held, so an unlock is in progress while keys are cleared.
private final class GatedBiometrics: BiometricKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var pausing = false
    func pause() { lock.lock(); pausing = true; lock.unlock() }
    func resume() {
        lock.lock(); pausing = false; let waiting = held; held = []; lock.unlock()
        waiting.forEach { $0.resume() }
    }
    var heldLoads: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    func save(_ data: Data, reference: String) throws { lock.lock(); storage[reference] = data; lock.unlock() }
    func load(reference: String, reason: String) async throws -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pausing { held.append(continuation); lock.unlock() } else { lock.unlock(); continuation.resume() }
        }
        lock.lock(); defer { lock.unlock() }
        guard let data = storage[reference] else { throw IdentityError.biometricsUnavailable }
        return data
    }
    func contains(reference: String) -> Bool { lock.lock(); defer { lock.unlock() }; return storage[reference] != nil }
    func delete(reference: String) throws { lock.lock(); storage.removeValue(forKey: reference); lock.unlock() }
}

/// A connection change closes the connection but not the session: keys other connections use stay unlocked.
final class IdentitySelectiveClearTests: XCTestCase {
    func testClearingKeepingSomeKeysLocksOnlyTheOthers() async throws {
        let store = EncryptedKeyFixture.makeStore()
        let kept = try await EncryptedKeyFixture.importKey(into: store, name: "Kept")
        let dropped = try await EncryptedKeyFixture.importKey(into: store, name: "Dropped")
        let alsoDropped = try await EncryptedKeyFixture.importKey(into: store, name: "Also dropped")
        for identity in [kept, dropped, alsoDropped] { try await EncryptedKeyFixture.unlock(identity, in: store) }
        await store.clearSession(keeping: [kept.id])
        let keptUnlocked = try await EncryptedKeyFixture.isUnlocked(kept, in: store)
        let droppedUnlocked = try await EncryptedKeyFixture.isUnlocked(dropped, in: store)
        let alsoDroppedUnlocked = try await EncryptedKeyFixture.isUnlocked(alsoDropped, in: store)
        XCTAssertTrue(keptUnlocked)
        XCTAssertFalse(droppedUnlocked)
        XCTAssertFalse(alsoDroppedUnlocked)
        // A locked key unlocks again as usual, and keeping nothing is the same as clearing the session.
        try await EncryptedKeyFixture.unlock(dropped, in: store)
        await store.clearSession(keeping: [])
        let keptAfterwards = try await EncryptedKeyFixture.isUnlocked(kept, in: store)
        let droppedAfterwards = try await EncryptedKeyFixture.isUnlocked(dropped, in: store)
        XCTAssertFalse(keptAfterwards); XCTAssertFalse(droppedAfterwards)
    }

    func testAnIdentityIDNoKeyHasIsIgnored() async throws {
        let store = EncryptedKeyFixture.makeStore()
        let identity = try await EncryptedKeyFixture.importKey(into: store)
        try await EncryptedKeyFixture.unlock(identity, in: store)
        await store.clearSession(keeping: [identity.id, UUID()])
        let unlocked = try await EncryptedKeyFixture.isUnlocked(identity, in: store)
        XCTAssertTrue(unlocked)
    }

    /// An unlock under way when its key is cleared caches nothing, as after `clearSession()`; one for a key
    /// that is kept completes; one begun afterwards is not affected by the earlier clear.
    func testUnlockInProgressWhenItsKeyIsClearedCachesNothingAndOthersComplete() async throws {
        let biometrics = GatedBiometrics()
        let store = EncryptedKeyFixture.makeStore(biometrics: biometrics)
        let kept = try await EncryptedKeyFixture.importKey(into: store, name: "Kept")
        let evicted = try await EncryptedKeyFixture.importKey(into: store, name: "Evicted")
        for identity in [kept, evicted] {
            try await EncryptedKeyFixture.unlock(identity, in: store)
            try await store.enableBiometricUnlock(identity)
        }
        await store.clearSession()
        biometrics.pause()
        let keptUnlock = Task { try await store.unlockWithBiometrics(kept, reason: "Test") }
        let evictedUnlock = Task { try await store.unlockWithBiometrics(evicted, reason: "Test") }
        for _ in 0..<400 where biometrics.heldLoads < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(biometrics.heldLoads, 2, "Both unlocks are in progress")
        await store.clearSession(keeping: [kept.id])
        biometrics.resume()
        _ = try await keptUnlock.value
        do { _ = try await evictedUnlock.value; XCTFail("An unlock of a cleared key must not complete") }
        catch IdentityError.sessionEnded { }
        let keptUnlocked = try await EncryptedKeyFixture.isUnlocked(kept, in: store)
        let evictedUnlocked = try await EncryptedKeyFixture.isUnlocked(evicted, in: store)
        XCTAssertTrue(keptUnlocked, "The unlock of a kept key was not cancelled")
        XCTAssertFalse(evictedUnlocked, "The cleared key's unlock cached nothing")
        // Unlocking the cleared key afterwards works, so the clear didn't poison the identity.
        _ = try await store.unlockWithBiometrics(evicted, reason: "Test")
        let unlockedAgain = try await EncryptedKeyFixture.isUnlocked(evicted, in: store)
        XCTAssertTrue(unlockedAgain)
    }

    func testClearingBeforeAnUnlockDoesNotStopIt() async throws {
        let store = EncryptedKeyFixture.makeStore()
        let identity = try await EncryptedKeyFixture.importKey(into: store)
        await store.clearSession(keeping: [])
        try await EncryptedKeyFixture.unlock(identity, in: store)
        let unlocked = try await EncryptedKeyFixture.isUnlocked(identity, in: store)
        XCTAssertTrue(unlocked, "A clear before the unlock does not stop a later one")
    }
}
