# Automated acceptance

Use the acceptance runner after integration, from Xcode 27 on a Mac with an
available iOS 27 simulator. It does not require an iPhone, a saved connection,
existing SSH keys, or changes to the Mac's Remote Login/security settings.
The default run combines host, Simulator, VoiceOver and device-compilation
checks. It does not replace a physical-device or real-server journey; see
[manual acceptance](MANUAL_ACCEPTANCE.md) for those checks.

```sh
xcrun simctl list devices available
scripts/test-acceptance.py \
  --simulator SIMULATOR_UDID \
  --output /private/tmp/remotefiles-acceptance-NEW_RUN
```

The output must be a fresh directory outside the checkout. The default mode
requires a clean checkout and identifies the exact commit. While preparing a
local change, add `--allow-dirty`: the runner captures tracked and nonignored
untracked files, records the base commit, full source manifest SHA-256, binary
patch SHA-256, and Git status, then builds that snapshot. A snapshot taken while
another agent changes files fails rather than mixing source versions. Dirty
results describe a working-tree snapshot and must not be attributed to HEAD.

Retain the output directory: `SUMMARY.md` is the readable report; `summary.json`
contains commands, exit codes, timing, suite counts, test identifiers, source
identity and exclusions. Compiler/test logs, source/lockfile copies, simulator
inventory, raw xcresult summaries and the signed Simulator/VoiceOver xcresults
remain available for investigation. The runner checks that builds did not alter
captured source or lockfiles. Dependencies use the checked-in resolved versions.

For repeated integration runs, these optional absolute paths reuse build and
dependency caches without reusing an evidence directory:

```sh
scripts/test-acceptance.py --allow-dirty \
  --simulator SIMULATOR_UDID \
  --output /private/tmp/remotefiles-acceptance-NEW_RUN \
  --source-packages /private/tmp/remotefiles-acceptance-SourcePackages \
  --swift-scratch /private/tmp/remotefiles-acceptance-SwiftBuild \
  --derived-data /private/tmp/remotefiles-acceptance-DerivedData
```

Run one acceptance process at a time per simulator/build cache. Builds use two
compiler jobs to keep an 8 GB Mac responsive. The isolated sshd binds
`127.0.0.1:22222`; pass `--port 22223` if another disposable fixture owns that
port. A port collision fails the lane. Each fixture-backed lane keeps the
server's complete, timestamped log as `<lane>-sshd.log` in the output folder, so
a dropped connection can be attributed to the client or the server. The fixture
disables OpenSSH per-source penalties: tests deliberately abandon handshakes, and
penalised loopback connections would otherwise fail later, unrelated tests.
sshd runs with an empty `TZ` (UTC): otherwise macOS reloads a zoneinfo file for
the long name of every listed entry, which made the 1,000-entry folder exceed its
deadline under a fresh simulator's boot load. The two directory-service lookups
per entry remain, so fixture listings stay sensitive to host load. On iOS, XCTest
can report a different error than the test threw when another task throws as the
test fails; fixture tests therefore disconnect in an async teardown block, after
the failure has been recorded, not from `defer`.
In a restricted agent environment, use
the supported approved shell execution workflow for compiler caches,
CoreSimulator and the loopback fixture. Do not change system permissions or
disable sandbox/security checks to make a test pass. Each command has a 30-minute
deadline, including test-host startup; use `--timeout-minutes 5` for a bounded
infrastructure check. A timeout interrupts only that stage's process group and
allows its fixture cleanup trap to finish before escalation to termination.

## CI selection

The default local command below still requires all four lanes. GitHub CI uses
independently inventoried lanes to run quick macOS/hosted-core validation on
ordinary code changes, and adds UI, VoiceOver and Release jobs for sensitive
changes or explicit requests. See [CI policy and timing](CI.md). `--lane` reports
its selected coverage explicitly; it does not count unrequested lanes as passed.

## Required lanes and failure rules

