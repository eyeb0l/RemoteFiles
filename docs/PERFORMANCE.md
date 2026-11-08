# Performance

[Documentation](README.md) · [Build and test](DEVELOPMENT.md)

What limits each operation, what was measured on 7 November 2026, and how to benchmark a change. Measured on iPhone means a physical iPhone 17 Pro; measured on Mac means the same code on a Mac, which says little about absolute speed on a phone. Raw samples are in [`performance/2026-11-07`](performance/2026-11-07), for the [follow-ups](#follow-ups-7-november) in [`performance/2026-11-07-followups`](performance/2026-11-07-followups), and for [the phone's download cap](#the-phones-download-cap-not-the-client) in [`performance/2026-11-07-download-cap`](performance/2026-11-07-download-cap).

## What limits what

| Operation | Limited by | Evidence |
|---|---|---|
| Recursive search, without the Linux helper | Round trips | 330 ms with no added latency, 12.8 s at 40 ms, on the same 364 folders (Mac) |
| Recursive search with the Linux helper | Round trips to set it up, then the server's disk | About 9 round trips before the first line, from about 35. On a cold, slow disk the server's reads take the rest (Mac) |
| Contents search over SFTP and saved indexes | Round trips per file | About 4.4 each; reads now overlap, up to 32 at a time |
| Offline folders | Round trips per file | About 10.7 each, mostly the file's own channel. Listing is under 6% (Mac) |
| Opening a connection | The protocol | 9 round trips at 40 ms to the first rows, all but one fixed by SSH, the server or SFTP. [The ledger](#connection-setup) |
| Opening a file or small folder | Round trips | 3.5 to 10 round trips each before this work |
| Opening a very large folder (first frame) | SwiftUI on the main thread | 2.6 s stall at 50,000 rows (iPhone); none of it in sorting, the network or layout of the data |
| Listing 10,000 names on OpenSSH | The server | 850 ms, of which about 18 ms is client CPU (Mac) or 80 ms (iPhone). `sftp-server` looks up the owner and group of every entry |
| Preparing rows | Formatting, then sorting | 127 ms per 10,000 rows on iPhone, over half of it formatting sizes and dates no one was looking at |
| Downloads over a fast, distant link | The read window | Fixed at 16 reads, at most 1 MiB per round trip. On iPhone from a wired Mac at 150 ms added, 5.3 MiB/s fixed at 16, 11.9 growing, 14.3 fixed at 64 |
| Downloads from the MacBook Air to this phone | The mesh node forwarding between two of its wireless clients | Plain TCP from the Air is no faster than SFTP, 7 to 14 MiB/s. From the wired Mac mini the same phone reads 77 MiB/s of plain TCP and 58 to 67 MiB/s by SFTP, and the Air sends the mini 95 MiB/s. The client used 7% of one core. [Details](#the-phones-download-cap-not-the-client) |
| Scrolling | Nothing that grows with the folder | At 120 Hz, 8 to 10% of frames miss one refresh, and none misses two, at 100 rows as at 50,000 (iPhone) |

Memory layout was not the limit on anything a person waits for, except sorting by date, size and kind. It's the one place a data-layout change made a large difference.

## What changed, and why

Each entry names the bottleneck, the evidence and the cost accepted.

**One shape for every folder row.** A condition at the top of a List row, including the one inside `WorkspaceLink`, made SwiftUI build every row to count them. The rows are now one `Button` with a varying action, chevron and menu. Measured directly, at 20,000 rows on iPhone: one shape 25 ms, `if`/`else` 175 ms, `WorkspaceLink` 548 ms. A custom view struct around the condition did not help (736 ms); neither did the row content, identifier type or context menu matter. *Cost:* rows push programmatically, so the row highlight doesn't linger through the push, and the chevron is drawn by the app. `FolderView.swift` says why, so the condition doesn't return.

**Fewer round trips.** Requests that can be answered together are sent together and judged afterwards in the order that makes them safe: root confinement still comes before a version match. Listings and reads return without waiting for `CLOSE`; a failed close still retires the channel. A known size ends reads exactly at the end of the file. Directory reads top up from half a window, because every read outstanding at EOF must be drained. *Cost:* five small additions to vendored Citadel ([provenance](../Vendor/Citadel/UPSTREAM.md)), and a failed close is no longer reported as the read's failure, only by retiring the channel. Reads still wait for the post-`OPEN` boundary recheck before any bytes move.

**Rows while a folder arrives.** With nothing on screen, rows appear 100 ms after the first batch if the rest hasn't come, and again each time they grow by half. Links resolve afterwards. The listing limit rose from 10,000 to 250,000 entries, and its deadline now extends while replies keep arriving. *Cost:* partial rows can move while **Updating…** shows. A folder already on screen is unaffected. On iPhone at 50,000 entries the updates cost 2 hitches, the longest frame 57 ms, against a single 2.6 s stall before.

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
- All 461 macOS tests pass with OpenSSH, including new ones for 340 reads and listings on one channel without waiting for `CLOSE`, a failed `CLOSE` reaching the caller, partial rows, search on its own channel, deadline extension and short and wrong size hints. That a failed `CLOSE` then retires the channel is checked in parts, not end to end against a real server.
- `ResponsivenessTests`, `FolderListingTests`, `RemoteEntryLayoutTests` and `PerformanceBenchmarkTests` pass hosted on the iOS simulator, 32 tests. A 100,000-entry listing returned exactly 100,000 entries.
- Eight UI journeys touching folder rows pass on the iPhone simulator. The keyboard journey failed once on its Home screen under load average 27, before reaching a folder, and passed when rerun.

- On an iPad Pro 11-inch simulator, `testAdaptiveWorkspaceKeepsLibraryFolderAndReaderOnIPad` fails at "Opening a preview keeps its folder visible", because the row sits under the column's bottom edge. The unchanged baseline fails on the same line. With that one assertion bypassed in a throwaway run, the rest of the journey passes on the new rows.

Not run: the whole UI inventory, VoiceOver and the Linux server helper. The rows' structure changed, so a pull request should carry `full-acceptance`.

## Follow-ups, 7 November

The five opportunities this work left, each treated as a hypothesis. Before is `b9bdcd1`'s code with the follow-ups' benchmark scenarios added; after is the follow-ups. Pairs were interleaved or alternated, and the order reversed every other pass.

The Linux server is a disposable QEMU guest on the Mac mini: Ubuntu 24.04, Linux 6.8, OpenSSH 9.6p1, Python 3.12, forwarded to loopback only. The existing [Linux acceptance suite](../Tests/LinuxSearchAcceptance/README.md) passed on it before anything was measured, and passes after, with two new tests.

### The Linux helper: adopted

**What limited it.** The helper was slower than the SFTP walk it was meant to beat: 1.56 s against the walk's 0.91 s for 364 folders at 40 ms (Mac), and the walk's first match came at 0.27 s. Timing it at three latencies put its setup at about 35 round trips, not 10 + 2 per descriptor: finding the root's descriptor took a directory listing of `/proc/PID/fd` twice, a READLINK and a REALPATH per descriptor in turn, and the results waited for the channel to close.

**What changed.**

- *Setup in four round trips.* Requests that don't depend on an earlier answer go together, judged in the same order as before. Descriptors are found by READLINK by number, up to 32, either side of the root's OPEN, all in one batch. The checks are unchanged: one new descriptor, leading to the root by READLINK and REALPATH, with its inode, mount and namespace compared by the helper before it reads anything, and the root held open until the helper exits. A server that answers out of order can only fail the one-new-descriptor test, which falls back to the walk; so does one with more than 32 descriptors open. The channel closes in the background.
- *Results as they're found.* The helper writes a line after a folder, at most ten times a second unless 64 KiB have piled up, and the app decodes each one off the actor and event loop, checking every candidate and every limit across lines as before. At the match limit the app stops listening and the helper ends at its next write. If the helper gives up part way, the walk that follows doesn't repeat what was already shown and counts it towards the limit. Duplicate checks now compare bytes, so two Unicode spellings of a name in one folder no longer make a response invalid.
- *Less work on the server.* A name that doesn't match takes no system call: the directory already says what each entry is. Only folders are sorted, and the binary check runs in C. Run on the guest directly, 91,000 entries took 74 ms instead of 341 ms warm, and 146 ms instead of 511 ms with its cache emptied.

| Search, Mac → guest through the proxy | Added | Before | After | First result after | SFTP walk, total (first) |
|---|---:|---:|---:|---:|---:|
| 364 folders, names | 0 | 45 ms | 30 ms | 28 ms | 71 ms (3) |
| | 40 ms | 1,571 ms | 460 ms | 458 ms | 910 ms (271) |
| | 150 ms | 5,236 ms | 1,467 ms | 1,464 ms | 3,147 ms (936) |
| 1,000 folders, 91,000 entries | 0 | 387 ms | 85 ms | 17 ms | 636 ms (14) |
| | 40 ms | 1,892 ms | 511 ms | 436 ms | 1,635 ms (276) |
| | 150 ms | 5,533 ms | 1,513 ms | 1,427 ms | 5,959 ms (953) |
| Contents, 500 files, a word in all of them | 0 | 277 ms | 78 ms | 16 ms | |
| | 40 ms | 1,794 ms | 507 ms | 438 ms | 30.1 s, stopped at 167 matches |
| | 150 ms | 5,476 ms | 1,494 ms | 1,425 ms | |

Pipelining alone took the 364 folders at 40 ms from 1,555 ms to 477 ms and the 1,000 folders from 1,903 ms to 787 ms; streaming and the helper's own speed did the rest. With a cold, slow disk (the guest's second drive held to 150 operations a second, cache emptied before every sample, so this is a model and not a real disk), at 40 ms:

| Search, cold modelled disk | Before | After | First result before | First result after |
|---|---:|---:|---:|---:|
| 1,000 folders, names | 9.60 s | 8.34 s | 9.33 s | 0.50 s |
| Contents, 500 files | 5.69 s | 4.51 s | 5.56 s | 0.45 s |
| 364 folders, names | 4.06 s | 2.94 s | 3.92 s | 0.56 s |

On iPhone, over Tailscale to the same guest, six samples each in alternating pairs:

| Search, iPhone → guest | Added | Before | After | First result after |
|---|---:|---:|---:|---:|
| 364 folders, names | 0 | 484 ms | 235 ms | 231 ms |
| | 40 ms | 1,876 ms | 607 ms | 603 ms |
| 1,000 folders, names | 0 | 957 ms | 267 ms | 145 ms |
| | 40 ms | 2,191 ms | 623 ms | 532 ms |
| Contents, a word in all 500 files | 0 | 2,924 ms | 1,654 ms | 163 ms |
| | 40 ms | 3,410 ms | 1,053 ms | 552 ms |

Results were the same in every run: the same matches, in the same counts. *Cost:* five more lines of vendored Citadel ([provenance](../Vendor/Citadel/UPSTREAM.md)), an output protocol of one line per batch, and results ordered by batch: within a batch in the app's natural order, nearer folders first, and between batches in the server's, which sets accents and case aside as the app does but can differ for some scripts. A folder is never split between batches, so which matches are kept at the limit follows the app's order within each folder; a single folder with many matching files shows nothing until it's done. The walk still shows its first match sooner at 40 ms (271 ms against 458 ms), because the helper must prove the root's identity before it reads anything. *Would reverse it:* a server where the descriptor scan or batching falls back when it didn't before; the acceptance suite catches the first on Linux.

Not tried: opening the exec channel during the identity checks, about one round trip; keeping the checked root and its channel between searches of the same folder, about six of the nine round trips, at the cost of holding a directory open on the server between searches.

### Connection setup: nothing to adopt

**The hypothesis was wrong.** Sending the subsystem request and `INIT` together saves nothing, because the app already does it: Citadel completes the request's promise when it's written, not when it's answered. Seven server implementations behaved identically either way, with every round succeeding: 80 each with nothing added and 48 each at 40 ms ([probe](performance/2026-11-07-followups/SFTPServerCompatibilityProbeTests.swift.txt)): about 92 ms to open a channel on all but OpenSSH, and 137 ms on OpenSSH. OpenSSH's extra round trip is its own: it opens a session channel with a window of zero and widens it only once the subsystem has started, so `INIT` can't go sooner ([each server's window](performance/2026-11-07-followups/session-channel-initial-window.txt)). The fear that a server might hang on early `INIT` isn't new risk, then: the app has always sent it early.

