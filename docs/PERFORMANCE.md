# Performance

[Documentation](README.md) · [Build and test](DEVELOPMENT.md)

What limits each operation, what was measured on 7 November 2026, and how to benchmark a change. Measured on iPhone means a physical iPhone 17 Pro; measured on Mac means the same code on a Mac, which says little about absolute speed on a phone. Raw samples are in [`performance/2026-11-07`](performance/2026-11-07).

## What limits what

| Operation | Limited by | Evidence |
|---|---|---|
| Recursive search, without the Linux helper | Round trips | 330 ms with no added latency, 12.8 s at 40 ms, on the same 364 folders (Mac) |
| Opening a file or small folder | Round trips | 3.5 to 10 round trips each before this work |
| Opening a very large folder (first frame) | SwiftUI on the main thread | 2.6 s stall at 50,000 rows (iPhone); none of it in sorting, the network or layout of the data |
| Listing 10,000 names on OpenSSH | The server | 850 ms, of which about 18 ms is client CPU (Mac) or 80 ms (iPhone). `sftp-server` looks up the owner and group of every entry |
| Preparing rows | Formatting, then sorting | 127 ms per 10,000 rows on iPhone, over half of it formatting sizes and dates no one was looking at |
| Downloads over a fast, distant link | The read window | At most 16 × 64 KiB per round trip |
| Downloads over this phone's Wi-Fi and Tailscale | The link | 5 to 12 MiB/s, varying by a factor of two between passes |
| Scrolling | Nothing measured | 0 to 1 hitches and a 16.67 ms 95th-percentile frame up to 50,000 rows, before and after, at the 60 Hz the test ran at (iPhone) |

Memory layout was not the limit on anything a person waits for, except sorting by date, size and kind. It's the one place a data-layout change made a large difference.

## What changed, and why

Each entry names the bottleneck, the evidence and the cost accepted.

**One shape for every folder row.** A condition at the top of a List row, including the one inside `WorkspaceLink`, made SwiftUI build every row to count them. The rows are now one `Button` with a varying action, chevron and menu. Measured directly, at 20,000 rows on iPhone: one shape 25 ms, `if`/`else` 175 ms, `WorkspaceLink` 548 ms. A custom view struct around the condition did not help (736 ms); neither did the row content, identifier type or context menu matter. *Cost:* rows push programmatically, so the row highlight doesn't linger through the push, and the chevron is drawn by the app. `FolderView.swift` says why, so the condition doesn't return.

**Fewer round trips.** Requests that can be answered together are sent together and judged afterwards in the order that makes them safe: root confinement still comes before a version match. Listings and reads return without waiting for `CLOSE`; a failed close still retires the channel. A known size ends reads exactly at the end of the file. Directory reads top up from half a window, because every read outstanding at EOF must be drained. *Cost:* five small additions to vendored Citadel ([provenance](../Vendor/Citadel/UPSTREAM.md)), and a failed close is no longer reported as the read's failure, only by retiring the channel. Reads still wait for the post-`OPEN` boundary recheck before any bytes move.

**Rows while a folder arrives.** With nothing on screen, rows appear 100 ms after the first batch if the rest hasn't come, and again each time they grow by half. Links resolve afterwards. The listing limit rose from 10,000 to 250,000 entries, and its deadline now extends while replies keep arriving. *Cost:* partial rows can move while **Updating…** shows. A folder already on screen is unaffected. On iPhone at 50,000 entries the updates cost 2 frames over 57 ms, against a single 2.6 s stall before.

**Search.** Walks list 8 to 64 folders at once, paced by how quickly the server answers. They skip link resolution except for matches and use their own SFTP channel, which prefetch now shares instead of opening one per folder. The screen refreshes at most ten times a second. *Cost:* a second idle `sftp-server` per session once used, and if a server stalls, more listings time out together. A sweep at a fixed 40 ms took 12.7 s at 4 folders, 6.5 s at 8, 3.4 s at 16, 1.9 s at 32 and 1.3 s at 64.

