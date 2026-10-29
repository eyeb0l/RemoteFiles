# CI policy and timing

[Build and test](DEVELOPMENT.md) · [Automated acceptance](AUTOMATED_ACCEPTANCE.md)

This page explains which checks a change receives, how to reproduce them, and
where to find the evidence. A green CI run covers only the jobs selected for
that change; it is not by itself evidence of a physical-device or real-server
check. For the full local suite and its failure rules, see
[Automated acceptance](AUTOMATED_ACCEPTANCE.md).

## Ordinary pull requests

Every PR and main push runs **Repository checks** on Linux: Python runner/scope
regressions, generated-project consistency and whitespace across the complete
change, including every commit in a PR. Documentation-only changes start no Mac
runners.

Code changes also run two jobs in parallel:

- **Quick / macos-openssh**: every inventoried macOS core test, including the
  generated OpenSSH fixture and key-import cases.
- **Quick / simulator-core**: every inventoried signed iOS hosted core test,
  including Keychain, image, reader-position and SFTP regressions. This excludes
  the separate slow UI-journey target, not UIKit-based core tests. The generated
  `RemoteFilesCoreCI` scheme builds the complete core-test target and its signed
  UIKit host, without building the application or UI-test runner. The original
  `RemoteFiles` scheme remains responsible for app/UI/Release acceptance.

The core and UI lanes record source identity and toolchain/device inventory while
their fresh disposable Simulator is still shut down. Each lane runs
`build-for-testing` for `generic/platform=iOS Simulator`, boots only that device
after the build succeeds,
then runs the same products with `test-without-building`. Build and test execution
each receive their own 30-minute command deadline, within the existing job ceiling.
A failed build cannot fall back to stale cached tests. The source/HEAD/status guard spans both actions;
method inventory, unexpected-skip, duplicate-result and xcresult-count checks are
unchanged. The OpenSSH fixture still surrounds test execution.

Only the methods in `SIMULATOR_ALLOWED_SKIPS` may skip in the hosted core lane:
the physical-device Data Protection assertion and the opt-in Face ID checks. Benchmark operations run once on loopback. Missing methods,
failures, unexpected skips and xcresult/log count mismatches fail validation.

## Changes requiring broader acceptance

After quick validation passes, acceptance runs these jobs in parallel:

- **Acceptance / simulator-ui**: ordinary demo journeys and navigation; explicit
  real-server opt-in methods remain skipped.
- **Acceptance / voiceover**: actual VoiceOver speech, focus and custom-action discovery
  against disposable fixture entry points using production views.
- **Acceptance / release-device-compile**: unsigned optimized iOS compilation.

The classifier in [scripts/ci_scope.py](../scripts/ci_scope.py) escalates reader,
preview/security boundaries, navigation entry points, dependency pins, vendored
code, Xcode/app configuration, fixtures and CI/acceptance infrastructure. Unknown
paths also require acceptance. It considers deleted files and both sides of a
rename, not just the final commit or new filename. The classifier's tests protect
docs-only, ordinary-code, sensitive-path and explicit-override decisions.

Add the **full-acceptance** PR label to request the broad suite for any change.
The workflow also responds to label changes. Manual dispatch defaults to full
acceptance; turn off **full_acceptance** to request just the quick checks. A
failure in quick validation prevents expensive acceptance jobs from starting.

Across these five jobs, the inventories cover the original full acceptance
suite. Each job reports only its selected lane; a partial report never claims
full acceptance. Physical iPhone and real-server participation remain separate.
No signing secrets, saved connections or personal SSH keys are required.

## Caches and evidence

Each job records its exact clean commit and source manifest, then verifies that
builds leave source/lockfiles unchanged. CI uses its dedicated checkout directly
instead of copying thousands of files; dirty direct-checkout runs are rejected.
Local acceptance retains immutable source copies by default. Build caches live outside the fresh evidence folder.
Keys include the actual Xcode build, architecture, dependency/vendor and source
hashes (including generated schemes), and lane. The v2 cache format enables
Xcode's native compilation cache, stores its CAS inside the saved cache root,
and disables IDE indexing for CI Xcode builds. Compiler cache diagnostics are
retained in each build log. Migration can restore an older dependency/build
cache, but saves new CAS progress under a v2 key. Related iOS lanes can restore each other's compiled work;
macOS and iOS caches remain separate. Successful compilation is saved even when
subsequent tests fail. Cancelled runs do not delay retirement to save a cache.

Phase timings record source preparation, toolchain queries, device inventory and
boot separately, with host load averages. The summary also records time from the
CI shell launch to source preparation, Python module initialization, source
verification and host CPU/memory capacity. macOS `/usr/bin/time -l` resource logs
record command CPU time, maximum resident memory, page faults and swaps. These
measurements distinguish cache hits from actual build savings.