| Lane | What it establishes | Required outcome |
|---|---|---|
| macOS + loopback OpenSSH | All host core tests, key import/trust, read/stream caps, cancellation and generated server fixtures; actual large-image decode | Every inventoried method runs, no failures or skips; benchmark operations run once on loopback |
| Signed iOS Simulator | Hosted Keychain/UI lifecycle tests, loopback SFTP, generated large-image decode and ordinary demo UI journeys | Every inventoried method runs; only real-server opt-in methods, the physical-device Data Protection assertion and the opt-in Face ID checks may skip |
| Actual VoiceOver service | `XCUIVoiceOverService` speech/focus checks against production reader/image views in a disposable fixture app | Every VoiceOver method passes; original VoiceOver enabled state is restored |
| Release generic iOS compile | Optimized device-target compilation | Build succeeds; this is not an installable/signed device run |

The runner inventories XCTest methods in platform-specific source and compares
that list with completed method results. An omitted new Xcode test file, crash,
unexpected skip, unexpected retry, nonzero command exit, missing xcresult, or
xcresult/log count mismatch fails acceptance. The inventory deliberately supports
the repository's `os(iOS)`/`os(macOS)` conditionals; a new conditional form must be
handled explicitly, otherwise acceptance fails closed.

There are no automatic retries. An investigated rerun uses a fresh evidence
directory; retain and disclose the first failure. Summary status stays `running`
until all required lanes finish, or `failed` as soon as a lane fails.

The demo reader VoiceOver journey enables the service before launching the app
so the initial screen change establishes focus. PR #23's first VoiceOver run
failed at its first Home speech query with `No speech available` after enabling
the service on an already idle screen; seven other journeys passed. The startup
ordering change retains every speech, navigation and state-restoration assertion
and does not retry or skip service failures. For the same reason the long JSON
and SVG journey enables VoiceOver before opening each preview, then focuses and
double-taps the touch-staged row, and stays in VoiceOver to switch the SVG to
Source. CI run 40241708814 failed with `No speech available` after re-enabling
the service on the settled SVG Source view (the same tree had passed), and an
Xcode 27.2 Simulator failed the same way on every settled-preview enable.

`RealServerUITests` are explicitly skipped in the Simulator run. The single
`IdentityTests/testTrustStoreWritesUseCompleteFileProtection` method may also skip
because Simulator filesystems do not report Data Protection classes; its actual
protection assertion still requires a physical device. The three opt-in Face ID
methods in `IdentityTests` also skip unless given the setup described in
[KEY_SUPPORT.md](KEY_SUPPORT.md). Keychain tests must run.
The opt-in latency benchmark's operations run once against the generated
loopback fixture on both platforms, with no latency proxy or performance
threshold. These timings are smoke coverage, not network-latency evidence. The runner
clears inherited real-server opt-in variables and never touches a real server.
The current `testSeventyMegabyteImageUsesBoundedDisplayPixels` creates a valid
PNG over 70 MB inside its temporary directory on both platforms, then checks
decoded bounds; fixture generation retains a single row. Both platform runs
must pass. This replaces the baseline's macOS-only method body and removes its
manual fixture prerequisite. Simulator speech/focus does not prove touch
gestures, rotor or Braille behavior.

The VoiceOver script can also be run independently. Set
`REMOTEFILES_SOURCE_PACKAGES_DIR` to reuse a locked package checkout directory;
otherwise it uses normal Xcode package resolution:

```sh
REMOTEFILES_SOURCE_PACKAGES_DIR=/private/tmp/remotefiles-acceptance-SourcePackages \
  scripts/test-voiceover.sh SIMULATOR_UDID /private/tmp/remotefiles-voiceover-NEW_RUN
```

## Feature-specific coverage

These sections identify the regression tests and the limits of the evidence
for changes that affect offline storage or search. They supplement the required
lane and failure rules above.

### Offline copies