**Data layout, by candidate.** Benchmarked on iPhone at 10,000 and 100,000 rows; [the experiment](performance/2026-11-07/FolderLayoutExperimentTests.swift.txt) checks each candidate's output against the current code.

| Step | Candidates (ms, 10,000 / 100,000 rows) | Chosen |
|---|---|---|
| Sort by name | Current 46 / 778. Keys with `String` 27 / 416. Keys with `NSString` and locale 84 / 1,190. Keys with `CFString` **17 / 255** | `CFString` keys. Reverse if `testNameOrderMatchesTheDefinition` ever fails: the flags restate what `localizedStandardCompare` does |
| Sort by date | Current 26 / 385. Keys, ties by position **1.2 / 17** | Keys. Rows are already in name order, so no name is compared again. Size and kind follow |
| Filter | Foundation 10.7 / 127. Per-row byte check **2.9 / 32**. One lowercase buffer, `memmem` and an offset table 2.7 / 28, plus 0.7 / 8 to build | Per-row check: the buffer ties, because the 15% of names that aren't ASCII still go to Foundation, and it costs memory and upkeep |
| Row storage | `RemoteEntry` 160 bytes, fields read by every row and by almost none together. Hot/cold, 72 bytes with one reference | Hot/cold, with formatted strings no longer stored and the hidden-free case sharing a buffer. An AoS of small structs is what SwiftUI needs, so SoA wasn't pursued |

Foundation still decides every name the byte check can't rule out, so results don't change. *Cost:* row descriptions are worked out on demand at about 8 µs each, only for rows shown.

**Transfers.** The read window starts at 16 and grows to 64 towards 1.5 × what the link delivers per round trip, using the shortest latency seen so queueing doesn't inflate it. Progress reaches the main actor at most ten times a second. *Cost:* up to 4 MiB in flight and an 8 MiB SSH receive window. Browsing during a transfer did not suffer, at any tested speed.

## Results

Medians; IQRs and 95th percentiles are in the raw files. Before is `616a7a3` with the harness added; after is this change. Builds were interleaved, because run order has misled comparisons here before.

### iPhone 17 Pro, iOS 27.2, no network

Release with testability enabled, two interleaved passes of five runs.

| Measure | Rows | Before | After | Change |
|---|---:|---:|---:|---:|
| First rows on screen | 1,000 | 135 ms | 109 ms | −19% |
| | 10,000 | 542 ms | 126 ms | −77% |
| | 50,000 | 3,850 ms | 215 ms | −94% |
| Longest main-thread stall meanwhile | 10,000 | 351 ms | 53 ms | −85% |
| | 50,000 | 2,627 ms | 17 ms | −99% |
| Memory taken by the screen, worst run | 10,000 | 149 MB | under 1 MB | |
| | 50,000 | 677 MB | 10 MB | |
| Preparing rows | 10,000 | 127 ms | 19 ms | −85% |
| | 100,000 | 1,326 ms | 244 ms | −82% |
| Row array storage, without name and path strings | 100,000 | 95 MB | 14 MB | −85% |
| Filter, no matches | 10,000 | 12.9 ms | 2.8 ms | −78% |
| | 100,000 | 137 ms | 30 ms | −78% |
| Sort by date | 100,000 | 421 ms | 18 ms | −96% |
| Sort by kind | 100,000 | 1,684 ms | 34 ms | −98% |

The memory cases are the first run of each size, since later runs reuse what the first left behind; the before figures are from that same pattern.

### iPhone 17 Pro over Wi-Fi to OpenSSH on a Mac

Through Tailscale on a direct LAN path, about 7 ms but often worse, with nothing added and with 40 ms added. Two interleaved passes of three runs.

