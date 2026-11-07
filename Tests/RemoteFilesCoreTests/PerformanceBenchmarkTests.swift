import XCTest
import Foundation
import NIOSSH
@testable import RemoteFilesCore
@testable import RemoteFilesUI
#if os(iOS)
import SwiftUI
import UIKit
#endif

/// Measurements for `scripts/benchmark_performance.py`, which supplies a generated tree, a delaying
/// proxy and an optimized build. Each scenario prints one `BENCHJSON` line of raw samples; the script
/// keeps them and compares runs. Nothing here asserts a timing, so shared machines can't fail it.
/// Without `REMOTEFILES_PERFORMANCE_BENCHMARK=1` each method runs once at its smallest size, so CI keeps
/// the harness working in moments. See docs/PERFORMANCE.md.
final class PerformanceBenchmarkTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var measuring: Bool { environment["REMOTEFILES_PERFORMANCE_BENCHMARK"] == "1" }
    private var runs: Int { measuring ? Int(environment["REMOTEFILES_BENCHMARK_RUNS"] ?? "") ?? 5 : 1 }
    /// A comma-separated list of scenario prefixes; everything runs without one.
    private func selected(_ scenario: String) -> Bool {
        guard let filter = environment["REMOTEFILES_BENCHMARK_ONLY"], !filter.isEmpty else { return true }
        return filter.split(separator: ",").contains { scenario.hasPrefix($0) }
    }

    // MARK: - Work that needs no network

    func testLocalWork() async throws {
        let recorder = BenchmarkRecorder(label: environment["REMOTEFILES_BENCHMARK_LABEL"] ?? "unlabelled")
        let sizes = (environment["REMOTEFILES_BENCHMARK_SIZES"] ?? (measuring ? "100,1000,10000,100000" : "100")).split(separator: ",").compactMap { Int($0) }
        for size in sizes {
            let entries = BenchmarkData.entries(count: size)
            let snapshot = DirectorySnapshot(path: "/bench", entries: entries)
            let repeats = size >= 100_000 ? min(runs, 3) : runs
            if selected("prepare") {
                try recorder.time("prepare.\(size)", runs: repeats) { blackHole(FolderListing(snapshot).rows.count) }
                try recorder.retainedBytes("prepare.retained.\(size)") { FolderListing(snapshot) }
            }
            if selected("sortname") {
                try recorder.time("sortname.\(size)", runs: repeats) {
                    blackHole(entries.sorted { FolderListing.precedes($0, $1, by: .name) }.count)
                }
            }
            if selected("rows") {
                try recorder.time("rows.\(size)", runs: repeats) { blackHole(entries.map(FolderRow.init).count) }
            }
            let listing = FolderListing(snapshot)
            let scenarios: [(String, String, FolderSortOrder, SearchQueryOptions)] = [
                ("filter.hit", "report", .name, .init()),
                ("filter.miss", "zzzqq", .name, .init()),
                ("filter.unicode", "東京", .name, .init()),
                ("filter.word", "report", .name, .init(wholeWord: true)),
                ("filter.extension", "", .name, .init(fileExtension: "md")),
                ("sort.modified", "", .modified, .init()),
                ("sort.size", "", .size, .init()),
                ("sort.kind", "", .kind, .init()),
            ]
            for (name, query, order, options) in scenarios where selected(name) {
                try recorder.time("\(name).\(size)", runs: repeats) {
                    blackHole(listing.visible(query: query, showHidden: true, order: order, options: options).count)
                }
            }
            if selected("subtitle") {
                try recorder.time("subtitle.\(size)", runs: repeats) {
                    var total = 0
                    for row in listing.rows { total &+= row.subtitle.utf8.count }
                    blackHole(total)
                }
            }
            if selected("append") {
                try recorder.time("append.\(size)", runs: repeats) {
                    var total = 0
                    for entry in entries { total &+= RemotePath.appending(entry.name, to: "/srv/projects/remote").utf8.count }
                    blackHole(total)
                }
            }
        }
        recorder.flush()
    }

    // MARK: - The real transport against OpenSSH

    func testTransport() async throws {
        // A physical device can't reach the fixture's files, so it is handed the keys it needs instead.
        let dir = environment["REMOTEFILES_SFTP_FIXTURE"], handedKey = environment["REMOTEFILES_BENCHMARK_PRIVATE_KEY"]
        guard dir != nil || handedKey != nil, let port = Int(environment["REMOTEFILES_SFTP_PORT"] ?? ""),
              handedKey != nil || environment["REMOTEFILES_SFTP_USER"] != nil else {
            throw XCTSkip("Needs the OpenSSH fixture")
        }
        let user = environment["REMOTEFILES_SFTP_USER"] ?? NSUserName()
        let root = try environment["REMOTEFILES_BENCHMARK_ROOT"] ?? Self.makeSmokeTree(in: dir ?? "")
        let recorder = BenchmarkRecorder(label: environment["REMOTEFILES_BENCHMARK_LABEL"] ?? "unlabelled")
        let host = environment["REMOTEFILES_SFTP_HOST"] ?? "127.0.0.1"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let identity = IdentityStore(secretStore: BenchmarkSecrets())
        let metadata = try MetadataStore(fileURL: folder.appendingPathComponent("metadata.json"))
        let trust = try HostTrustStore(fileURL: folder.appendingPathComponent("trust.json"))
        let key: IdentityMetadata
        if let handedKey {
            key = try await identity.importKey(name: "Benchmark", openSSH: handedKey)
        } else {
            key = try await identity.generate(name: "Benchmark")
            let keys = try FileHandle(forWritingTo: URL(fileURLWithPath: (dir ?? "") + "/authorized_keys"))
            try keys.seekToEnd(); try keys.write(contentsOf: Data((key.publicKey + "\n").utf8)); try keys.close()
        }
        let profile = ConnectionProfile(name: "Benchmark", host: host, port: port, username: user,
                                        identityID: key.id, startingDirectory: root)
        var value = AppMetadata(); value.identities = [key]; value.connections = [profile]
        try await metadata.save(value)
        let hostKey = try environment["REMOTEFILES_BENCHMARK_HOST_KEY"] ?? String(contentsOfFile: (dir ?? "") + "/host.pub", encoding: .utf8)
        try await trust.trustUnknown(endpoint: HostEndpoint(host: host, port: port),
                                     key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: hostKey)))
        func service() -> SFTPRemoteFileService {
            SFTPRemoteFileService(identityStore: identity, trustStore: trust, metadataStore: metadata, timeoutSeconds: 120)
        }

        if selected("connect") {
            try await recorder.timeAsync("connect.list", runs: runs) {
                let cold = service()
                _ = try await cold.listDirectory(profile: profile, path: root + "/d10")
                let measured = await cold.metrics().lastConnectionSeconds
                recorder.add("connect.only", value: measured * 1000)
                await cold.disconnect()
            }
        }
        let warm = service()
        addTeardownBlock { await warm.disconnect() }
        _ = try await warm.listDirectory(profile: profile, path: root + "/d10")

        for size in measuring ? [10, 100, 1_000, 9_900] : [10] where selected("list.\(size)") || selected("open.\(size)") {
            let path = "\(root)/d\(size)"
            try await recorder.timeAsync("list.\(size)", runs: runs) {
                blackHole(try await warm.listDirectory(profile: profile, path: path).entries.count)
            }
            // Work done here, not at the server or on the wire.
            let cpu = BenchmarkMemory.processCPU()
            blackHole(try await warm.listDirectory(profile: profile, path: path).entries.count)
            recorder.add("list.\(size).clientCPU", value: BenchmarkMemory.processCPU() - cpu)
            if size >= 1_000 {
                try await recorder.peakFootprint("list.\(size).peakMB", runs: 1) {
                    blackHole(try await warm.listDirectory(profile: profile, path: path).entries.count)
                }
            }
            // What a person waits for when they tap a folder: the transport, then rows ready to show.
            try await recorder.timeAsync("open.\(size)", runs: runs) {
                let snapshot = try await warm.listDirectory(profile: profile, path: path)
                let listing = await Task.detached(priority: .userInitiated) { FolderListing(snapshot) }.value
                blackHole(listing.visible(query: "", showHidden: false, order: .name).count)
            }
            try await recorder.timeAsync("first.\(size)", runs: runs) {
                try await self.measureFirstRows("first.\(size)", path: path, profile: profile, service: warm, recorder: recorder)
            }
        }
        if measuring, selected("prefetch") {
            // What opening a folder does ahead of time for the next tap.
            let folders = try await warm.listDirectory(profile: profile, path: root + "/tree").entries.filter { $0.kind == .directory }.prefix(3)
            let deeper = try await warm.listDirectory(profile: profile, path: folders.first?.path ?? root).entries.filter { $0.kind == .directory }.prefix(3)
            let paths = (folders + deeper).map(\.path)
            try await recorder.timeAsync("prefetch.6", runs: runs) {
                for path in paths { blackHole(try await warm.listDirectoryInBackground(profile: profile, path: path)?.entries.count ?? 0) }
            }
        }
        if measuring, selected("list.links") {
            try await recorder.timeAsync("list.links", runs: runs) {
                blackHole(try await warm.listDirectory(profile: profile, path: root + "/links").entries.count)
            }
            try await recorder.timeAsync("first.links", runs: runs) {
                try await self.measureFirstRows("first.links", path: root + "/links", profile: profile, service: warm, recorder: recorder)
            }
        }
        if measuring, selected("list.100000") {
            // Time for Instruments to attach, when asked for.
            if let wait = environment["REMOTEFILES_BENCHMARK_ATTACH_WAIT"].flatMap({ Int($0) }) {
                print("BENCHWAIT \(ProcessInfo.processInfo.processIdentifier)")
                try await Task.sleep(for: .seconds(wait))
            }
            if environment["REMOTEFILES_BENCHMARK_ONLY"] == "list.100000" {
                // Alone in a fresh process, the kernel's own peak covers this listing and nothing larger.
                let before = BenchmarkMemory.footprint()
                blackHole(try await warm.listDirectory(profile: profile, path: root + "/d100000").entries.count)
                recorder.add("list.100000.lifetimePeakMB", value: Double(BenchmarkMemory.lifetimePeakFootprint() - before) / 1_048_576, unit: "MB")
                recorder.add("list.100000.afterMB", value: Double(BenchmarkMemory.footprint() - before) / 1_048_576, unit: "MB")
            }
            // Over the listing limit before this work: the time to the answer, whatever the answer is.
            try await recorder.timeAsync("list.100000", runs: min(runs, 3), tolerateFailure: true) {
                let count = try await warm.listDirectory(profile: profile, path: root + "/d100000").entries.count
                recorder.add("list.100000.entries", value: Double(count), unit: "entries")
            }
            try await recorder.peakFootprint("list.100000.peakMB", runs: 1) {
                blackHole((try? await warm.listDirectory(profile: profile, path: root + "/d100000").entries.count) ?? 0)
            }
        }
        if selected("search") {
            // Lets one run compare how many folders are listed at once.
            let window = environment["REMOTEFILES_BENCHMARK_SEARCH_WINDOW"].flatMap { Int($0) }
            let limits = window.map { RemoteFolderSearch.Limits(concurrentListings: $0, concurrentListingLimit: $0) } ?? RemoteFolderSearch.Limits()
            for (name, query) in [("search.few", "needle"), ("search.none", "zzzqq")] {
                try await recorder.timeAsync("\(name).total", runs: runs) {
                    var first: Double?, matches = 0
                    let started = ContinuousClock.now
                    for try await update in RemoteFolderSearch.names(matching: query, below: root + "/tree", profile: profile,
                                                                     service: warm, includeHidden: false, limits: limits) {
                        if first == nil, !update.matches.isEmpty { first = started.elapsedMilliseconds }
                        matches += update.matches.count
                        if update.isFinished { recorder.add("\(name).folders", value: Double(update.foldersSearched), unit: "folders") }
                    }
                    if let first { recorder.add("\(name).first", value: first) }
                    recorder.add("\(name).matches", value: Double(matches), unit: "matches")
                }
            }
            if measuring {
                // How long a folder tap waits while a search is walking fairly large folders.
                let walk = Task { [profile] in
                    for try await update in RemoteFolderSearch.names(matching: "zzzqq", below: root + "/wide", profile: profile,
                                                                     service: warm, includeHidden: false, limits: limits) {
                        if update.isFinished { recorder.add("search.wide.folders", value: Double(update.foldersSearched), unit: "folders") }
                    }
                }
                let walkStarted = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(200))
                for _ in 0..<max(runs, 5) {
                    try await recorder.timeAsync("search.contended.list.10", runs: 1) {
                        blackHole(try await warm.listDirectory(profile: profile, path: root + "/d10").entries.count)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                _ = await walk.result
                recorder.add("search.wide.total", value: walkStarted.elapsedMilliseconds)
            }
        }
        // Asked for by name: it needs a server that runs the helper, and folders the script's tree doesn't have.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("assisted") == true {
            try await measureAssistedSearch(root: root, profile: profile, service: warm, recorder: recorder)
        }
        // By name: the two window policies strictly alternate, so link drift can't favour either.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("windowpairs") == true {
            let temp = folder.appendingPathComponent("pairs.bin"), file = root + "/big-64m.bin"
            let bytes = 64.0 * 1024 * 1024
            for pair in 0..<runs {
                for limit in pair % 2 == 0 ? [SFTPRemoteFileService.transferReadWindow, SFTPRemoteFileService.transferReadWindowLimit]
                                           : [SFTPRemoteFileService.transferReadWindowLimit, SFTPRemoteFileService.transferReadWindow] {
                    await warm.setTransferWindowLimit(limit)
                    let name = "windowpairs." + (limit == SFTPRemoteFileService.transferReadWindow ? "fixed16" : "growing")
                    let started = ContinuousClock.now
                    _ = try await warm.downloadManagedFile(profile: profile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) { _ in }
                    let elapsed = started.elapsedMilliseconds
                    recorder.add(name + ".ms", value: elapsed)
                    recorder.add(name + ".MiBps", value: bytes / (1024 * 1024) / (elapsed / 1000), unit: "MiB/s")
                    recorder.add("windowpairs.pair\(pair)." + (limit == SFTPRemoteFileService.transferReadWindow ? "fixed16" : "growing"), value: elapsed)
                }
            }
            await warm.setTransferWindowLimit(SFTPRemoteFileService.transferReadWindowLimit)
        }
        // Also by name, for the same reason as above.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("bulk") == true {
            try await measureBulkWork(root: root, profile: profile, service: warm, folder: folder, recorder: recorder)
        }
        if selected("read") {
            let readFiles = measuring ? [("read.50B", "report.md"), ("read.173KB", "large-report.md"), ("read.2MB", "big-2m.bin")] : [("read.50B", "report.md")]
            for (name, file) in readFiles {
                let path = root + "/" + file
                try await recorder.timeAsync(name, runs: runs) {
                    blackHole(try await warm.readFile(profile: profile, path: path, limit: 4 * 1024 * 1024).count)
                }
                try await recorder.timeAsync(name + ".confined", runs: runs) {
                    blackHole(try await warm.readDocumentFile(profile: profile, path: path, allowedRoot: root, limit: 4 * 1024 * 1024).count)
                }
            }
        }
        if measuring, selected("contended") {
            // How long browsing waits while a transfer shares its connection.
            let temp = folder.appendingPathComponent("background.bin")
            let file = root + "/big-64m.bin"
            let transfer = Task { [profile] in
                try await warm.downloadManagedFile(profile: profile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) { _ in }
            }
            try await Task.sleep(for: .milliseconds(500))
            try await recorder.timeAsync("contended.list.10", runs: runs) {
                blackHole(try await warm.listDirectory(profile: profile, path: root + "/d10").entries.count)
            }
            transfer.cancel()
            _ = await transfer.result
            _ = try await warm.listDirectory(profile: profile, path: root + "/d10")
        }
        if measuring, selected("download") {
            let temp = folder.appendingPathComponent("download.bin")
            let file = root + "/big-64m.bin"
            let bytes = 64.0 * 1024 * 1024
            try await recorder.timeAsync("download.64MiB.quiet", runs: runs) {
                _ = try await warm.downloadManagedFile(profile: profile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) { _ in }
            }
            recorder.deriveThroughput(from: "download.64MiB.quiet", bytes: bytes)
            // As DownloadManager does: every report reaches the main actor.
            let progress = MainActorBox()
            try await recorder.timeAsync("download.64MiB.mainactor", runs: runs) {
                _ = try await warm.downloadManagedFile(profile: profile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) { update in
                    await progress.record(update.receivedBytes)
                }
            }
            recorder.deriveThroughput(from: "download.64MiB.mainactor", bytes: bytes)
            recorder.add("download.64MiB.progressUpdates", value: Double(await progress.updates) / Double(max(1, runs)), unit: "updates")
            try await recorder.peakFootprint("download.64MiB.peakMB", runs: 1) {
                _ = try await warm.downloadManagedFile(profile: profile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) { _ in }
            }
        }
        recorder.flush()
    }

    /// Work that touches a whole folder tree: a saved index and an offline folder, with how long a folder tap
    /// takes meanwhile. `REMOTEFILES_BENCHMARK_BULK_ROOT` is the tree, of folders of small text files.
    private func measureBulkWork(root: String, profile: ConnectionProfile, service: SFTPRemoteFileService, folder: URL,
                                 recorder: BenchmarkRecorder) async throws {
        let tree = root + "/" + (environment["REMOTEFILES_BENCHMARK_BULK_ROOT"] ?? "docs")
        try await recorder.timeAsync("bulk.index", runs: runs) {
            var last = RemoteFolderSearch.Update()
            let snapshot = try await RemoteFolderSearch.buildIndex(below: tree, profile: profile, service: service, includeHidden: false,
                                                                   extraction: .init()) { last = $0 }
            recorder.add("bulk.index.documents", value: Double(snapshot.documents.count), unit: "documents")
            recorder.add("bulk.index.folders", value: Double(last.foldersSearched), unit: "folders")
        }
        // A tap while an index is being built.
        let building = Task { [profile] in
            try await RemoteFolderSearch.buildIndex(below: tree, profile: profile, service: service, includeHidden: false, extraction: .init())
        }
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<max(runs, 5) {
            try await recorder.timeAsync("bulk.index.tap", runs: 1) {
                blackHole(try await service.listDirectory(profile: profile, path: root + "/d10").entries.count)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        building.cancel()
        _ = await building.result
        guard environment["REMOTEFILES_BENCHMARK_BULK_INDEX_ONLY"] == nil else { return }
        try await recorder.timeAsync("bulk.offline", runs: runs) {
            let store = try OfflineFileStore(directory: folder.appendingPathComponent("offline-" + UUID().uuidString))
            let pin = try await store.pinFolder(profile: profile, path: tree, service: service)
            recorder.add("bulk.offline.files", value: Double(pin.fileIDs.count), unit: "files")
            try await store.removeFolder(pin.id)
        }
        // A tap in the middle of an offline folder.
        let background = Task { [profile] in
            let store = try OfflineFileStore(directory: folder.appendingPathComponent("offline-" + UUID().uuidString))
            return try await store.pinFolder(profile: profile, path: tree, service: service)
        }
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<max(runs, 5) {
            try await recorder.timeAsync("bulk.offline.tap", runs: 1) {
                blackHole(try await service.listDirectory(profile: profile, path: root + "/d10").entries.count)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        background.cancel()
        _ = await background.result
    }

    /// The Linux helper against the SFTP walk, over the same folders. Only a server that runs the helper
    /// measures it: `.helperRuns` says how many searches it answered, so a silent fallback is visible.
    /// A file-extension option of only spaces filters nothing, but differs from the default, so the app walks.
    private func measureAssistedSearch(root: String, profile: ConnectionProfile, service: SFTPRemoteFileService,
                                       recorder: BenchmarkRecorder) async throws {
        let walk = SearchQueryOptions(fileExtension: " ")
        let cases: [(name: String, folder: String, query: String, content: Bool)] = [
            ("tree", "tree", "needle", false), ("big", "big", "needle-report", false), ("big.many", "big", "needle", false),
            ("docs.rare", "docs", "needle", true), ("docs.common", "docs", "the", true)
        ]
        for item in cases {
            for (how, options) in [("helper", SearchQueryOptions()), ("walk", walk)] where environment["REMOTEFILES_BENCHMARK_ASSISTED_MODE"] ?? how == how {
                let name = "assisted.\(item.name).\(how)"
                let before = await service.metrics().serverSearchOperations
                try await recorder.timeAsync(name + ".total", runs: runs) {
                    #if os(macOS)
                    Self.runColdCommand(environment["REMOTEFILES_BENCHMARK_COLD_COMMAND"])
                    #endif
                    var first: Double?, matches = 0, folders = 0
                    let started = ContinuousClock.now
                    let updates = item.content
                        ? RemoteFolderSearch.contents(matching: item.query, below: root + "/" + item.folder, profile: profile, service: service,
                                                      includeHidden: false, options: options)
                        : RemoteFolderSearch.names(matching: item.query, below: root + "/" + item.folder, profile: profile, service: service,
                                                   includeHidden: false, options: options)
                    for try await update in updates {
                        let found = update.matches.count + update.contentMatches.count
                        if first == nil, found > 0 { first = started.elapsedMilliseconds }
                        matches += found
                        folders = max(folders, update.foldersSearched)
                    }
                    if let first { recorder.add(name + ".first", value: first) }
                    recorder.add(name + ".matches", value: Double(matches), unit: "matches")
                    recorder.add(name + ".folders", value: Double(folders), unit: "folders")
                }
                let helped = await service.metrics().serverSearchOperations - before
                recorder.add(name + ".helperRuns", value: Double(helped), unit: "runs")
            }
        }
    }

    #if os(macOS)
    /// Lets a run empty the server's caches before each sample. Benchmarks only, from its own environment.
    private static func runColdCommand(_ command: String?) {
        guard let command else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
        process.waitUntilExit()
    }
    #endif

    /// Without the script's tree, the few files the methods need when running once.
    private static func makeSmokeTree(in fixture: String) throws -> String {
        let root = URL(fileURLWithPath: fixture).appendingPathComponent("files/benchmark-smoke")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("d10"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("tree/below"), withIntermediateDirectories: true)
        for index in 0..<10 { manager.createFile(atPath: root.appendingPathComponent("d10/entry-\(index).txt").path, contents: nil) }
        manager.createFile(atPath: root.appendingPathComponent("tree/below/needle.txt").path, contents: nil)
        manager.createFile(atPath: root.appendingPathComponent("report.md").path, contents: Data("# Report\n".utf8))
        // Foundation's own resolving strips /private, which isn't this folder's canonical path.
        guard let canonical = realpath(root.path, nil) else { throw RemoteFileError.invalidPath }
        defer { free(canonical) }
        return String(cString: canonical)
    }

    // MARK: - The folder screen, hosted

    #if os(iOS)
    @MainActor func testFolderScreen() async throws {
        let recorder = BenchmarkRecorder(label: environment["REMOTEFILES_BENCHMARK_LABEL"] ?? "unlabelled")
        let sizes = (environment["REMOTEFILES_BENCHMARK_SCREEN_SIZES"] ?? (measuring ? "100,1000,10000,50000" : "100")).split(separator: ",").compactMap { Int($0) }
        for size in sizes {
            let service = BenchmarkFolderService(entries: BenchmarkData.entries(count: size))
            for _ in 0..<runs {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let model = try AppModel(directory: directory, fileService: service)
                let profile = ConnectionProfile(name: "Bench", host: "fixture.invalid", username: "bench", identityID: UUID(), startingDirectory: "/bench")
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first { $0.isKeyWindow }
                let window = UIWindow(windowScene: scene)
                let before = BenchmarkMemory.footprint()
                let started = ContinuousClock.now
                window.rootViewController = UIHostingController(rootView: NavigationStack {
                    FolderView(model: model, profile: profile, requestedPath: "/bench")
                })
                window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
                let frames = FrameSampler()
                frames.start()
                defer { frames.stop() }
                func list() -> UICollectionView? {
                    func find(_ view: UIView) -> UICollectionView? {
                        (view as? UICollectionView) ?? view.subviews.lazy.compactMap(find).first
                    }
                    return find(window)
                }
                let deadline = ContinuousClock.now + .seconds(120)
                while (list()?.visibleCells.isEmpty ?? true), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
                guard let collection = list(), !collection.visibleCells.isEmpty else { XCTFail("No rows appeared"); return }
                recorder.add("screen.firstRows.\(size)", value: started.elapsedMilliseconds)
                recorder.add("screen.displayMaxFPS", value: Double(UIScreen.main.maximumFramesPerSecond), unit: "fps")
                recorder.add("screen.firstRows.stall.\(size)", value: frames.longestGapMilliseconds)
                // Let loading settle, then scroll at a steady speed, a screen or so at a time.
                try await Task.sleep(for: .milliseconds(measuring ? 500 : 50))
                recorder.add("screen.memoryMB.\(size)", value: Double(BenchmarkMemory.footprint() - before) / 1_048_576, unit: "MB")
                frames.reset()
                let scrollEnd = ContinuousClock.now + (measuring ? .seconds(3) : .milliseconds(100))
                while ContinuousClock.now < scrollEnd {
                    let maxOffset = max(0, collection.contentSize.height - collection.bounds.height)
                    let next = collection.contentOffset.y + 32
                    collection.setContentOffset(CGPoint(x: 0, y: next > maxOffset ? 0 : next), animated: false)
                    try await Task.sleep(for: .milliseconds(8))
                }
                recorder.add("screen.scroll.hitches.\(size)", value: Double(frames.hitches), unit: "frames")
                recorder.add("screen.scroll.longestFrame.\(size)", value: frames.longestGapMilliseconds)
                recorder.add("screen.scroll.p95Frame.\(size)", value: frames.percentile(0.95))
                recorder.add("screen.scroll.medianFrame.\(size)", value: frames.percentile(0.5))
                recorder.add("screen.scroll.p99Frame.\(size)", value: frames.percentile(0.99))
                recorder.add("screen.scroll.missedShare.\(size)", value: frames.missedShare * 100, unit: "%")
            }
        }
        recorder.flush()
    }

    /// The folder screen while a large folder is still arriving: rows appear, then grow to the whole folder.
    @MainActor func testFolderScreenArriving() async throws {
        let recorder = BenchmarkRecorder(label: environment["REMOTEFILES_BENCHMARK_LABEL"] ?? "unlabelled")
        let sizes = (environment["REMOTEFILES_BENCHMARK_SCREEN_SIZES"] ?? (measuring ? "10000,50000" : "1000")).split(separator: ",").compactMap { Int($0) }
        for size in sizes {
            let service = BenchmarkArrivingFolderService(entries: BenchmarkData.entries(count: size))
            for _ in 0..<runs {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let model = try AppModel(directory: directory, fileService: service)
                let profile = ConnectionProfile(name: "Bench", host: "fixture.invalid", username: "bench", identityID: UUID(), startingDirectory: "/bench")
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first { $0.isKeyWindow }
                let window = UIWindow(windowScene: scene)
                let started = ContinuousClock.now
                window.rootViewController = UIHostingController(rootView: NavigationStack {
                    FolderView(model: model, profile: profile, requestedPath: "/bench")
                })
                window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
                let frames = FrameSampler()
                frames.start()
                defer { frames.stop() }
                func list() -> UICollectionView? {
                    func find(_ view: UIView) -> UICollectionView? {
                        (view as? UICollectionView) ?? view.subviews.lazy.compactMap(find).first
                    }
                    return find(window)
                }
                let deadline = ContinuousClock.now + .seconds(120)
                while (list()?.visibleCells.isEmpty ?? true), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
                recorder.add("arriving.firstRows.\(size)", value: started.elapsedMilliseconds)
                while model.cachedListing(profile.id, path: "/bench") == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
                recorder.add("arriving.complete.\(size)", value: started.elapsedMilliseconds)
                try await Task.sleep(for: .milliseconds(measuring ? 200 : 10))
                recorder.add("arriving.longestFrame.\(size)", value: frames.longestGapMilliseconds)
                recorder.add("arriving.hitches.\(size)", value: Double(frames.hitches), unit: "frames")
            }
        }
        recorder.flush()
    }
    #endif
}

// MARK: - Inputs

enum BenchmarkData {
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
    private static let words = ["report", "summary", "IMG", "notes", "backup", "index", "Final", "draft", "main", "config", "data", "résumé",
                                "東京", "café", "Übersicht", "log", "test", "archive", "photo", "invoice"]
    private static let suffixes = ["md", "txt", "JPG", "png", "swift", "py", "json", "log", "pdf", "mp4", "tar.gz", "html", "svg", "pem", "csv"]

    /// The same mixed folder each time: about a tenth folders, 2% links, 3% hidden, 15% with non-ASCII
    /// names, in the order a server's directory stream might give them.
    static func entries(count: Int, parent: String = "/bench") -> [RemoteEntry] {
        var generator = Generator(state: 0x5EED)
        return (0..<count).map { index in
            let word = words[Int(generator.next() % UInt64(words.count))]
            let roll = generator.next() % 100
            let hidden = generator.next() % 100 < 3 ? "." : ""
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(generator.next() % 94_000_000))
            if roll < 10 {
                let name = "\(hidden)\(word) folder \(index)"
                return RemoteEntry(name: name, path: parent + "/" + name, kind: .directory, modifiedAt: date)
            }
            let suffix = suffixes[Int(generator.next() % UInt64(suffixes.count))]
            let name = "\(hidden)\(word)-\(index).\(suffix)"
            if roll < 12 {
                let target = RemoteEntry(name: name, path: "/target/" + name, kind: .file, size: 1024, modifiedAt: date)
                return RemoteEntry(name: name, path: parent + "/" + name, kind: .symlink, modifiedAt: date, link: .target(target))
            }
            let size = UInt64(1) << (generator.next() % 34)
            return RemoteEntry(name: name, path: parent + "/" + name, kind: .file, size: size + generator.next() % size, modifiedAt: date)
        }
    }
}

/// Keeps the optimizer from removing the work being timed.
@inline(never) func blackHole(_ value: Int) { BenchmarkSink.value &+= value }
enum BenchmarkSink { nonisolated(unsafe) static var value = 0 }

enum BenchmarkMemory {
    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }
    /// User and system CPU this process has used, in milliseconds.
    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func milliseconds(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
        return milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime)
    }
    /// What the system counts against the app.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
    /// The most the system has ever counted against this process. The kernel keeps it, so nothing is
    /// missed between samples, but it never goes down: only the first large thing a process does can use it.
    static func lifetimePeakFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : 0
    }
}