The servers were OpenSSH's `sftp-server` and `internal-sftp`, Dropbear 2022.83 with `sftp-server`, ProFTPD 1.3.8b `mod_sftp`, Paramiko 2.12, AsyncSSH 2.10, SFTPGo 2.7.6 and Apache MINA SSHD 2.15. Dropbear and Paramiko can't be reached with the app's algorithms (Paramiko has no AES-GCM), so they were probed with Citadel's wider set.

<a id="connection-setup"></a>Where a cold open's time goes, counted from a [trace](performance/2026-11-07-followups/connect-and-list-trace-40ms.txt) at 40 ms (the proxy hides TCP's handshake, one more):

| Round trip | What | Can the app save it? |
|---|---|---|
| 1 | Version banners | No |
| 2 | Key exchange | Already overlaps the client's offer |
| 3 | New keys, service request | Only by sending authentication unasked, which needs a change to NIOSSH's state machine |
| 4 | Signed authentication | No |
| 5 | Channel open | No: the request needs the server's channel number |
| 6 | Subsystem, and OpenSSH's window | No |
| 7 | `INIT` and the server's version | See below |
| 8-9 | The folder: REALPATH and OPENDIR, then reads | Already together |

**Measured, not adopted: the first requests with `INIT`.** Letting a channel's first requests follow `INIT` without waiting for the server's version saves a round trip on every implementation above, and every one of 320 rounds with nothing added and 192 at 40 ms succeeded ([0 ms](performance/2026-11-07-followups/probe-first-requests-0ms.txt), [40 ms](performance/2026-11-07-followups/probe-first-requests-40ms.txt)): a channel and its first listing took 271 ms instead of 316 ms on OpenSSH, and about 230 ms instead of 278 ms on the others. It was left out because the app reads a failed subsystem or version as a failed *open*, and decides on that whether to fall back from server search and whether to share a channel; with requests in flight, the failure would surface as a failed listing instead. It's also one round trip in nine on a cold open, for servers no one here can test, like Bitvise or Synology's. *Would reverse it:* a version check that runs before any reply is used, with the same fallbacks, and evidence from a closed-source server.