| Measure | Added | Before | After | Change |
|---|---:|---:|---:|---:|
| Open a 10-entry folder | 0 | 42 ms | 31 ms | −26% |
| | 40 ms | 167 ms | 114 ms | −32% |
| First rows, 9,900 entries | 0 | 1,071 ms | 150 ms | −86% |
| | 40 ms | 1,208 ms | 256 ms | −79% |
| List a folder of 256 links | 0 | 305 ms | 161 ms | −47% |
| | 40 ms | 1,081 ms | 313 ms | −71% |
| Read a 50 B file | 0 | 45 ms | 25 ms | −44% |
| | 40 ms | 263 ms | 112 ms | −58% |
| Read a file by document link | 0 | 86 ms | 35 ms | −59% |
| | 40 ms | 482 ms | 221 ms | −54% |
| Search 364 folders | 0 | 3.7 s | 0.79 s | −79% |
| | 40 ms | 15.7 s | 1.25 s | −92% |
| Search 1,000 larger folders | 0 | 13.4 s | 5.6 s | −58% |
| | 40 ms | stopped at 648 folders, 30 s | all 1,000, 5.2 s | |
| Open a folder during that search | 0 | 245 ms | 31 ms | −88% |
| | 40 ms | 392 ms | 111 ms | −72% |
| Prefetch six folders | 0 | 458 ms | 185 ms | −60% |
| | 40 ms | 2,294 ms | 712 ms | −69% |
| Connect and list | 0 | 165 ms | 147 ms | −11% |
| | 40 ms | 607 ms | 537 ms | −11% |
| Download 64 MiB, 6 alternating pairs | 0 | 6.1 MiB/s | 6.2 MiB/s | **no measurable change** |

Downloads: the link limits them here, and pairs ranged from 0.65 to 1.41 times the baseline. An earlier, less tightly paired run suggested a 22% loss at no added latency and a 40% gain at 40 ms; those differences were within what the link did between passes, so neither is claimed. Listing 1,000 entries showed +13% at no added latency while opening the same folder showed −26%: that one is noise too.

### Mac mini (M2, 8 GB), macOS 27.2, loopback OpenSSH through a delaying proxy

This is where a link fast enough to show the read window exists. The proxy models fixed delay and an optional rate, with no loss or jitter, so use it to compare revisions and not to predict field results.

| Measure | Condition | Before | After | Change |
|---|---|---:|---:|---:|
| Download 64 MiB | 5 ms | 108 MiB/s | 231 MiB/s | +114% |
| | 40 ms | 18 MiB/s | 45 MiB/s | +153% |
| | 150 ms | 5.3 MiB/s | 14 MiB/s | +171% |
| | 40 ms, 100 Mbit/s | 10.7 MiB/s | 11.0 MiB/s | +3% |
| | 150 ms, 100 Mbit/s | 5.3 MiB/s | 9.1 MiB/s | +74% |
| Progress updates, 64 MiB | 40 ms | 1,026 | 10 | |
| Open a folder during a download | 40 ms, 100 Mbit/s | 247 ms | 167 ms | −32% |
| | 150 ms, 100 Mbit/s | 471 ms | 331 ms | −30% |
| Read 2 MB | 40 ms | 365 ms | 96 ms | −74% |
| Search 364 folders | 5 ms | 1.86 s | 0.36 s | −80% |
| | 40 ms | 12.8 s | 0.91 s | −93% |
| | 150 ms | stopped at 252 folders, 30 s | all 364, 3.2 s | |
| List 100,000 entries | none | failed, over the limit | 12-20 s, 100,000 entries | server-bound |
| Search 1,000 larger folders | none | 3.4-3.6 s | 3.6-3.9 s | 0 to +15% |
| Download 64 MiB | none | 490-530 MiB/s | 320-390 MiB/s | −21 to −40%, noisy |

The last two rows got worse with no latency at all, a condition no phone has; by 5 ms both have turned into large gains.

## Correctness