extension ContinuousClock.Instant {
    var elapsedMilliseconds: Double {
        let elapsed = ContinuousClock.now - self
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}

final class BenchmarkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var samples: [String: (unit: String, values: [Double])] = [:]
    private var order: [String] = []
    private var failures: [String: String] = [:]
    init(label: String) { self.label = label }

    func add(_ scenario: String, value: Double, unit: String = "ms") {
        lock.lock(); defer { lock.unlock() }
        if samples[scenario] == nil { order.append(scenario); samples[scenario] = (unit, []) }
        samples[scenario]?.values.append(value)
    }
    func time(_ scenario: String, runs: Int, _ body: () throws -> Void) throws {
        for _ in 0..<runs {
            let started = ContinuousClock.now
            try body()
            add(scenario, value: started.elapsedMilliseconds)
        }
    }
    func timeAsync(_ scenario: String, runs: Int, tolerateFailure: Bool = false, _ body: () async throws -> Void) async throws {
        for _ in 0..<runs {
            let started = ContinuousClock.now
            do {
                try await body()
            } catch where tolerateFailure {
                lock.lock(); failures[scenario] = String(describing: error); lock.unlock()
            }
            add(scenario, value: started.elapsedMilliseconds)
        }
    }
    /// The most heap memory in use while `body` ran, above where it started, sampled every 5 ms. The
    /// footprint isn't used here because it hardly moves once earlier work has grown the allocator.
    func peakFootprint(_ scenario: String, runs: Int, _ body: () async throws -> Void) async throws {
        for _ in 0..<runs {
            let start = BenchmarkMemory.heapInUse()
            let sampler = Task.detached(priority: .high) { () -> Int in
                var peak = start
                while !Task.isCancelled {
                    peak = max(peak, BenchmarkMemory.heapInUse())
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return peak
            }
            try await body()
            sampler.cancel()
            add(scenario, value: Double(await sampler.value - start) / 1_048_576, unit: "MB")
        }
    }
    /// Heap bytes the result keeps alive, repeated because the allocator's numbers move a little.
    func retainedBytes<T>(_ scenario: String, runs: Int = 3, _ make: () -> T) throws {
        for _ in 0..<runs {
            let before = BenchmarkMemory.heapInUse()
            let value = make()
            let after = BenchmarkMemory.heapInUse()
            withExtendedLifetime(value) {}
            add(scenario, value: Double(after - before), unit: "bytes")
        }
    }
    func deriveThroughput(from scenario: String, bytes: Double) {
        lock.lock()
        let values = samples[scenario]?.values ?? []
        lock.unlock()
        for milliseconds in values { add(scenario + ".throughput", value: bytes / 1_048_576 / (milliseconds / 1000), unit: "MiB/s") }
    }
    func flush() {
        lock.lock(); defer { lock.unlock() }
        let output = ProcessInfo.processInfo.environment["REMOTEFILES_BENCHMARK_OUTPUT"]
        var lines = ""
        for scenario in order {
            guard let sample = samples[scenario] else { continue }
            var object: [String: Any] = ["label": label, "scenario": scenario, "unit": sample.unit, "samples": sample.values]
            if let failure = failures[scenario] { object["failure"] = failure }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { continue }
            print("BENCHJSON " + line)
            lines += line + "\n"
        }
        if let output, let handle = FileHandle(forWritingAtPath: output) ?? {
            FileManager.default.createFile(atPath: output, contents: nil)
            return FileHandle(forWritingAtPath: output)
        }() {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(lines.utf8))
            try? handle.close()
        }
    }
}