### Offline folders and saved indexes: `FolderWalking` rejected, reads overlapped instead

**The hypothesis was wrong on both counts.** Saved indexes already list through `FolderWalking`. For offline folders, the walk's listings changed nothing: 22.09 s against 21.99 s for 50 files at 40 ms, and 18.52 s against 18.37 s for a folder of 256 links, where skipping link lookups should help most. A folder tap during an offline download was already unaffected, at about 90 ms. What limits both is each file's round trips, taken one at a time: about 4.4 for a search or index read, about 10.7 for an offline file, most of them the file's own channel.

**Adopted: reading ahead.** A content walk and an index build start reading the files they'll reach next, so the round trips overlap. Each read keeps its own confinement checks and files are still handled strictly in order. Files are offered and started in the walk's order, so a read under way is always for a file after the current one, and each read's limit is charged to the walk as it starts and stays charged if it's never used: the file and byte limits hold for everything sent. After the deadline nothing new starts, but a read that has already finished is kept. Reads move to the walk's channel, so they can't queue ahead of browsing or retire its channel. The window is 32 files and 2 MiB of expected bytes, because a read's deadline includes its wait behind the others. An index build lists every folder before reading: the walk can't take more listings while it reads, and reads started in the order they'll be wanted waste no slots. It keeps only the files the file limit lets it read, and stops listing once it has one more than that, where its reads would stop.