Logs (including each fixture-backed lane's complete `<lane>-sshd.log`), source identity, phase/resource measurements, summaries and xcresults are uploaded for seven days on
success or failure. Failed method identifiers/assertions are printed immediately
in the job log. Cleanup touches only each job's disposable Simulator and generated
loopback fixture. New commits cancel superseded runs for the same PR or branch.
The quick jobs have a 35-minute infrastructure ceiling and acceptance jobs 45
minutes; these are failure bounds, not target durations. Each command retains
its own 30-minute deadline.

## Local reproduction

Run a single lane with fresh evidence outside the checkout:

```sh
python3 -B scripts/test-acceptance.py --lane macos-openssh \
  --output /private/tmp/remotefiles-macos-NEW_RUN
python3 -B scripts/test-acceptance.py --lane simulator-core \
  --simulator SIMULATOR_UDID --output /private/tmp/remotefiles-core-NEW_RUN
```

Other choices are `simulator-ui`, `voiceover`, `release-device-compile`, and the
combined `simulator` lane. Repeat `--lane` to select disjoint inventories; the
combined Simulator lane cannot be mixed with its core/UI subsets. Omit `--lane`
to retain the complete local acceptance run. Use `--allow-dirty` only when the
report should identify a working-tree snapshot rather than an exact commit.

## UI lane deadline regression

[PR #36](https://github.com/eyeb0l/RemoteFiles/pull/36) passed only on its second
UI attempt. Its tested source tree, toolchain and lane selection matched
[main run 40606036577](https://github.com/eyeb0l/RemoteFiles/actions/runs/40606036577),
which failed twice. This was not a merge-only source or scope change.

The UI lane previously ran `xcodebuild test`, sharing one 30-minute command
budget between compilation, test-host startup and all UI journeys. The passing
PR attempt needed 281 seconds before the first XCTest and 1,274 seconds for its
23 UI methods. Main took 761 and 637 seconds before the first XCTest; the runner
interrupted both attempts with methods still missing. The second main attempt
had passed every completed method before that interruption. A rerun could pass
or fail depending on preparation time without fixing the underlying budget.

The UI lane now follows the core lane's build-before-boot sequence and separates
build and execution deadlines. It retains the complete UI inventory, nine explicit
real-server skips, per-method deadlines, failure checks and 45-minute job ceiling.
A failed build never boots the simulator or executes cached products. Separate
`simulator-ui-build.log` and `simulator-ui.log` files and summary rows expose where
time was spent. There are no automatic retries.

Main's first attempt also hit the production HTML preview deadline. Its app log
recorded GPU and WebContent launches taking 13.25 and 13.62 seconds, consuming
most of the 15-second rendering allowance. The runners had three logical CPUs
and 7 GiB RAM; preparation load averages were in the hundreds after simulator
boot. Deferring boot removes overlap with compilation; this is a contention
mitigation, not proof of which background process caused the load. Production
rendering limits and preview assertions remain unchanged. Require full hosted
acceptance, including HTML/SVG journeys, on the fix and inspect the resulting
main run rather than treating a successful rerun as a diagnosis.

The first validation of this runner fix also exposed an unrelated setup race in
`testMemoryWarningAndInactivityReleaseAttributedKeysButRetainAnchor`: it timed
out waiting for asynchronous highlighting/layout to populate the cache, before
posting any memory warning. The cleanup test now mounts readable prose and seeds
distinct real cache entries directly before invoking the production notification
handler. It refills the cache before checking inactivity cleanup too, so both
paths must evict nonempty state while retaining the anchor. It does not require
80 repeated code blocks to finish layout within an eight-second setup wait.

The next hosted run completed UI compilation in 153 seconds and executed the
UI lane within its independent deadline; HTML, SVG, core, VoiceOver and Release
checks passed. One offline-reader journey still exceeded its three-minute
method allowance: app-wide link queries traversed the underlying library and
hit an XCTest remote-query timeout. Document-link queries now stay within the
reader scroll view, retaining the same visibility, navigation and position
assertions. Background checks accept both running and suspended background
states, while still rejecting a terminated or foreground app. No deadlines were
extended. The runner prints structured xcresult failures as well as log assertions,
so an interrupted test reports its primary timeout even if no completed-result
line was emitted and a later assertion failed during cancellation.

## WebKit cold-start regression

The first WebKit navigation in the core test host pays WebKit's cold start.
`testRendererDefensesBlockActiveMarkupAndResourceRequests` normally runs first.
On a just-booted Simulator under a host load average near 94, the GPU and
WebContent processes each took over 8 seconds to launch, and the networking
process took another 1.9 seconds. The local attack document then missed its old
10-second wait. On a quieter fresh Simulator the same navigation took 2.3
seconds, while compiling `SVGResourceBlocker` rules took 0.11 seconds. The test
now loads an inert SVG in the production configuration first, with a 60-second
cold-start bound. It then times the attack document against the production
15-second SVG deadline. After warm-up, that document finished in 0.6–0.7 seconds
on three fresh-Simulator lane runs. The `finished` precondition and the
script/resource assertions are unchanged. The test log prints
`RENDERER DEFENSES TIMING`, which separates rule, WebKit-start and document time.

<a id="why-the-first-workflow-took-nearly-an-hour"></a>
## Historical baseline: the first workflow

[The original main run](https://github.com/eyeb0l/RemoteFiles/actions/runs/39261247900)
spent 57 minutes 54 seconds in its Mac job. It ran everything serially on every
code or documentation change, even after a failure:

| Original command | Elapsed | Measured test execution |
|---|---:|---:|
| macOS/OpenSSH | 8m 38s | 25s for 129 tests |
| Combined iOS Simulator | 22m 18s | 2m 31s hosted core + 12m 04s UI journeys |
| VoiceOver | 14m 01s | 10m 26s for eight journeys |
| Release device compile | 6m 02s | compile only |

The commands total about 51 minutes; boot, toolchain/source/result preparation
and cleanup account for the remainder. Copying/hashing the source alone delayed
the first command by 2m 39s; CI now avoids that redundant copy while preserving
the before/after source guard. Dependencies and Debug/Release products
were cold, and the old cache action skipped saving because the job failed.
Consequently a failed test also forced later runs to repeat the expensive build.
The original default was too broad for ordinary PR validation.

The new policy removes UI/VoiceOver/Release from ordinary PRs, parallelizes
independent work, gates expensive work behind quick checks and preserves build
progress after failures. Cold builds still take longer than warm ones. Use each
job's timestamps and retained summary to measure actual elapsed time rather than
treating a compiler cache hit as proof that tests passed.

## Quick-run comparison baseline

[Main run 39311217923](https://github.com/eyeb0l/RemoteFiles/actions/runs/39311217923)
finished in 13m02s on `3e4c9851875412813cdf762b63be6cfb135acb50`:

| Critical-path phase | Time |
|---|---:|
| Workflow/repository/runner/checkout/toolchain/cache setup | 48s |
| Simulator creation and boot | 1m21s |
| Runner preparation | 2m54s |
| Fixture, build and test-host startup | 5m00s |
| 205 iOS methods (204 passed, one allowed skip) | 2m27s |
| Evidence, cleanup, cache save and completion | 32s |

The parallel macOS lane took 3m02s and passed 140 methods. Compare hosted runs
using this same inventory, a first run that populates the native compilation
cache, a warm rerun of the unchanged commit, and a one-test-file change. Report
cache state, build/test/boot phases and full workflow duration separately. Keep
full acceptance before merging CI/scheme changes and verify the resulting main
push as well. The implementation does not assert a speedup until those hosted
measurements exist; first-boot contention is a hypothesis to test.

## Jump-host fixture

The isolated OpenSSH launcher also starts a loopback bastion with its own host key and
an independent authorized identity. The main fixture port defaults to 22222; its bastion
uses the next port, or `REMOTEFILES_TEST_JUMP_PORT` when set. Reserve both when running
lanes locally in parallel. Hosted tests receive both ports through `TEST_RUNNER_` variables.
The bastion permits forwarding only to loopback test listeners. Both servers are stopped
on exit; `<lane>-sshd-jump.log` retains the bastion log beside the destination log.

## Local VoiceOver fixture state

Use a fresh disposable simulator for a full VoiceOver lane. The small-feature fixtures retain
installation and recent-entry state across app launches. Reusing their app container can start
with an already-installed mock public key or an already-removed seeded recent entry. A fresh
output directory alone does not reset that simulator state. Diagnose these failures before
rerunning the affected methods on a fresh device; retain both the original failure and rerun evidence.

The VoiceOver launcher supports macOS’s stock Bash when optional package or
compiler-cache settings are absent. Launcher regressions also check that argument
paths with spaces survive and that collecting lifecycle logs cannot turn a failed
Xcode run into success.

Disposable fixture projects rebase the app's `App/Info.plist` input to the source
checkout, along with their package and source references. The project-preparation
regression executes all four fixture launchers' preparation code and verifies both
app configurations still resolve the original plist, including checkout paths
with spaces. Test hosts retain their generated plists.
