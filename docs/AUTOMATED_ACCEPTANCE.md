# Automated acceptance

Use the acceptance runner after integration, from Xcode 27 on a Mac with an
available iOS 27 simulator. It does not require an iPhone, a saved connection,
existing SSH keys, or changes to the Mac's Remote Login/security settings.

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
port. A port collision fails the lane. In a restricted agent environment, use
the supported approved shell execution workflow for compiler caches,
CoreSimulator and the loopback fixture. Do not change system permissions or
disable sandbox/security checks to make a test pass. Each command has a 30-minute
deadline, including test-host startup; use `--timeout-minutes 5` for a bounded
infrastructure check. A timeout interrupts only that stage's process group and
allows its fixture cleanup trap to finish before escalation to termination.

## Required lanes and failure rules

| Lane | What it establishes | Required outcome |
|---|---|---|
| macOS + loopback OpenSSH | All host core tests, key import/trust, read/stream caps, cancellation and generated server fixtures; actual large-image decode | Every inventoried method runs, no failures or skips |
| Signed iOS Simulator | Hosted Keychain/UI lifecycle tests, loopback SFTP, generated large-image decode and ordinary demo UI journeys | Every inventoried method runs; only explicit real-server opt-in methods may skip |
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

`RealServerUITests` are explicitly skipped in the Simulator run. The runner
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

## October 3 baseline

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
