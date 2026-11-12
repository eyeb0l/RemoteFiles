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
    /// Reads a TCP stream to its end and returns its length: the link's speed with nothing above TCP.
    private static func readAll(host: String, port: Int, receiveBuffer: Int32? = nil) throws -> Int {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &found) == 0, let info = found else { throw POSIXError(.EHOSTUNREACH) }
        defer { freeaddrinfo(info) }
        // A sender that serves one connection at a time, such as a loop of `nc -l`, refuses briefly between them.
        var socket: Int32 = -1
        for attempt in 0..<100 {
            socket = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard socket >= 0 else { throw POSIXError(.EIO) }
            if var size = receiveBuffer {
                guard setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0 else { close(socket); throw POSIXError(.EINVAL) }
            }
            if connect(socket, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { break }
            let failure = errno
            close(socket); socket = -1
            guard failure == ECONNREFUSED, attempt < 99 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .ECONNREFUSED) }
            usleep(10_000)
        }
        defer { close(socket) }
        var buffer = [UInt8](repeating: 0, count: 1 << 16), total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            if count == 0 { return total }
            if count < 0 {
                // A reset sender must fail the sample, not record a short one as complete.
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            total += count
        }
    }

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
        // By name: the window policies take turns, in a rotating order, so link drift can't favour any.
        // Each records the largest window it reached, since growth that never happens compares nothing.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("windowpairs") == true {
            let temp = folder.appendingPathComponent("pairs.bin"), file = root + "/big-64m.bin"
            let bytes = 64.0 * 1024 * 1024
            let low = SFTPRemoteFileService.transferReadWindow, high = SFTPRemoteFileService.transferReadWindowLimit
            let arms = [("fixed\(low)", low, low), ("growing", low, high), ("fixed\(high)", high, high)]
            for pair in 0..<runs {
                for index in 0..<arms.count {
                    let (name, floor, limit) = arms[(index + pair) % arms.count]
                    await warm.setTransferWindow(floor: floor, limit: limit)
                    let started = ContinuousClock.now
                    _ = try await warm.downloadManagedFile(profile: profile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) { _ in }
                    let elapsed = started.elapsedMilliseconds
                    let metrics = await warm.metrics()
                    recorder.add("windowpairs.\(name).ms", value: elapsed)
                    recorder.add("windowpairs.\(name).MiBps", value: bytes / (1024 * 1024) / (elapsed / 1000), unit: "MiB/s")
                    recorder.add("windowpairs.\(name).peakWindow", value: Double(metrics.lastTransferPeakWindow), unit: "reads")
                    recorder.add("windowpairs.\(name).meanInFlight", value: metrics.lastTransferMeanInFlight, unit: "reads")
                    recorder.add("windowpairs.pair\(pair).\(name)", value: elapsed)
                }
            }
            await warm.setTransferWindow(floor: low, limit: high)
        }
        // By name: browsing during a download under each read-window policy, rotating in one process. Use with --mbit,
        // or a fast link finishes the file before the taps begin.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("windowtaps") == true {
            let temp = folder.appendingPathComponent("windowtaps.bin"), file = root + "/big-64m.bin"
            let low = SFTPRemoteFileService.transferReadWindow, high = SFTPRemoteFileService.transferReadWindowLimit
            let arms = [("fixed\(low)", low, low), ("growing", low, high), ("fixed\(high)", high, high), ("growing\(high * 2)", low, high * 2)]
            for pass in 0..<runs {
                for index in arms.indices {
                    let (name, floor, limit) = arms[(index + pass) % arms.count]
                    await warm.setTransferWindow(floor: floor, limit: limit)
                    let started = ContinuousClock.now
                    let transfer = Task { [profile] in
                        try await warm.downloadManagedFile(profile: profile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) { _ in }
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    for _ in 0..<5 {
                        try await recorder.timeAsync("windowtaps.\(name).tap", runs: 1) {
                            blackHole(try await warm.listDirectory(profile: profile, path: root + "/d10").entries.count)
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    _ = try await transfer.value
                    let elapsed = started.elapsedMilliseconds, metrics = await warm.metrics()
                    recorder.add("windowtaps.\(name).MiBps", value: 64 / (elapsed / 1000), unit: "MiB/s")
                    recorder.add("windowtaps.\(name).peakWindow", value: Double(metrics.lastTransferPeakWindow), unit: "reads")
                }
            }
            await warm.setTransferWindow(floor: low, limit: high)
        }
        // By name: whether a transfer should start at the read window the last one on its connection settled at.
        // Each arm downloads the file twice on one connection, `REMOTEFILES_BENCHMARK_CARRY_IDLE_MS` apart, with folder
        // taps during the second. `growing` is what ships. `carry` starts the second where the first settled, with the
        // usual start as its floor, and `carryhold` also keeps that window until it has been answered once. `stale64`
        // and `stale64hold` start the second at the limit whatever the first found, as a link that has slowed since
        // would; `fixed64` never changes. `REMOTEFILES_BENCHMARK_CARRY_ARMS` names the arms, which rotate by pass.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("windowcarry") == true {
            let temp = folder.appendingPathComponent("windowcarry.bin")
            let file = root + "/" + (environment["REMOTEFILES_BENCHMARK_CARRY_FILE"] ?? "big-64m.bin")
            let idle = Duration.milliseconds(Int(environment["REMOTEFILES_BENCHMARK_CARRY_IDLE_MS"] ?? "") ?? 0)
            let low = SFTPRemoteFileService.transferReadWindow, high = SFTPRemoteFileService.transferReadWindowLimit
            let arms = (environment["REMOTEFILES_BENCHMARK_CARRY_ARMS"] ?? "growing,carry,carryhold,fixed\(high)").split(separator: ",").map(String.init)
            await warm.setProgressInterval(.milliseconds(10))
            for pass in 0..<runs {
                for index in arms.indices {
                    let name = arms[(index + pass) % arms.count]
                    let fixed = name == "fixed\(high)", stale = name.hasPrefix("stale\(high)")
                    guard fixed || stale || name == "growing" || name.hasPrefix("carry") else { throw XCTSkip("No window arm called \(name)") }
                    let carry: TransferWindowCarry? = fixed || name == "growing" ? nil : .init(holdsFirstWindow: name.hasSuffix("hold"))
                    await warm.setTransferWindow(floor: fixed ? high : low, limit: high)
                    await warm.setTransferWindowCarry(carry)
                    for order in ["first", "second"] {
                        let second = order == "second"
                        if second {
                            try await Task.sleep(for: idle)
                            if stale { await warm.setTransferWindowCarry(carry, settled: high) }
                        }
                        let marks = BenchmarkTransferMarks(megabytes: [1, 4, 8, 32])
                        let transfer = Task { [profile] in
                            defer { marks.finish() }
                            return try await warm.downloadManagedFile(profile: profile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) {
                                marks.record($0.receivedBytes)
                            }
                        }
                        if second {
                            // As `windowtaps` begins, and then until the file is done: its first five taps compare with that.
                            try await Task.sleep(for: .milliseconds(500))
                            var taps = 0, worst = 0.0
                            while !marks.isFinished {
                                let tapped = ContinuousClock.now
                                blackHole(try await warm.listDirectory(profile: profile, path: root + "/d10").entries.count)
                                let waited = tapped.elapsedMilliseconds
                                taps += 1; worst = max(worst, waited)
                                if taps <= 5 { recorder.add("windowcarry.\(name).tap", value: waited) }
                                recorder.add("windowcarry.\(name).tapAll", value: waited)
                                try await Task.sleep(for: .milliseconds(100))
                            }
                            recorder.add("windowcarry.\(name).tapWorst", value: worst)
                        }
                        let size = Double(try await transfer.value.size ?? 0) / 1_048_576
                        let elapsed = marks.elapsed, metrics = await warm.metrics()
                        let scenario = "windowcarry.\(name).\(order)"
                        recorder.add("\(scenario).MiBps", value: size / (elapsed / 1000), unit: "MiB/s")
                        recorder.add("\(scenario).ms", value: elapsed)
                        for (megabytes, reached) in marks.reached { recorder.add("\(scenario).to\(megabytes)MiB", value: reached) }
                        recorder.add("\(scenario).startWindow", value: Double(metrics.lastTransferStartWindow), unit: "reads")
                        recorder.add("\(scenario).peakWindow", value: Double(metrics.lastTransferPeakWindow), unit: "reads")
                        recorder.add("\(scenario).settledWindow", value: Double(metrics.lastTransferSettledWindow), unit: "reads")
                        recorder.add("\(scenario).meanInFlight", value: metrics.lastTransferMeanInFlight, unit: "reads")
                    }
                }
            }
            await warm.setTransferWindow(floor: low, limit: high)
            await warm.setTransferWindowCarry(nil)
            await warm.setProgressInterval(.milliseconds(100))
        }
        // By name: live content searches over SFTP against a saved index of the same tree, whose listings all come
        // before its reads, so its reads overlap across folders. `tree` holds empty files; `texts` holds text, about
        // one file in six from its third level down holding "kestrel". Each search records its first match, total,
        // what it examined and the most it had in flight; then come folder taps during a search, and how soon a
        // cancelled one ends and browsing goes on. `REMOTEFILES_BENCHMARK_PIPELINE_ROOTS` narrows the trees.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("pipeline") == true {
            let walk = SearchQueryOptions(fileExtension: " ")
            let roots = (environment["REMOTEFILES_BENCHMARK_PIPELINE_ROOTS"] ?? environment["REMOTEFILES_BENCHMARK_PIPELINE_ROOT"] ?? "tree,texts")
                .split(separator: ",").map(String.init)
            let searches = roots.flatMap { tree in (tree == "texts" ? ["kestrel", "zzzqq"] : ["zzzqq"]).map { (tree, $0) } }
            // `REMOTEFILES_BENCHMARK_PIPELINE_LOOKAHEADS=8,16,64` rotates how far a live search lists ahead, in one process.
            let lookaheads = (environment["REMOTEFILES_BENCHMARK_PIPELINE_LOOKAHEADS"] ?? "").split(separator: ",").compactMap { Int($0) }
            let shipped = RemoteFolderSearch.liveLookahead
            defer { RemoteFolderSearch.liveLookahead = shipped }
            func contents(_ tree: String, _ query: String, lookahead: Int? = nil) async throws {
                let key = "pipeline.\(tree == "tree" ? "contents" : tree + "." + query)" + (lookahead.map { ".ahead\($0)" } ?? "")
                RemoteFolderSearch.liveLookahead = lookahead ?? shipped
                SearchPipelineMetrics.shared.reset()
                let started = ContinuousClock.now
                var last = RemoteFolderSearch.Update(), first: Double?, matches = 0
                try await recorder.peakFootprint(key + ".heapMB", runs: 1) {
                    for try await update in RemoteFolderSearch.contents(matching: query, below: root + "/" + tree, profile: profile, service: warm,
                                                                        includeHidden: false, options: walk) {
                        if first == nil, !update.contentMatches.isEmpty { first = started.elapsedMilliseconds }
                        matches += update.contentMatches.count; last = update
                    }
                }
                recorder.add(key + ".total", value: started.elapsedMilliseconds)
                if let first { recorder.add(key + ".first", value: first) }
                let peaks = SearchPipelineMetrics.shared.current
                for (name, value, unit) in [("matches", matches, "matches"), ("folders", last.foldersSearched, "folders"),
                                            ("files", last.filesSearched, "files"), ("readKB", last.bytesRead / 1024, "KB"),
                                            ("peakReads", peaks.reads, "reads"), ("peakReadKB", peaks.expectedBytes / 1024, "KB"),
                                            ("peakReservedKB", peaks.reservedBytes / 1024, "KB"), ("peakListings", peaks.listings, "listings"),
                                            ("peakFoldersAhead", peaks.foldersAhead, "folders")] {
                    recorder.add(key + "." + name, value: Double(value), unit: unit)
                }
            }
            for pass in 0..<runs {
                for (tree, query) in searches {
                    guard !lookaheads.isEmpty else { try await contents(tree, query); continue }
                    for offset in lookaheads.indices {
                        try await contents(tree, query, lookahead: lookaheads[(offset + pass) % lookaheads.count])
                    }
                }
                guard lookaheads.isEmpty else { continue }
                for tree in roots {
                    try await recorder.timeAsync("pipeline.\(tree == "tree" ? "" : tree + ".")index.total", runs: 1) {
                        var last = RemoteFolderSearch.Update()
                        let snapshot = try await RemoteFolderSearch.buildIndex(below: root + "/" + tree, profile: profile, service: warm, includeHidden: false,
                                                                               extraction: .init()) { last = $0 }
                        recorder.add("pipeline.\(tree == "tree" ? "" : tree + ".")index.documents", value: Double(snapshot.documents.count), unit: "documents")
                        recorder.add("pipeline.\(tree == "tree" ? "" : tree + ".")index.files", value: Double(last.filesSearched), unit: "files")
                    }
                }
            }
            // Unless `REMOTEFILES_BENCHMARK_PIPELINE_EXTRAS=0`.
            for (tree, query) in searches where environment["REMOTEFILES_BENCHMARK_PIPELINE_EXTRAS"] != "0" && lookaheads.isEmpty {
                let key = "pipeline.\(tree == "tree" ? "contents" : tree + "." + query)"
                let searching = Task { [profile] in
                    for try await _ in RemoteFolderSearch.contents(matching: query, below: root + "/" + tree, profile: profile, service: warm,
                                                                   includeHidden: false, options: walk) {}
                }
                try await Task.sleep(for: .milliseconds(300))
                for _ in 0..<5 {
                    try await recorder.timeAsync(key + ".tap", runs: 1) {
                        blackHole(try await warm.listDirectory(profile: profile, path: root + "/d10").entries.count)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                searching.cancel(); _ = await searching.result
                // Cancelling part way: how soon the stream ends, and how soon a folder opens afterwards.
                for _ in 0..<3 {
                    let running = Task { [profile] in
                        for try await _ in RemoteFolderSearch.contents(matching: query, below: root + "/" + tree, profile: profile, service: warm,
                                                                       includeHidden: false, options: walk) {}
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    let cancelled = ContinuousClock.now
                    running.cancel(); _ = await running.result
                    recorder.add(key + ".cancel", value: cancelled.elapsedMilliseconds)
                    try await recorder.timeAsync(key + ".tapAfterCancel", runs: 1) {
                        blackHole(try await warm.listDirectory(profile: profile, path: root + "/d10").entries.count)
                    }
                }
            }
        }
        // By name: the same link without SSH or SFTP. `REMOTEFILES_BENCHMARK_RAW_PORTS` lists ports on the server's
        // host that send the 64 MiB file over plain TCP; `REMOTEFILES_BENCHMARK_SFTP_PORTS` lists other ports of this
        // server, such as one without the proxy. Every arm takes its turn in a rotating order.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("linkbaseline") == true {
            func ports(_ key: String) -> [Int] { (environment[key] ?? "").split(separator: ",").compactMap { Int($0) } }
            var arms: [(String, () async throws -> Int)] = []
            // Each entry is a port on the server's host, or HOST:PORT for another sender, such as a second machine.
            // The two-stream arm reads its second stream from the next port, so a sender that serves one connection at a time works.
            for entry in (environment["REMOTEFILES_BENCHMARK_RAW_PORTS"] ?? "").split(separator: ",") {
                let parts = entry.split(separator: ":")
                guard let raw = parts.last.flatMap({ Int($0) }) else { continue }
                let sender = parts.count == 2 ? String(parts[0]) : host
                let name = "tcp" + (parts.count == 2 ? "-\(sender)-" : "") + "\(raw)"
                arms.append((name, { try await Task.detached { try Self.readAll(host: sender, port: raw) }.value }))
                // A receive buffer that limited one stream would let a larger one, or two streams, go faster.
                arms.append((name + ".rcvbuf8m", { try await Task.detached { try Self.readAll(host: sender, port: raw, receiveBuffer: 8 << 20) }.value }))
                arms.append((name + ".two", {
                    async let first = Task.detached { try Self.readAll(host: sender, port: raw) }.value
                    async let second = Task.detached { try Self.readAll(host: sender, port: raw + 1) }.value
                    return try await first + second
                }))
            }
            let temp = folder.appendingPathComponent("baseline.bin"), file = root + "/big-64m.bin"
            for other in [port] + ports("REMOTEFILES_BENCHMARK_SFTP_PORTS") {
                // The main port reuses the warmed profile: a new profile would open a new connection inside the first sample.
                let endpointProfile = other == port ? profile : ConnectionProfile(name: "Benchmark \(other)", host: host, port: other, username: user,
                                                                                  identityID: key.id, startingDirectory: root)
                let client = other == port ? warm : service()
                if other != port {
                    try await trust.trustUnknown(endpoint: HostEndpoint(host: host, port: other),
                                                 key: HostKeyDetails(publicKey: NIOSSHPublicKey(openSSHPublicKey: hostKey)))
                    value.connections.append(endpointProfile); try await metadata.save(value)
                    _ = try await client.listDirectory(profile: endpointProfile, path: root + "/d10")
                    addTeardownBlock { await client.disconnect() }
                }
                arms.append(("sftp\(other)", {
                    let entry = try await client.downloadManagedFile(profile: endpointProfile, path: file, allowedRoot: root, destination: temp, limit: 1 << 30) { _ in }
                    return Int(entry.size ?? 0)
                }))
            }
            for pass in 0..<runs {
                for index in 0..<arms.count {
                    let (name, arm) = arms[(index + pass) % arms.count]
                    let started = ContinuousClock.now
                    let bytes = try await arm()
                    let elapsed = started.elapsedMilliseconds
                    recorder.add("linkbaseline.\(name).MiBps", value: Double(bytes) / (1024 * 1024) / (elapsed / 1000), unit: "MiB/s")
                    recorder.add("linkbaseline.pass\(pass).\(name)", value: elapsed)
                }
            }
        }
        // Also by name, for the same reason as above.
        if measuring, environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("bulk") == true {
            try await measureBulkWork(root: root, profile: profile, service: warm, folder: folder, recorder: recorder)
        }
        // By name as well: several trees, latencies and arms make it the longest scenario. Once, small, otherwise.
        if measuring ? environment["REMOTEFILES_BENCHMARK_ONLY"]?.contains("offline") == true : selected("offline") {
            try await measureOfflineFolders(root: root, profile: profile, service: warm, folder: folder, recorder: recorder)
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

    /// Saving folders offline, from the script's `offline` trees. Each sample records the whole save, when
    /// its first file was done, channels opened and the heap's peak; then come folder taps during a save, and
    /// how soon a cancelled or interrupted save gives its slot back. `REMOTEFILES_BENCHMARK_OFFLINE_TREES`
    /// narrows the trees, and `REMOTEFILES_BENCHMARK_OFFLINE_ARMS` names transfer policies that take turns
    /// in a rotating order (`OfflineBenchmarkArm`). Without the script's trees it saves the smoke tree once.
    private func measureOfflineFolders(root: String, profile: ConnectionProfile, service: SFTPRemoteFileService, folder: URL,
                                       recorder: BenchmarkRecorder) async throws {
        let trees = measuring ? (environment["REMOTEFILES_BENCHMARK_OFFLINE_TREES"] ?? "small50,tiny400,mixed").split(separator: ",").map(String.init) : ["smoke"]
        let arms = (environment["REMOTEFILES_BENCHMARK_OFFLINE_ARMS"] ?? "current").split(separator: ",").map(String.init)
        for name in trees {
            let tree = name == "smoke" ? root + "/tree" : root + "/offline/" + name
            // `REMOTEFILES_BENCHMARK_OFFLINE_SAVES=0` keeps only the extras below.
            for pass in 0..<(environment["REMOTEFILES_BENCHMARK_OFFLINE_SAVES"] == "0" ? 0 : runs) {
                for index in arms.indices {
                    let arm = arms[(index + pass) % arms.count]
                    try OfflineBenchmarkArm.apply(arm)
                    let key = "offline.\(name).\(arm)"
                    let channels = await service.metrics().sftpChannels
                    let counter = OfflineProgressCounter()
                    var saved = (files: 0, bytes: 0)
                    OfflineListingMetrics.shared.reset()
                    try await recorder.peakFootprint(key + ".heapMB", runs: 1) {
                        let started = ContinuousClock.now
                        saved = try await Self.saveOffline(tree: tree, profile: profile, service: service, folder: folder, counter: counter)
                        let elapsed = started.elapsedMilliseconds
                        recorder.add(key + ".total", value: elapsed)
                        recorder.add(key + ".MiBps", value: Double(saved.bytes) / 1_048_576 / (elapsed / 1000), unit: "MiB/s")
                        recorder.add(key + ".pass\(pass)", value: elapsed)
                    }
                    if let first = counter.firstFile { recorder.add(key + ".first", value: first) }
                    recorder.add(key + ".files", value: Double(saved.files), unit: "files")
                    recorder.add(key + ".progressUpdates", value: Double(counter.updates), unit: "updates")
                    let metrics = await service.metrics()
                    recorder.add(key + ".channels", value: Double(metrics.sftpChannels - channels), unit: "channels")
                    recorder.add(key + ".peakFiles", value: Double(metrics.lastBatchPeakFiles), unit: "files")
                    recorder.add(key + ".peakInFlightMiB", value: Double(metrics.lastBatchPeakBytes) / 1_048_576, unit: "MiB")
                    // Time the save spent waiting for its listings, with nothing else able to start meanwhile.
                    let listing = OfflineListingMetrics.shared.last
                    recorder.add(key + ".listingWait", value: Double(listing.waited.components.seconds) * 1000
                                 + Double(listing.waited.components.attoseconds) / 1e15)
                    recorder.add(key + ".listings", value: Double(listing.listings), unit: "listings")
                    recorder.add(key + ".peakListings", value: Double(listing.mostAtOnce), unit: "listings")
                }
            }
            // Taps, cancellation and interruption, unless `REMOTEFILES_BENCHMARK_OFFLINE_EXTRAS=0`.
            guard measuring, environment["REMOTEFILES_BENCHMARK_OFFLINE_EXTRAS"] != "0" else { continue }
            for arm in arms {
                try OfflineBenchmarkArm.apply(arm)
                let key = "offline.\(name).\(arm)"
                // Folder taps while a save runs, on the connection it shares.
                let background = Task { [profile] in
                    try await Self.saveOffline(tree: tree, profile: profile, service: service, folder: folder, counter: OfflineProgressCounter())
                }
                try await Task.sleep(for: .milliseconds(200))
                for _ in 0..<max(runs, 5) {
                    try await recorder.timeAsync(key + ".tap", runs: 1) {
                        blackHole(try await service.listDirectory(profile: profile, path: root + "/d10").entries.count)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                _ = await background.result
                // A cancelled save, once its first file is done: until it returns, and until its slot is free.
                for (outcome, stop) in [("cancel", false), ("interrupt", true)] {
                    for _ in 0..<runs {
                        let counter = OfflineProgressCounter()
                        let store = try OfflineFileStore(directory: folder.appendingPathComponent("offline-" + UUID().uuidString))
                        let id = UUID()
                        let saving = Task { [profile] in try await Self.saveOffline(tree: tree, profile: profile, service: service, store: store,
                                                                                    operationID: id, counter: counter) }
                        while counter.firstFile == nil, !counter.finished { try await Task.sleep(for: .milliseconds(2)) }
                        let started = ContinuousClock.now, connections = await service.metrics().connections
                        if stop { await service.closeSessionPreservingUnlockedIdentities() } else { saving.cancel() }
                        let result = await saving.result
                        recorder.add("\(key).\(outcome).returned", value: started.elapsedMilliseconds)
                        await store.waitForCancelledTransfer(id)
                        recorder.add("\(key).\(outcome).drained", value: started.elapsedMilliseconds)
                        if case .success = result { recorder.add("\(key).\(outcome).finishedFirst", value: 1, unit: "saves") }
                        // The next save may connect again: whether it had to says what the stop closed.
                        _ = try await service.listDirectory(profile: profile, path: root + "/d10")
                        recorder.add("\(key).\(outcome).reconnected", value: Double(await service.metrics().connections - connections), unit: "connections")
                    }
                }
            }
        }
        try OfflineBenchmarkArm.apply("current")
    }

    /// Saves one folder. The library holds at most 100 files, so a larger tree goes through `OfflineFolderDownload`
    /// directly with the store's other limits: the same transfers, without the final move into the library.
    private static func saveOffline(tree: String, profile: ConnectionProfile, service: SFTPRemoteFileService, folder: URL? = nil,
                                    store given: OfflineFileStore? = nil, operationID: UUID = UUID(),
                                    counter: OfflineProgressCounter) async throws -> (files: Int, bytes: Int) {
        defer { counter.finish() }
        let canonical = try await service.listDirectory(profile: profile, path: tree).path
        if tree.hasSuffix("/tiny400"), given == nil, let folder {
            let worker = OfflineFolderDownload(directory: folder.appendingPathComponent("direct-" + UUID().uuidString), profile: profile,
                path: canonical, includeHidden: false, service: service, oldFiles: [], fileLimit: OfflineFileStore.maximumFileBytes,
                byteLimit: OfflineFileStore.maximumStoredBytes, countLimit: 1_000, limits: .init()) { counter.record($0) }
            do {
                let prepared = try await worker.prepare()
                await worker.cleanup()
                return (prepared.files.count, prepared.files.reduce(0) { $0 + $1.byteCount })
            } catch {
                await worker.cancelAndDrain(); throw error
            }
        }
        let store = try given ?? OfflineFileStore(directory: folder!.appendingPathComponent("offline-" + UUID().uuidString))
        let pin = try await store.pinFolder(profile: profile, path: canonical, service: service, operationID: operationID) { counter.record($0) }
        let bytes = await store.snapshot().filter { pin.fileIDs.contains($0.id) }.reduce(0) { $0 + $1.byteCount }
        try await store.removeFolder(pin.id)
        return (pin.fileIDs.count, bytes)
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

/// When an offline save first reported a finished file, and how many reports it made.
private final class OfflineProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ContinuousClock.now
    private var first: Double?, count = 0, done = false
    var firstFile: Double? { lock.lock(); defer { lock.unlock() }; return first }
    var updates: Int { lock.lock(); defer { lock.unlock() }; return count }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func record(_ progress: OfflineFolderProgress) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if first == nil, progress.files > 0 { first = started.elapsedMilliseconds }
    }
    func finish() { lock.lock(); done = true; lock.unlock() }
}

/// Offline transfer policies a benchmark can switch between in one process: `current` as shipped, or a
/// channel per file (`dedicated`) or one shared channel (`shared`), followed by how many files run at once.
enum OfflineBenchmarkArm {
    static func apply(_ name: String) throws {
        if name == "current" {
            OfflineFolderDownload.sharesChannel = true; OfflineFolderDownload.concurrentFiles = 16; OfflineFolderDownload.listingsAhead = 4
            return
        }
        // Folders listed ahead of the walk, with files as shipped.
        if name.hasPrefix("ahead"), let count = Int(name.dropFirst(5)), count >= 0 {
            OfflineFolderDownload.sharesChannel = true; OfflineFolderDownload.concurrentFiles = 16; OfflineFolderDownload.listingsAhead = count
            return
        }
        for (prefix, shares) in [("dedicated", false), ("shared", true)] where name.hasPrefix(prefix) {
            guard let count = Int(name.dropFirst(prefix.count)), count > 0 else { break }
            OfflineFolderDownload.sharesChannel = shares; OfflineFolderDownload.concurrentFiles = count
            return
        }
        throw XCTSkip("No offline arm called \(name)")
    }
}

/// When a transfer had received each of a few amounts, in milliseconds from its start, and whether it has ended.
private final class BenchmarkTransferMarks: @unchecked Sendable {
    let started = ContinuousClock.now
    private let lock = NSLock()
    private var pending: [Int], times: [(Int, Double)] = [], finished: Double?
    init(megabytes: [Int]) { pending = megabytes.sorted() }
    var reached: [(Int, Double)] { lock.withLock { times } }
    var isFinished: Bool { lock.withLock { finished != nil } }
    /// The transfer's own time: whoever waits for it may be busy with a folder tap when it ends.
    var elapsed: Double { lock.withLock { finished } ?? started.elapsedMilliseconds }
    func finish() { let now = started.elapsedMilliseconds; lock.withLock { finished = now } }
    func record(_ received: UInt64) {
        let now = started.elapsedMilliseconds
        lock.withLock {
            while let next = pending.first, received >= UInt64(next) << 20 { times.append((next, now)); pending.removeFirst() }
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