| Mac → guest through the proxy | Added | Before | After |
|---|---:|---:|---:|
| Saved index, 500 files in 101 folders | 0 | 564 ms | 201 ms |
| | 40 ms | 30.1 s, stopped at 166 of 500 | 3.4 s, all 500 |
| | 150 ms | 30.3 s, stopped at 48 of 500 | 11.8 s, all 500 |
| Contents over SFTP only, a word in all 500 | 40 ms | 30.1 s, 167 matches | 13.6 s, all 500 |
| Contents over SFTP only, a word in 32 | 40 ms | 30.2 s, 14 matches | 15.4 s, all 32 |
| A folder tap meanwhile | 40 ms | 90 ms | 90 ms |

| Index at 40 ms, by window | 4 | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|
| Offered as listed | 30.1 s, stopped | 26.9 s | 20.6 s | 5.4 s | 2.2 s |
| Offered in the order wanted | 25.3 s | 12.3 s | 6.4 s | 3.5 s | 2.1 s |

Name searches, which read nothing, didn't change. A first version offered files as folders arrived and charged reads only when used, which a review showed could exceed the limits; offering them in the walk's order and charging at once [measured the same](performance/2026-11-07-followups/read-ahead-limits-fix.jsonl): an index at 40 ms in 3.60 s against 3.43 s, and content searches in 13.1 s and 13.9 s against 13.6 s and 14.7 s. *Cost:* up to 32 reads and their results held at once, within the byte budget; an index shows only folder counts until its listing is done; a live search reads ahead only about a folder at a time, since its walk can't take listings while it reads. *Would reverse it:* reads timing out on a slow server that read one at a time in time, which the 2 MiB cap is there to prevent.

