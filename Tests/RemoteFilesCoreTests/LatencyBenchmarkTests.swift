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
        addTeardownBlock { await warm.disconnect() }
        _ = try await warm.listDirectory(profile: profile, path: files)
        try await measure("list folder") { _ = try await warm.listDirectory(profile: profile, path: files) }
        try await measure("list 1,000 entries") { _ = try await warm.listDirectory(profile: profile, path: files + "/thousand") }
        try await measure("resolve symlink") { _ = try await warm.resolveEntry(profile: profile, path: files + "/report-link.md") }
        try await measure("resolve document link") {
            _ = try await warm.resolveDocumentLink(profile: profile, documentPath: files + "/large-report.md", reference: "report.md")
        }
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
        // Uploads: each goes to a new name in a folder of this run's own, under its partial name first.
        let uploads = files + "/benchmark-uploads-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: uploads, withIntermediateDirectories: false)
        let sources = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-sources-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: uploads); try? FileManager.default.removeItem(at: sources) }
        let small = sources.appendingPathComponent("small"), large = sources.appendingPathComponent("large")
        try Data(repeating: 0x41, count: 50).write(to: small)
        try Data((0..<3 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: large)
        func upload(_ source: any TransferSource, over transport: any RemoteFileUploading) async throws {
            _ = try await transport.uploadFile(profile: profile,
                request: .init(directory: uploads, name: UUID().uuidString + ".bin", conflict: .fail,
                               partialName: UploadRequest.partialName(for: UUID()), limit: 64 * 1024 * 1024),
                source: source, started: { _, _ in }, progress: { _ in })
        }
        try await measure("upload 50 B file") { try await upload(LocalFileTransferSource(url: small), over: warm) }
        try await measure("upload 3 MiB file") { try await upload(LocalFileTransferSource(url: large), over: warm) }
        // As the transfer queue sends a batch: every file after the first finds the channel open.
        let batch = SnapshotTransferBatch()
        func queued(_ source: any TransferSource) async throws {
            _ = try await warm.uploadFile(profile: profile,
                request: .init(directory: uploads, name: UUID().uuidString + ".bin", conflict: .fail,
                               partialName: UploadRequest.partialName(for: UUID()), limit: 64 * 1024 * 1024),
                source: source, batch: batch, started: { _, _ in }, progress: { _ in })
        }
        try await queued(LocalFileTransferSource(url: small))
        try await measure("upload 50 B file, queued") { try await queued(LocalFileTransferSource(url: small)) }
        try await measure("upload 3 MiB file, queued") { try await queued(LocalFileTransferSource(url: large)) }
        await warm.endSnapshotBatch(batch)
        // A copy reads over one connection while it writes over another, as between two servers.
        let reader = service()
        addTeardownBlock { await reader.disconnect() }
        _ = try await reader.listDirectory(profile: profile, path: files)
        try await measure("copy 3 MiB file between connections") {
            try await upload(RemoteFileTransferSource(service: reader, profile: profile, path: files + "/oversized.txt", canonicalRoot: files), over: warm)
        }
        // As the queue copies a batch: one channel on each server, already open after the first file.
        let reads = SnapshotTransferBatch(), writes = SnapshotTransferBatch()
        func queuedCopy() async throws {
            var source = RemoteFileTransferSource(service: reader, profile: profile, path: files + "/oversized.txt", canonicalRoot: files)
            source.batch = reads
            _ = try await warm.uploadFile(profile: profile,
                request: .init(directory: uploads, name: UUID().uuidString + ".bin", conflict: .fail,
                               partialName: UploadRequest.partialName(for: UUID()), limit: 64 * 1024 * 1024),
                source: source, batch: writes, started: { _, _ in }, progress: { _ in })
        }
        try await queuedCopy()
        try await measure("copy 3 MiB file between connections, queued") { try await queuedCopy() }
        await reader.endSnapshotBatch(reads); await warm.endSnapshotBatch(writes)
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