@MainActor private final class MainActorState { var received: UInt64 = 0; var updates = 0 }
private final class MainActorBox: @unchecked Sendable {
    @MainActor private lazy var state = MainActorState()
    @MainActor func record(_ received: UInt64) { state.received = received; state.updates += 1 }
    @MainActor var updates: Int { state.updates }
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

#if os(iOS)
private actor BenchmarkFolderService: RemoteFileService {
    private let entries: [RemoteEntry]
    init(entries: [RemoteEntry]) { self.entries = entries }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: entries) }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unavailable("Not used")
    }
    func disconnect() async {}
}

/// Delivers a folder a hundred entries at a time, as OpenSSH does, at a pace that takes a second or two.
private actor BenchmarkArrivingFolderService: RemoteFileService, ProgressiveFolderListing {
    private let entries: [RemoteEntry]
    init(entries: [RemoteEntry]) { self.entries = entries }
    func listDirectory(profile: ConnectionProfile, path: String) async throws -> DirectorySnapshot { .init(path: path, entries: entries) }
    func listDirectory(profile: ConnectionProfile, path: String,
                       partial: @escaping @Sendable (DirectorySnapshot) -> Void) async throws -> DirectorySnapshot {
        var delivered = 0
        while delivered < entries.count {
            delivered = min(entries.count, delivered + max(800, entries.count / 40))
            partial(.init(path: path, entries: Array(entries[..<delivered])))
            try await Task.sleep(for: .milliseconds(40))
        }
        return .init(path: path, entries: entries)
    }
    func resolveEntry(profile: ConnectionProfile, path: String) async throws -> RemoteEntry {
        .init(name: RemotePath.name(of: path), path: path, kind: .directory)
    }
    func readFile(profile: ConnectionProfile, path: String, limit: Int) async throws -> Data { Data() }
    func downloadFile(profile: ConnectionProfile, path: String, allowedRoot: String, destination: URL, limit: Int) async throws -> RemoteEntry {
        throw RemoteFileError.unavailable("Not used")
    }
    func disconnect() async {}
}

