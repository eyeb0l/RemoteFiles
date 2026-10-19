import XCTest
import Foundation
import NIOSSH
@testable import RemoteFilesCore

/// Opt-in timings for `scripts/benchmark-latency.sh`, which runs them through a delaying proxy.
/// Each line reports the median and fastest of the configured runs in milliseconds.
final class LatencyBenchmarkTests: XCTestCase {
    func testRoundTripSensitiveOperations() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["REMOTEFILES_BENCHMARK"] == "1", let dir = env["REMOTEFILES_SFTP_FIXTURE"],
              let port = Int(env["REMOTEFILES_SFTP_PORT"] ?? ""), let user = env["REMOTEFILES_SFTP_USER"] else {
            throw XCTSkip("Benchmark is opt-in")
        }
        let label = env["REMOTEFILES_BENCHMARK_LABEL"] ?? "unlabelled"
        let runs = Int(env["REMOTEFILES_BENCHMARK_RUNS"] ?? "") ?? 5
        let folder = URL(fileURLWithPath: dir).appendingPathComponent(UUID().uuidString)
        let identity = IdentityStore(secretStore: BenchmarkSecrets())
        let metadata = try MetadataStore(fileURL: folder.appendingPathComponent("metadata.json"))
        let trust = try HostTrustStore(fileURL: folder.appendingPathComponent("trust.json"))
        let key = try await identity.generate(name: "Benchmark")
        let keys = try FileHandle(forWritingTo: URL(fileURLWithPath: dir + "/authorized_keys"))
        try keys.seekToEnd(); try keys.write(contentsOf: Data((key.publicKey + "\n").utf8)); try keys.close()
        let files = dir + "/files"
        let profile = ConnectionProfile(name: "Benchmark", host: "127.0.0.1", port: port, username: user,
                                        identityID: key.id, startingDirectory: files)
        var value = AppMetadata(); value.identities = [key]; value.connections = [profile]
        try await metadata.save(value)
        let hostKey = try String(contentsOfFile: dir + "/host.pub", encoding: .utf8)
        try await trust.trustUnknown(endpoint: HostEndpoint(host: "127.0.0.1", port: port),
                                     key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: hostKey)))
        func service() -> SFTPRemoteFileService {
            SFTPRemoteFileService(identityStore: identity, trustStore: trust, metadataStore: metadata, timeoutSeconds: 60)
        }
        var lines: [String] = []
        func measure(_ name: String, _ body: () async throws -> Void) async throws {
            var samples: [Double] = []
            for _ in 0..<runs {
                let start = ContinuousClock.now
                try await body()
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            }
            samples.sort()
            lines.append(String(format: "BENCH %@ | %@ | median %.0f ms | fastest %.0f ms", label, name, samples[samples.count / 2], samples[0]))
        }

        try await measure("connect + list folder (cold)") {
            let cold = service()
            _ = try await cold.listDirectory(profile: profile, path: files)
            await cold.disconnect()
        }
        let warm = service()
        defer { Task { await warm.disconnect() } }
        _ = try await warm.listDirectory(profile: profile, path: files)
        try await measure("list folder") { _ = try await warm.listDirectory(profile: profile, path: files) }
        try await measure("list 1,000 entries") { _ = try await warm.listDirectory(profile: profile, path: files + "/thousand") }
        try await measure("resolve symlink") { _ = try await warm.resolveEntry(profile: profile, path: files + "/report-link.md") }
        try await measure("read 50 B file") { _ = try await warm.readFile(profile: profile, path: files + "/report.md", limit: 2_097_152) }
        try await measure("read 173 KB report") { _ = try await warm.readFile(profile: profile, path: files + "/large-report.md", limit: 2_097_152) }
        guard case .contents(_, let version?) = try await warm.readFileIfChanged(
            profile: profile, path: files + "/large-report.md", allowedRoot: nil, limit: 2_097_152, since: nil) else { return XCTFail() }
        try await measure("reopen unchanged 173 KB report") {
            _ = try await warm.readFileIfChanged(profile: profile, path: files + "/large-report.md", allowedRoot: nil, limit: 2_097_152, since: version)
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await measure("download 3 MiB file") {
            _ = try await warm.downloadFile(profile: profile, path: files + "/oversized.txt", allowedRoot: files, destination: temp, limit: 4 * 1024 * 1024)
        }
        print(lines.joined(separator: "\n"))
    }
}

private final class BenchmarkSecrets: IdentitySecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func save(_ value: Data, reference: String) throws { lock.lock(); defer { lock.unlock() }; data[reference] = value }
    func load(reference: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = data[reference] else { throw IdentityError.missingSecret }
        return value
    }
    func delete(reference: String) throws { lock.lock(); defer { lock.unlock() }; data.removeValue(forKey: reference) }
}
