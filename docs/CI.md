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

- **Acceptance / simulator-ui-shard-1** and **simulator-ui-shard-2**: disjoint halves
  of the complete UI inventory, on separate runners and disposable simulators.
  Sorted method identifiers alternate between the two shards, so newly inventoried
  methods are included automatically. Explicit real-server opt-in methods remain skipped.
- **Acceptance / voiceover**: actual VoiceOver speech, focus and custom-action discovery
  against disposable fixture entry points using production views.
- **Acceptance / release-device-compile**: unsigned optimized iOS compilation.

The existing **Acceptance / simulator-ui** check is an aggregate gate on Linux.
It succeeds only when both UI shards succeed; failed, cancelled or skipped shards
cannot satisfy it. It does not wait for VoiceOver or Release compilation. Each
shard builds the full UI target, then executes only its exact selected methods and
checks those results against its selected inventory. Together they cover each UI
method exactly once, retaining missing/extra/duplicate-result, skip and xcresult
validation. A shard report is explicitly partial UI evidence.

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

Across these six Mac jobs, the inventories cover the original full acceptance
suite. Each job reports only its selected lane; a partial report never claims
full acceptance. Physical iPhone and real-server participation remain separate.
No signing secrets, saved connections or personal SSH keys are required.

## Caches and evidence

Each job records its exact clean commit and source manifest, then verifies that
builds leave source/lockfiles unchanged. CI uses its dedicated checkout directly
instead of copying thousands of files; dirty direct-checkout runs are rejected.
Local acceptance retains immutable source copies by default. Build caches live outside the fresh evidence folder.
Keys include the actual Xcode build, architecture, dependency/vendor and source
hashes (including generated schemes), lane and optional UI shard. Artifact names
also include the shard, so concurrent UI jobs cannot overwrite each other's evidence.
The v2 cache format enables
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
python3 -B scripts/test-acceptance.py --lane simulator-ui --ui-shard 1 \
  --simulator SIMULATOR_UDID --output /private/tmp/remotefiles-ui-1-NEW_RUN
