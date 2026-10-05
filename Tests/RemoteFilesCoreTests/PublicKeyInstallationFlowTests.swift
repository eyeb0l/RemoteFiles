#if os(iOS)
import XCTest
import Crypto
import NIOSSH
import RemoteFilesCore
@testable import RemoteFilesUI

private actor ControlledKeyInstaller: PublicKeyInstalling {
    private(set) var requests: [PublicKeyInstallationRequest] = []
    private var pending: [Int: CheckedContinuation<PublicKeyInstallationResult, Error>] = [:]
    private(set) var cancellations = 0
    func install(_ request: PublicKeyInstallationRequest, password: String) async throws -> PublicKeyInstallationResult {
        requests.append(request); let call = requests.count
        // Deliberately return even after caller cancellation to exercise stale-publication guards.
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }
    func cancelAll() {
        cancellations += 1
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
    func waiting(_ call: Int) -> Bool { pending[call] != nil }
    func finish(_ call: Int, result: Result<PublicKeyInstallationResult, Error>) { pending.removeValue(forKey: call)?.resume(with: result) }
}

@MainActor final class PublicKeyInstallationFlowTests: XCTestCase {
    private func identity() throws -> IdentityMetadata {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        return .init(name: "Fixture public identity", publicKey: String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey),
                     fingerprint: "SHA256:fixture", requiresPassphrase: true, keychainReference: "never-read")
    }
    private func wait(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "FixtureDeadline", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testReviewAndPasswordRequiredBeforeWriteRepeatedConfirmRunsOnceAndRetryRecognizesDuplicate() async throws {
        let installer = ControlledKeyInstaller(); let flow = PublicKeyInstallationFlow(installer: installer)
        flow.confirm(password: "fixture password")
        let initial = await installer.requests; XCTAssertTrue(initial.isEmpty)
        flow.prepare(host: "first.fixture.invalid", port: 22, username: "fixture", identity: try identity())
        XCTAssertEqual(flow.review?.account, "fixture@first.fixture.invalid:22")
        flow.confirm(password: "")
        let withoutPassword = await installer.requests; XCTAssertTrue(withoutPassword.isEmpty)
        flow.confirm(password: "fixture password"); flow.confirm(password: "fixture password")
        try await wait { await installer.waiting(1) }
        let one = await installer.requests; XCTAssertEqual(one.count, 1)
        await installer.finish(1, result: .success(.installed)); try await wait { !flow.isWorking }
        XCTAssertEqual(flow.result, .installed); XCTAssertNil(flow.review)
        XCTAssertTrue(flow.message?.contains("fixture@first.fixture.invalid:22") == true)
        flow.prepare(host: "first.fixture.invalid", port: 22, username: "fixture", identity: try identity())
        flow.confirm(password: "fixture password"); try await wait { await installer.waiting(2) }
        await installer.finish(2, result: .success(.alreadyInstalled)); try await wait { !flow.isWorking }
        XCTAssertEqual(flow.result, .alreadyInstalled)
    }
    func testCancelAndLateSuccessCannotPublishIntoNewAttemptFailureCanBeRetried() async throws {
        let installer = ControlledKeyInstaller(); let flow = PublicKeyInstallationFlow(installer: installer)
        flow.prepare(host: "first.fixture.invalid", port: 22, username: "fixture", identity: try identity())
        flow.confirm(password: "fixture password"); try await wait { await installer.waiting(1) }
        flow.cancel(); XCTAssertFalse(flow.isWorking); XCTAssertNil(flow.review)
        flow.prepare(host: "second.fixture.invalid", port: 2222, username: "second", identity: try identity())
        flow.confirm(password: "fixture password"); try await wait { await installer.waiting(2) }
        await installer.finish(1, result: .success(.installed)); await Task.yield()
        XCTAssertTrue(flow.isWorking); XCTAssertNil(flow.result)
        await installer.finish(2, result: .failure(PublicKeyInstallationError.uncertainOutcome)); try await wait { !flow.isWorking }
        XCTAssertNil(flow.result); XCTAssertNil(flow.review); XCTAssertTrue(flow.message?.contains("may have been added") == true)
        flow.prepare(host: "second.fixture.invalid", port: 2222, username: "second", identity: try identity())
        flow.confirm(password: "fixture password"); try await wait { await installer.waiting(3) }
        await installer.finish(3, result: .success(.alreadyInstalled)); try await wait { !flow.isWorking }
        XCTAssertEqual(flow.result, .alreadyInstalled)
    }
    func testUnknownHostRequiresTrustAndNewReviewChangedHostNeverOffersTrustReplacement() async throws {
        let installer = ControlledKeyInstaller(); let flow = PublicKeyInstallationFlow(installer: installer)
        let identity = try identity(), endpoint = HostEndpoint(host: "fixture.invalid")
        let key = try HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: identity.publicKey))
        flow.prepare(host: endpoint.host, port: 22, username: "fixture", identity: identity)
        flow.confirm(password: "fixture password"); try await wait { await installer.waiting(1) }
        await installer.finish(1, result: .failure(HostTrustError.unknown(endpoint: endpoint, key: key))); try await wait { !flow.isWorking }
        XCTAssertEqual(flow.unverifiedHost?.0, endpoint); XCTAssertNil(flow.review)
        flow.hostAccepted(); flow.confirm(password: "fixture password")
        let stillOne = await installer.requests; XCTAssertEqual(stillOne.count, 1, "Host acceptance never retries a write automatically")
        flow.prepare(host: endpoint.host, port: 22, username: "fixture", identity: identity)
        flow.confirm(password: "fixture password"); try await wait { await installer.waiting(2) }
        await installer.finish(2, result: .failure(HostTrustError.changed(endpoint: endpoint, previous: key, current: key))); try await wait { !flow.isWorking }
        XCTAssertNil(flow.unverifiedHost); XCTAssertNil(flow.result); XCTAssertTrue(flow.message?.contains("blocked") == true)
    }
}
#endif