`OfflineFolderTests` covers complete recursive snapshots, empty/hidden folders,
skipped links, legacy metadata, independent overlapping copies, byte-sensitive
names, atomic replacement, count/byte/traversal bounds, cancellation/deadlines,
redirects and corrupt membership. The folder UI journey browses a nested saved
document after disconnect, backgrounding and relaunch, then removes the snapshot.
The OpenSSH folder check rejects changed canonical roots and aliases before
downloading and verifies locally saved bytes after disconnect. No skips or
deadlines are added to accommodate these checks.

`OfflineFileTests` verifies exact originals, persistent metadata, atomic refresh,
corrupt/symlinked local files, count/byte/lease limits, and cancellation with late
writers. `AppModelLifecycleTests` covers background cancellation, changed/deleted
connections and ownership of a shared store across windows, including a window
opened after its library directory is created. `OfflineFileTests` also checks
actor reuse across equivalent absolute, relative and directory-hinted URLs.
The OpenSSH suite pins a real fixture file, reads it after disconnect, and
rejects a canonical-root escape. The Demo UI journey pins, disconnects, reopens
after relaunch, removes the copy and checks that the remote original is still
readable. These methods are part of the normal generated inventories; they add
no allowed skips.

Offline-link checks in `OfflineFileTests` and `OfflineFolderTests` cover saved-route
and snapshot isolation, parent/nested/percent-encoded paths, Unicode byte names,
missing/excluded destinations, stale/removed sources, relaunch and cancellation.
The Demo UI journeys follow local and linked heading fragments, navigate nested
saved documents, return with Back and recover from missing/out-of-folder links
after disconnect.

The offline reader has no SFTP/resource service. Its media/renderer policies are
the existing bounded preview policies. Simulator permissions/backup-exclusion
checks do not establish locked-device Data Protection; physical acceptance is
listed in [offline files](OFFLINE_FILES.md).

### Bounded file-content search

`FileContentSearchTests` covers source matching, Unicode line/snippet handling,
binary/hidden/link/size exclusions, incremental updates, read/file/match/depth/time
budgets, failed-read accounting, and cancellation that cannot publish late bytes
or cancel a foreground preview. `FolderBrowsingTests` covers Contents scope
identity, retained completed results and rejection of updates for an obsolete scope.

`SFTPIntegrationTests.testContentSearchReadsSourceOverSFTPAndNeverFollowsEscapeLinks`
checks real bounded source reads with the disposable server. The macOS-only
`testContentSearchRejectsAnEntireRootRedirectedAfterListing` replaces only a
synthetic fixture directory with a symlink and checks the fixed canonical boundary.
The UI journey `testContentSearchShowsSourceSnippetsAndKeepsResultsWhenOpeningAFile`
checks snippet/line accessibility labels, recursive results, reader navigation and
scope changes, with an adaptive iPad path. These checks do not establish physical
device interaction or cellular performance.

### Recursive search timeout recovery

`SFTPIntegrationTests.testSubfolderSearchRecoversListingsInterruptedByAPeersDeadline`
uses the existing loopback OpenSSH fixture and reply-stalling relay. It staggers
four real `SFTPRemoteFileService` listings so the first deadline closes their
shared SFTP channel before its peers reach their own deadlines, then releases
the held replies. Assertions require the first listing's actual `timedOut`,
three actual `connectionEnded` failures with one retry each, retained ordered
matches, traversal of queued descendants, a replaced SFTP channel on the same
authenticated connection, and a successful foreground listing afterwards.
The scheduling wrapper never injects snapshots or errors. The existing
`FolderSearchTests` still cover persistent connection failure and root errors;
`testConnectionRecoveryDoesNotStartAListingAfterTheSearchDeadline` covers the
retry's scheduling budget separately.

`FolderSearchTests.testNewlyDiscoveredFoldersAreConsumedAfterTheLastListingFinishes`
and the corresponding `FileContentSearchTests` regression walk nested trees with
one and four listing slots. They require every discovered folder and match to
be consumed even when the previous listing was the last outstanding child.
Run these suites in optimized builds as well as Debug when changing scheduling:

```sh
swift test -c release --filter 'FolderSearchTests|FileContentSearchTests|OfflineFileTests'
```

Run just this investigation's suites on a supported Mac with:

```sh
scripts/test-openssh.sh swift test --filter 'FolderSearchTests|SFTPIntegrationTests'
```

The relay holds encrypted server replies on loopback while OpenSSH continues
working. This exercises a real timeout and channel-close cascade, but does not
establish how an external SFTP server behaves when only one filesystem operation
stalls while other responses continue. Physical iPhone checks are still needed
for cellular/Tailscale interruptions, background/foreground cancellation and
post-recovery navigation during a recursive search. Neither a simulator run nor
Release device compilation supplies that evidence.

<a id="october-3-baseline"></a>
## Historical baseline: October 3

The initial source snapshot was copied from clean commit
`5522b660651412d3d42fd8b05286e95f176e8d49` on
`codex/remote-files-preview`. Toolchain: Xcode 27.0 (27A266a), Swift 6.4;
selected destination: iPhone 18 Pro, iOS 27.0 (24A434), UDID
`2AD111FE-5A34-4EBF-A9E4-6302E9255002`.

Baseline evidence is retained locally under
`/private/tmp/remotefiles-baseline-acceptance-5522b660` with source at
`/private/tmp/remotefiles-baseline-5522b660.DnSr5B`. These are local run paths,
not portable dependencies or committed test results.

| Baseline lane | Passed | Failed | Skipped | Interpretation |
|---|---:|---:|---:|---|
| macOS without SSH fixture | 40 | 1 | 6 | Persistence write failed; real SSH was deliberately absent |
| macOS with loopback SSH | 40 | 7 | 0 | Persistence plus all six SSH methods failed during fixture metadata creation, before authentication |
| Signed Simulator initial attempt | 0 | — | — | Products compiled/signed; no method results during 10 minutes; explicitly interrupted |
| Signed Simulator bounded retry | 0 | — | — | Existing signed products; no method results during six minutes; explicitly interrupted |
| Baseline VoiceOver | — | — | — | Not run after the bounded Simulator startup attempts stalled |

The host failures exposed unconditional use of iOS complete-file protection in
`MetadataStore` on macOS. An independent disposable write probe passed plain and
atomic writes, while complete-file-protection writes failed with `EPERM`. This
baseline does not establish SSH or persistence success. The compatibility fix
and feature changes require a new aggregate run of their own exact snapshot.

The baseline large-image method did execute: 73,533,330 input bytes became
1600 × 800 pixels / 5,120,000 decoded bytes. This measures the decoded thumbnail
allocation, not peak process RSS. XCTest snapshot latency does not establish a
sub-200 ms cached first display.

## Remaining user/device participation

| Check | Minimum participation |
|---|---|
| Repeat automated lanes | None once the Mac's checkout, Xcode and simulator are available |
| Physical build and Keychain/network lifecycle regression | Connect and unlock the iPhone; keep it available for the device run |
| Local Network denial and Settings recovery | Grant authorization for the controlled permission exercise and perform requested device Settings changes |
| Changed-server refresh/background recovery | Authorize a disposable server fixture; keep the device connected/unlocked; real-server mutation remains separate authorization |
| Touch selection/copy and original Save to Files | Perform text-selection gestures; choose a Files destination and reopen/compare the exported file |
| VoiceOver continuous reading, focus return and rotor | Enable VoiceOver and perform the documented touch/rotor gestures on the current build |
| Braille reading/navigation | Pair a Braille display and exercise navigation/readback |
| Physical cached-first-display timing | Make the iPhone available for an instrumented Release measurement; no snapshot-timing proxy |

Keep device tests distinct from simulator results. No unavailable physical test
is counted as passed.