- Fast paths are tested against the code they replace: name order, every sort and every filter option over awkward Unicode, numeric, width and case names, plus random printable text (`FolderListingTests`). Equality and hashing survive the hot/cold split (`RemoteEntryLayoutTests`).
- 279 macOS core tests pass with OpenSSH, including new ones for handles closing after 340 reads without waiting for replies, partial rows, search on its own channel, deadline extension and short and wrong size hints.
- `ResponsivenessTests`, `FolderListingTests`, `RemoteEntryLayoutTests` and `PerformanceBenchmarkTests` pass hosted on the iOS simulator, 32 tests. A 100,000-entry listing returned exactly 100,000 entries.
- Eight UI journeys touching folder rows pass on the iPhone simulator. The keyboard journey failed once on its Home screen under load average 27, before reaching a folder, and passed when rerun.

Not run: the whole UI inventory, VoiceOver and the Linux server helper. The rows' structure changed, so a pull request should carry `full-acceptance`.

## Remaining opportunities

Theoretical until measured, most promising first.

1. **The Linux helper's setup.** On a server with SSH command access, a search first makes about 10 + 2 per descriptor sequential requests, then returns everything at once. Pipelining them and streaming results would help first results most. No Linux server was available here to test on.
2. **Time to open a connection.** Six to eight round trips, unchanged by this work, and the largest remaining part of a cold open. Sending the SFTP subsystem request and `INIT` together would save one, but no server beyond OpenSSH could be tested, so it was left out.
3. **Offline folder downloads and saved indexes** still use one listing channel and the foreground path. They could use the walk.
4. **Faster links on a phone.** The read window's benefit is measured only through the proxy. Repeat the download comparison over a path faster than this Tailscale one.
5. **120 Hz.** The hosted test ran at 60 Hz, so frame results can't show anything finer than 16.67 ms.
6. **Peak memory while listing.** The heap sampler here is too coarse to report; Instruments would settle it. Longnames and attributes are now released batch by batch.

## Run it

```sh
# Local work and transport, on one checkout. Build first, or use --skip-build.
python3 -B scripts/benchmark_performance.py run --output after.jsonl --label after --rtt 0,5,40,150 --huge

# Compare two recorded files.
python3 -B scripts/benchmark_performance.py compare before.jsonl after.jsonl
```

To compare fairly, `git worktree add` the baseline, build both, and alternate `run --skip-build --checkout PATH` between them. `--only download,search` narrows the scenarios, `--mbit 100` caps the rate.

On a phone, build with a separate bundle ID so the installed app is left alone: copy the checkout, replace `dev.iris.RemoteFiles` with `dev.iris.RemoteFilesBench` in its `project.pbxproj`, then:

```sh
xcodebuild build-for-testing -project RemoteFiles.xcodeproj -scheme RemoteFilesCoreCI -configuration Release \
  -destination 'id=DEVICE' -derivedDataPath DD -allowProvisioningUpdates ENABLE_TESTABILITY=YES

# Folder screen and local work, no network.
TEST_RUNNER_REMOTEFILES_BENCHMARK=1 xcodebuild test-without-building -xctestrun DD/Build/Products/*.xctestrun -destination 'id=DEVICE' \
  -only-testing:RemoteFilesTests/PerformanceBenchmarkTests/testFolderScreen -only-testing:RemoteFilesTests/PerformanceBenchmarkTests/testLocalWork

# Transport. The address must be one the phone can reach: this Mac's Tailscale address worked where its LAN address was filtered.
python3 -B scripts/benchmark_performance.py device --output phone.jsonl --label after --xctestrun DD/Build/Products/*.xctestrun \
  --udid DEVICE --address MAC_ADDRESS --rtt 0,40
```

Keep the phone unlocked and allow Local Network on first run. Links vary, so alternate short runs and compare pairs, as for downloads above. Remove the app afterwards with `xcrun devicectl device uninstall app`.

Nothing in the harness fails on a timing, because shared machines are too noisy for that. `PerformanceBenchmarkTests` runs once in CI at its smallest size, so it can't rot without anyone noticing. To catch a regression, compare against a kept baseline when changing listing, search, reads, rows or transfers.