```

Other choices are `simulator-ui`, `voiceover`, `release-device-compile`, and the
combined `simulator` lane. Repeat `--lane` to select disjoint inventories; the
combined Simulator lane cannot be mixed with its core/UI subsets. Omit `--lane`
to retain the complete local acceptance run. Use `--allow-dirty` only when the
report should identify a working-tree snapshot rather than an exact commit.
`--ui-shard 1` or `--ui-shard 2` requires exactly `--lane simulator-ui`;
omit it to run the whole UI lane locally. Run both shards for full UI evidence,
using separate fresh output directories and never running two jobs on one device.

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

PR #39's [run 40996701531](https://github.com/eyeb0l/RemoteFiles/actions/runs/40996701531)
then exhausted the execution-only 1,800-second budget twice on the same source.
Attempt 1 completed 24 UI methods and nine expected skips before interrupting
the final wrap-lines journey while it was progressing. Attempt 2 completed 21
UI methods and nine expected skips before interrupting the saved-index journey,
also without an assertion or per-method timeout. The newly completed PDF/OCR
journey passed in both attempts. The unchanged wrap-lines test passed locally.
The expanded UI suite therefore now runs in the two independent shards above.
The 30-minute command, 180/240-second per-method and 45-minute Mac job limits
remain unchanged; no method, assertion or skip policy was removed and there are
no automatic retries.

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

The demo reader and image-viewer speech journeys launch their fixture with VoiceOver
already enabled. Enabling it after the screen has settled can leave the first
`currentSpeech()` call with `No speech available`. Launch alone also does not guarantee
focus on an asynchronously loaded image: the image journey uses the same tap, speech
verification and double-tap helper as JSON/SVG navigation. After closing the system
share sheet it waits for Close to disappear before starting the existing backward
traversal to Done. The final automatic focus return to the invoking image is still
asserted. Retain the speech and traversal assertions when diagnosing these setup failures.

The VoiceOver launcher supports macOS’s stock Bash when optional package or
compiler-cache settings are absent. Launcher regressions also check that argument
paths with spaces survive and that collecting lifecycle logs cannot turn a failed
Xcode run into success.

Disposable fixture projects rebase the app's `App/Info.plist` input to the source
checkout, along with their package and source references. The project-preparation
regression executes all four fixture launchers' preparation code and verifies both
app configurations still resolve the original plist, including checkout paths
with spaces. Test hosts retain their generated plists.

## UI journey method deadlines

[Main run 41046564410](https://github.com/eyeb0l/RemoteFiles/actions/runs/41046564410)
failed UI shard 1 while all other lanes passed. Its second attempt reached the
heading journey's final screenshot at 179 seconds, then exceeded the 180-second
method allowance during teardown. The saved-index journey was still progressing
through its final deletion/reopen assertions at that deadline; the native Files
picker alone had taken about 30 seconds. Neither failure was an assertion about
production behavior.

Find plus same-document heading navigation and outline plus linked-document
heading navigation now run as independent methods. Outline queries and swipes
stay within its collection view. Saved-index persistence/deletion and exporting
an original from a reopened index also run separately; each builds and reopens
its own synthetic snapshot. All original assertions remain covered. The complete
method inventory is still distributed across both UI shards, with unchanged
180/240-second method, 30-minute command and 45-minute job limits. No skip or
retry was added.

The first hosted validation of this split also exposed a core-test setup race in
`TextualNavigationRevealTests`: after changing the fixture's `.id`, its wait could
accept the old tall scroll view before SwiftUI replaced the subtree. A fixed
300-millisecond sleep did not establish that the replacement document scroll
had usable geometry, and its unwrap failed. The test now waits for a different document
scroll view using the original 12-second bound, then retains the settling delay
and verifies that the new view remains mounted at the top. Exact target-range,
horizontal visibility and fulfilled-request assertions are unchanged.

The next validation passed the heading journeys in 84 and 55 seconds, reopened
index export in 151 seconds, and index persistence/deletion in 156 seconds.
It also exposed the combined live PDF/OCR and saved-index journey: after 130
seconds of successful assertions, XCTest spent another 60 seconds awaiting an
animation-idle notification on the return from PDF preview. Live extraction
options/results and saved extraction/build/preview/deletion now run independently,
each opening its own synthetic sample folder. The saved-index form already
defaults PDF extraction on and explicitly enables OCR, so it does not depend on
live-search options. All original assertions and deadlines remain in place.
The saved form also waits up to five seconds for the OCR switch's accessible
value to become enabled before building. A focused iOS 27.2 run read its old
value immediately after the tap; temporary before/after screenshots confirmed
the switch updated when given time to settle. The enabled-state assertion is
retained, and the diagnostic screenshots are not part of the final test.

## Post-merge UI follow-up

[Main run 41086051385](https://github.com/eyeb0l/RemoteFiles/actions/runs/41086051385)
passed core, macOS, VoiceOver and Release validation after PR #43, but exposed two
other UI checks. The single-file offline journey spent 132 seconds pinning and
opening its document, then exhausted the method budget during accessibility
queries before its link, foreground, relaunch and removal checks were complete.
Link navigation and lifecycle/removal now run independently, each preparing its
own saved copy. Reader queries use the first matching scroll view and keep
heading lookups inside it; every original assertion remains covered.

The SVG check counted zero purple pixels even though its retained screen recording
showed the complete painted fixture during that interval. It now samples the same
full-screen capture API used for test attachments, and keeps the bitmap buffer
pinned while CoreGraphics draws into it. The existing 5,000-pixel threshold and
ten-second paint bound remain unchanged. The rendered screenshot is attached
before asserting, so any future mismatch retains the exact visible screen.

Focused follow-up validation also caught the generic background predicate timing
out while its failure message reported the accepted running-background state.
Background checks now use XCTest's native state wait, then explicitly assert
running-background or suspended-background. The five-second bound is unchanged;
a foreground or terminated app still fails.

The follow-up PR also caught content-search setup asking XCTest for hittability
while its entire launch-time accessibility hierarchy still had infinite origins
and zero sizes. The shared tappability wait now requires finite, positive element
geometry before evaluating hittability. It still requires an actually hittable
element within the same timeout; invalid geometry never counts as ready.

## HTML anchor fixture presentation

[Main run 41116836414](https://github.com/eyeb0l/RemoteFiles/actions/runs/41116836414)
loaded the visual-block HTML fixture, but its initial native scroll was reset to
zero before anchor capture. The retained DOM was complete and 3,000 pixels high;
native and DOM offsets were both zero. Local baseline traversal-budget checks
also reproduced this initial-scroll failure.

The bare HTML fixture now waits for an after-screen-updates WebKit snapshot
before returning to its caller. This synchronizes its initial presentation before
the test establishes a nonzero reading position. Initial-offset, traversal-limit,
anchor and post-resize assertions remain unchanged, as do all existing deadlines.

## Console back-pressure and readiness fixes

Several journeys failed intermittently on `main` and unrelated PRs in late October.
Each one was investigated before any rerun:

- **UI snapshot timeouts.** Content search, adaptive workspace and linked-folder
  journeys timed out while XCTest asked a just-launched or idle app for elements;
  queries took 14–31 seconds and logged `(retry 1)`/`(retry 2)`. The spindump that
  XCTest captured in [run 41228358818](https://github.com/eyeb0l/RemoteFiles/actions/runs/41228358818)
  showed the app's main thread blocked in `writev` to its stderr pseudo-terminal while
  serving the query. XCTest's in-app automation logs every attribute it fetches (about
  9 MB per journey), and Xcode's `OS_ACTIVITY_DT_MODE` mirrors that output to stderr.
  xcodebuild drains the terminal through its main thread, which runs at utility priority
  on CI runners and was runnable but starved. Pausing xcodebuild locally reproduced the
  same failure line and retries. UI-tested apps now launch with `OS_ACTIVITY_DT_MODE=NO`;
  the messages still reach the unified log. With the same pause, queries answered in
  0.14 seconds and the journey passed.
- **VoiceOver JSON speech.** The preview opened, but VoiceOver had not yet moved focus
  off the activated row, so traversal skipped to the end of the JSON. Opening a row now
  waits up to 10 seconds for the focused utterance to change before reading speech.
- **Offline reader Back position.** The rich Markdown renderer restored its saved offset
  as soon as `render()` resolved, while the native scroll view still had the empty
  template's 772-point height. A later WebKit commit could reset that offset, and scroll
  tracking then saved the top. Restoration and tracking now wait until native geometry
  covers the rendered document, as the HTML reader does. A hosted regression failed 4 of
  5 runs before the change. The offline lifecycle test waits for the reader's progress
  indicator to disappear before scrolling. Its first reader also gets a 60-second bound
  for WebKit's process cold start, measured at 23–28 seconds on a loaded Mac; later steps
  keep 15 seconds.
- **Saved-index OCR budget.** On an Apple silicon Mac with a purged Neural Engine cache,
  Vision's first model compile used the index's whole 30-second budget. The boundary test
  now compiles the model once before its timed build. Virtual CI Macs use the fast model
  and were unaffected.
- **Static HTML defenses.** After #52 merged, main's
  [run 41280678027](https://github.com/eyeb0l/RemoteFiles/actions/runs/41280678027)
  failed `testHTMLCannotRunDocumentScriptsOrLoadResources`: its document did not finish
  within the test's 15-second wait, although its DOM was readable afterwards and the next two
  HTML tests passed in 1.6 and 1.3 seconds. The host log shows a second WebContent process
  starting 12.6 seconds into the test; the attack document's cross-site frame is the likely
  reason, though the log does not prove it. Launches of that length were recorded on these
  runners before. The wait was a hang guard, not the production deadline, which
  `HTMLContentView` keeps at 15 seconds and the UI lane's HTML journey still exercises. The
  three `HTMLDisplayTests` now wait the same 60-second
  cold-start bound as the SVG defenses, print `HTML DISPLAY TIMING`, and report a failed or
  terminated navigation by reason instead of as a timeout.
- **Search helper allowance.** The same run failed
  `testBoundedSearchExecClosesOnOutputOverflowCancellationAndDeadlineWithoutClosingSFTP`
  with an uncaught `timedOut` from its final command. The fixture `sshd` log shows
  authentication taking 2.5 seconds and `printf` 1.5 seconds; the Python search helper then
  missed the test's 5-second allowance, which production never uses: `serverSearch` allows
  the 30-second search time limit plus 16 seconds. The output-bound and helper commands now
  get that production allowance. The cancellation and deadline commands keep their own
  5- and 1-second bounds and their 2- and 3-second return-time assertions.
- **HTML rendering guard.** `testHTMLRenderedSourceAndRefresh` hit the app's 15-second
  HTML rendering guard on main twice: on the first render in
  [run 41268255736](https://github.com/eyeb0l/RemoteFiles/actions/runs/41268255736), and after
  returning from Source in attempt 1 of
  [run 41317772450](https://github.com/eyeb0l/RemoteFiles/actions/runs/41317772450). The
  recording shows the spinner for the whole 15 seconds; the first render of that run took
  about 11 seconds, and attempt 2 rendered in about 7 and 5 seconds. Each rendered view starts
  a new WebKit content process, and launches of 13 seconds or more were recorded on these
  runners. This revisits the decision above to keep production rendering limits: the guard
  catches hung renders, and 15 seconds also failed slow but healthy ones. It is now
  30 seconds, and the journey's three render waits are 35 seconds so the app, not the test,
  decides. To reproduce, each new WebContent process of a local iOS 27.2 simulator was paused
  with `SIGSTOP` for 13 seconds, and WebKit then logged 14.6–15.2-second launches. The
  unchanged journey failed its first render with the app's "could not finish rendering"
  message. After the change all three renders finished in about 22 seconds and the journey
  passed. With 20-second pauses the change still failed the second render: under memory
  pressure WebKit had also relaunched its network and GPU processes, and that render needed
  about 32 seconds. The guard covers the launches recorded on hosted runners, not unlimited
  ones. SVG keeps 15 seconds and Markdown 20 seconds; neither has failed on main.

HTML reading-position timeouts were seen only while several local simulator jobs ran;
those methods took 75–189 seconds each. Hosted runs took at most 5.1 seconds, so their
15-second waits are unchanged. No lane budget, allowed skip or retry changed.

## Offline reader and share sheet waits

On 1 November, [PR #56](https://github.com/eyeb0l/RemoteFiles/pull/56) failed UI shard 1
in all three attempts of [run 41335073198](https://github.com/eyeb0l/RemoteFiles/actions/runs/41335073198),
each time in a different method that the PR did not touch. Each was investigated
before a rerun:

- **Offline copy after relaunch.** In attempt 2,
  `testOfflineCopyOpensAfterDisconnectAndRelaunchAndCanBeRemoved` relaunched the app,
  opened the saved copy, and still found `Opening saved copy…` when its 15-second wait
  ended. The UI hierarchy captured at the failure showed no error. Earlier opens of the
  same copy in that run took 1–3 seconds. Reading a saved copy (lease, fingerprint check,
  text preview and heading index) has no app deadline, so the test's wait was the only
  bound, and the first read in a fresh process paid that process's cold start on a loaded
  runner. That wait is now 60 seconds, the cold-start bound the offline lifecycle test
  already gives its first reader. The other offline reader waits stay at 15 seconds.
- **Share sheet contents.** In the same attempt, `testOfflineShareOriginalPresentsAndCancels`
  found the share popover within 1 second, but its `ShareSheet.RemoteContainerView` was
  still empty when the 5-second wait for `Save to Files` ended. That list comes from a
  system service outside the app. The cell wait is now 30 seconds; the popover's own
  15-second wait is unchanged.
- **App termination.** Attempt 1's `testDemoAudioAndVideoHaveNativePlaybackControls`
  finished its steps in 55 seconds, then XCTest's own `Tear Down` took 131 seconds to
  terminate the app and exceeded the 180-second method allowance. Its spindump
  recorded no samples. In attempt 3, launching
  `testKeyDetailsShowFingerprintAndPublicKeyWithoutAddedHyphens` spent 65 seconds
  terminating the previous instance and failed with `Failed to terminate`. The app
  registers no termination work (no `willTerminate` handler or background task), so the
  test code cannot shorten these steps. Treat a termination failure as runner
  infrastructure once its log shows this pattern.

Neither wait change was reproduced locally: pausing the app or the simulator's sharing
services with `SIGSTOP` made XCTest's queries block until they resumed, and then
succeed, rather than letting the wait run out. Both changed methods pass locally. No lane
budget, allowed skip or retry changed.

## Runner load and post-boot settling

Measured lanes now keep `<lane>-load.log`: every 15 seconds, the host's load averages
and its busiest processes. Each lane's evidence also records a `host_load` summary,
which the job log prints. The baseline in
[run 41360147250](https://github.com/eyeb0l/RemoteFiles/actions/runs/41360147250)
attempt 2 (three-vCPU `xcode-27-arm64` runners) showed:

- **The simulator boot is the load spike.** The 1-minute load was 400–600 in the first
  minutes after a lane's simulator booted. It fell to about 40–150 within 10–15 minutes
  while tests kept running. The busiest processes early on were iOS widget
  extensions and system daemons (`NewsToday2`, `PassbookLockedWidgetsExtension`,
  `fitnesscoachingd`, `profiled`) together with both `diagnosticd` instances.
- **Steady consumers.** Over whole lanes, `diagnosticd` averaged 43–53% of a CPU and
  `apsd` 13–15%, next to the app under test (45–53%). Nothing in the repository streams
  logs. Setting `TEST_RUNNER_OS_ACTIVITY_DT_MODE=NO` for the core test host did not
  change `diagnosticd`'s CPU use locally.
- **Screen recording was not a significant cost.** XCTest's automatic screen recording
  for UI tests did not appear among the busiest processes: the simulator's render
  services used 4–5%. The capture format is unchanged.

Core and UI lanes boot their simulator just before testing, so tests started inside
that spike. After boot, CI now waits until the 1-minute load is at most 40 per
logical CPU (120 on these runners), for at most 8 minutes, as the
`simulator-settle` phase. The wait never fails a lane; the evidence records each
sample and whether it settled. Local runs without `--ci-compilation-cache` skip it.
The VoiceOver lane boots before its build, so the spike overlaps compilation; its
mean load was about half that of the other simulator lanes, and it is unchanged.

Larger runners with more CPUs and GPU acceleration would address the load itself.
That is a billing choice outside this repository.