Not tried: offline folders, whose files each open their own channel for about four of their 10.7 round trips. Sharing one channel, or downloading a few at once, is the next step there.

### Downloads on a faster phone link: no measurable change, `TransferPacing` kept

*Later this was found wrong twice over: the comparison couldn't show a difference, and a faster phone path did exist, from the wired Mac mini. The cap was the path from the Air, not the phone's Wi-Fi. See [the phone's download cap](#the-phones-download-cap-not-the-client). The figures below stand as measured.*

No faster path from the phone exists here. To a MacBook Air's SSH fixture on the same LAN the phone reached 6 to 7 MiB/s, though the Mac mini downloads the same file from it at 17 MiB/s, so the phone's Wi-Fi is the limit. A cable gave no path either: an app can't reach the Mac through the device tunnel (the connection timed out). This Mac's LAN address isn't filtered by the network, as the earlier note said, but by Little Snitch, per process.

On that LAN path, with the window's growth switched off and on in turn within one process, six pairs at each of three latencies:

| iPhone → Air over Wi-Fi | Fixed at 16 | Growing | Growing's speed-up, median (range) |
|---|---:|---:|---:|
| Nothing added | 6.5 MiB/s | 6.4 MiB/s | 0.98 (0.79-1.08) |
| 40 ms | 5.1 MiB/s | 4.7 MiB/s | 0.93 (0.86-1.10) |
| 150 ms | 3.8 MiB/s | 3.8 MiB/s | 1.01 (0.92-1.22) |

That shows no change, and couldn't, though not for the reason first given here (that something below the window held both to 3.8 MiB/s): the growing arm can't have grown, as [below](#the-phones-download-cap-not-the-client) explains. `TransferPacing` stays, because it grows only once a round trip delivers more than the window, so it does nothing on these links, and through the proxy it was worth +114 to +171%. *Would reverse it:* a phone path that delivers more than 1 MiB a round trip and still shows no gain, or shows a loss.

### Measurement gaps: closed

**120 Hz.** An iPhone holds an app's display links to 60 Hz unless its Info.plist sets `CADisableMinimumFrameDurationOnPhone`, so no change to the test could have shown more. A benchmark build now adds it to its own host only, and the test records the median, 99th percentile and the share of frames that miss a refresh. On iPhone at 120 Hz, the median frame is 8.3 ms and the 95th and 99th percentiles 16.7 ms, at 100, 1,000, 10,000 and 50,000 rows alike: 8 to 10% of frames miss one refresh, none misses two, and the 100-row control misses as many as 50,000 rows. Asked for 60 Hz in the same build, the median is 16.7 ms. The app itself doesn't set the key; Apple documents it as lifting the limit for an app's own display links and animations, not for system scrolling.

**Peak memory while listing.** The kernel keeps a peak footprint for each process that never goes down, so a fresh process that lists once can read the listing's true peak; the benchmark now records it when run with `--only list.100000` alone. Listing 100,000 entries peaks at 37 MB on iPhone, over Tailscale to the guest (the heap sampler had said 31 MB), and 39 MB on the Mac (sampler: 12 MB). Instruments' Allocations, attached on iPhone over the same three listings, recorded 1.15 GB allocated in 1.26 million allocations, nearly all short-lived: about 3.8 KB and four allocations per entry each listing, with 5 MB live at the end ([statistics](performance/2026-11-07-followups/iphone-list100000-allocations-statistics.xml)). `xctrace` can't export a peak from the command line, which is why the kernel's figure is the one reported. The churn costs no time anyone waits for: the server sets the pace of a large listing.

### Correctness of the follow-ups

- The Linux acceptance suite passes on the guest, 7 tests: the original five, one that results arrive before the search finishes, and one that the match limit ends the helper and browsing carries on. The two that use the production adapter also pass with `internal-sftp` as the subsystem.
- All 478 macOS tests pass with OpenSSH on top of `b9bdcd1`, with the opt-in `LatencyBenchmarkTests` skipped as usual. New ones cover output split anywhere between chunks, a missing or trailing final line, limits and duplicates across lines, two Unicode spellings of one name, the match limit on the last line, a walk after a partial server answer, the helper's binary check against every byte value, the helper's types without stat, and reading ahead within file, byte and in-flight limits, a file that grew, cancellation, and index order.
- Not run: the iOS simulator, the UI journeys and VoiceOver. Nothing in the follow-ups touches a view.

## The phone's download cap: not the client

Why phone downloads stayed below the link and, at 150 ms, below what a window of 16 allows. Each cause was a hypothesis, tested in arms that rotate within one process. The phone was on the home Wi-Fi with two servers: a throwaway OpenSSH fixture on the MacBook Air, which is also on Wi-Fi (802.11ax, 5 GHz, 80 MHz, −37 dBm), and one on the Mac mini, on gigabit Ethernet. Delays came from `latency_proxy.py`, on the Air for the Air and on the mini's loopback for the mini. Little Snitch on the mini lets `nc` take LAN connections but not the fixture, so a loop of `nc` relays the phone to it. Raw data: [`performance/2026-11-07-download-cap`](performance/2026-11-07-download-cap).

**The cap is the Air-to-phone path.** A bench-only arm reads the same 64 MiB by plain TCP, rotated with SFTP in one process:

| iPhone ← server, 3 or 4 rotations | Median | Range |
|---|---:|---:|
| Mini, plain TCP | 77.1 MiB/s | 8.4-80.2 |
| Mini, plain TCP, 8 MiB `SO_RCVBUF` | 71.7 MiB/s | 36.5-72.8 |
| Mini, two plain TCP streams at once, together | 65.5 MiB/s | 62.5-67.3 |
| Mini, SFTP through the relay | 58.5 MiB/s | 29.7-66.6 |
| Air, plain TCP, same rotation | 7.8 MiB/s | 7.2-11.0 |
| Air, plain TCP, 8 MiB `SO_RCVBUF` | 12.0 MiB/s | 12.0-13.6 |
| Air, two streams, together | 13.7 MiB/s | 12.8-14.5 |
| *Earlier runs, Air only:* plain TCP | 7.1 and 8.7 MiB/s | 5.1-11.1 |
| SFTP without the proxy | 8.3 and 9.9 MiB/s | 6.2-10.6 |
| SFTP through the proxy, nothing added | 7.0 MiB/s | 5.8-9.0 |

The phone's Wi-Fi carries 77 MiB/s and RemoteFiles takes most of it, so neither the phone nor the client sets the 7 MiB/s seen from the Air. The Air isn't slow either: it sends the mini 93 to 97 MiB/s of plain TCP and receives 82. Only traffic from one wireless device to the other is slow, and in the earlier rotations SFTP over it was never slower than plain TCP. The network is a mesh, but the router's app shows the Air, the phone and the mini's own Wi-Fi all on one node. Through that node the Air sends 256 MiB to the mini's Wi-Fi address at 17.0 and 17.5 MiB/s, and to its Ethernet address at 62.9 and 65.3 MiB/s; the mini's interface counters confirm each path. Two strong 802.11ax clients on one node and channel reach each other at well under half of what either gets alone, which no client can change. Turning off AirDrop and Handoff on the Air changed nothing (17.2 and 15.2 against 65.3 and 61.1 MiB/s, alternating), though its peer-to-peer interface (`awdl0`) still reported itself active and the mini's was left on. The first sample of an arm was sometimes low on every path; the first SFTP sample on the main port also included a new connection, since fixed, which can't account for the gaps between paths.

**The earlier pairs compared 16 with 16.** `TransferPacing` grows only while one and a half times what a round trip delivers exceeds the window. Through the Air at 150 ms the phone delivered about 0.6 MiB a round trip, and 1.5 × 0.6 MiB is less than the 1 MiB window, so the growing arm stayed at 16, and nothing recorded how far it grew. `windowpairs` now rotates three arms (fixed at 16, growing, fixed at 64) and records each one's largest window and mean reads in flight. From the mini, the first phone path faster than the window:

| iPhone ← mini, 3 rotations | Fixed at 16 | Growing (largest window) | Fixed at 64 |
|---|---:|---:|---:|
| Nothing added, relay only | 37.0 MiB/s (25.8-39.5) | 41.1 MiB/s (36.4-53.7), 24-29 | 44.7 MiB/s (14.8-53.4) |
| 40 ms | 13.2 MiB/s (13.1-14.2) | 25.7 MiB/s (17.7-28.7), 64 | 26.2 MiB/s (22.0-38.0) |
| 150 ms | 5.3 MiB/s (5.2-5.3) | 11.9 MiB/s (7.1-12.8), 64 | 14.3 MiB/s (8.6-14.3) |

Growth doubles a fixed window's speed at 40 ms and more than doubles it at 150 ms, reaching 98% and 83% of a fixed 64. Fixed at 16, the phone gets close to the window's bound: at 150 ms, about 1 MiB per 155 ms once about 1.3 s of channel setup, path checks and `OPEN` is taken off. Through the Air the window mattered only at 150 ms (4.9 fixed at 16, 7.0 growing, 8.7 fixed at 64), and the earlier 3.8 MiB/s wasn't reproduced; it fits a slower link that day, whose queue lengthened the round trip once the window nearly filled it.

**Not the proxy, the client's CPU or SSH.** From the Mac mini, OpenSSH's own `sftp -R 16 -B 65536` through the Air's 150 ms proxy moved a flat 6.0 MiB/s once connected, at the window's bound. `TCP_SENDMOREACKS` on both of the proxy's sockets changed nothing (4.5 and 4.6 MiB/s with connection setup), and NIOSSH's 8 MiB channel window, topped up at half, can't bind with at most 4 MiB in flight. On the Mac with the proxy capped at 52 Mbit/s, RemoteFiles reached the cap at every latency. On the phone, Instruments' Time Profiler found the NIO event loop thread, which decrypts and parses every byte, busy 7% of one core during downloads at 7.2 to 7.6 MiB/s, and every other thread under 1%.

Nothing in the app changed. The benchmark gained the three window arms and the plain TCP baseline (`linkbaseline`), and transfers report their largest window and mean reads in flight to `TransportMetrics`, at the cost of one closure call per reply. *Would reverse it:* plain TCP over some phone path clearly beating SFTP over the same path, or two streams beating one where one SFTP connection is used.

**What it leaves.** At 150 ms growth settles below a fixed 64 (11.9 against 14.3 MiB/s from the mini). By design it stops once requests wait half as long again as the shortest round trip; a fixed 64 keeps about 4 MiB in flight, which anything else on the connection waits behind. Whether the rest is worth that wait needs `contended` measured on the phone at that latency.

## Remaining opportunities

Theoretical until measured, most promising first.

1. **Offline folders' files.** About 10.7 round trips each, one at a time; a shared channel would save about four.
2. **Repeated server searches of one folder.** Keeping the checked root and its channel could take a search from about nine round trips to three.
3. **The first requests with `INIT`.** One round trip per channel, measured on seven implementations; see [why it was left out](#connection-setup-nothing-to-adopt).
4. **Live content searches over SFTP** read ahead only about a folder at a time. Letting the walk take listings while it reads would give them the index's window.
5. **Read-window growth on a long phone path.** At 150 ms it reached 11.9 MiB/s against 14.3 for a fixed 64; measure browsing during a transfer on the phone before trading queue depth for it. See [the phone's download cap](#the-phones-download-cap-not-the-client).

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
TEST_RUNNER_REMOTEFILES_PERFORMANCE_BENCHMARK=1 xcodebuild test-without-building -xctestrun DD/Build/Products/*.xctestrun -destination 'id=DEVICE' \
  -only-testing:RemoteFilesTests/PerformanceBenchmarkTests/testFolderScreen -only-testing:RemoteFilesTests/PerformanceBenchmarkTests/testLocalWork

# Transport. The address must be one the phone can reach: Little Snitch on this Mac lets the phone in over Tailscale but not the LAN.
python3 -B scripts/benchmark_performance.py device --output phone.jsonl --label after --xctestrun DD/Build/Products/*.xctestrun \
  --udid DEVICE --address MAC_ADDRESS --rtt 0,40
```

Against a server you already run, such as the Linux guest above, alternating builds:

```sh
python3 -B scripts/benchmark_performance.py server --output linux.jsonl --checkout before=../before --checkout after=. \
  --port 22401 --user ubuntu --key KEY --host-key HOST_KEY.pub --root /srv/rf/bench --only assisted,bulk --rtt 0,40,150
```

The `assisted` scenarios search the guest's `tree`, `big` and `docs` folders with the helper and with the walk; `REMOTEFILES_BENCHMARK_ASSISTED_MODE=helper` or `walk` runs one. `bulk` builds an index and saves an offline folder of `REMOTEFILES_BENCHMARK_BULK_ROOT`. `--cold-command` empties the server's caches before each search sample. `windowpairs` rotates a read window fixed at 16, a growing one and one fixed at 64 in one process, and records how far each grew. `linkbaseline` rotates SFTP with a plain TCP read of the same file: `REMOTEFILES_BENCHMARK_RAW_PORTS` lists ports on the server's host, or `HOST:PORT` elsewhere, that send `big-64m.bin` and close, such as a loop of `nc -l`; the two-stream arm also reads from the next port up, and `REMOTEFILES_BENCHMARK_SFTP_PORTS` lists other ports of the same server, such as one without the proxy. For 120 Hz frames, give the benchmark host an Info.plist with `CADisableMinimumFrameDurationOnPhone`; `REMOTEFILES_BENCHMARK_FRAME_RATE=60` asks for 60 Hz in the same build.

Keep the phone unlocked and allow Local Network on first run. Links vary, so alternate short runs and compare pairs, as for downloads above. Remove the host afterwards with `xcrun devicectl device uninstall app`; it is `dev.iris.RemoteFilesBenchTestHost`.

Nothing in the harness fails on a timing, because shared machines are too noisy for that. `PerformanceBenchmarkTests` runs once in CI at its smallest size, so it can't rot without anyone noticing. To catch a regression, compare against a kept baseline when changing listing, search, reads, rows or transfers.