/// Records the gaps between display frames on the main run loop.
@MainActor private final class FrameSampler: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // An iPhone holds a display link to 60 Hz unless the app's Info.plist sets
        // CADisableMinimumFrameDurationOnPhone, which a benchmark build can add. See docs/PERFORMANCE.md.
        let requested = ProcessInfo.processInfo.environment["REMOTEFILES_BENCHMARK_FRAME_RATE"].flatMap { Float($0) }
        let fastest = min(requested ?? .infinity, Float(UIScreen.main.maximumFramesPerSecond))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fastest / 2, maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    func reset() { gaps.removeAll(); last = 0 }
    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { gaps.append((link.timestamp - last) * 1000) }
        last = link.timestamp
    }
    var longestGapMilliseconds: Double { gaps.max() ?? 0 }
    /// Frames that took at least one refresh longer than most did. At 120 Hz a 16.7 ms frame is one of
    /// these but not a hitch below, which looks for twice the usual.
    var missedShare: Double {
        let typical = percentile(0.5)
        return gaps.isEmpty ? 0 : Double(gaps.filter { $0 > typical * 1.5 }.count) / Double(gaps.count)
    }
    /// Frames that took more than twice as long as most frames did.
    var hitches: Int {
        let typical = percentile(0.5)
        return gaps.filter { $0 > typical * 2 + 1 }.count
    }
    func percentile(_ value: Double) -> Double {
        guard !gaps.isEmpty else { return 0 }
        let sorted = gaps.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * value))]
    }
}
#endif
