# Cold-reader performance investigation

Measured 22 September 2026 with Xcode 27.0 (27A266a), Swift 6.4 and macOS
27.0 (26A428). This fixes synchronous syntax-highlighter startup on the main
thread and reduces the observed simulator reader stall. It does **not** establish
that all reader hitches or the preview's performance acceptance criteria are resolved.

## Follow-up: off-main runtime warm-up (19 October 2026)

Measured with Xcode 27.0 on the iPhone 18 Pro simulator (iOS 27.0). This reduces,
but does not remove, the residual simulator stall. No physical-device profile was
recorded for this change.

### What dominated

In the baseline, 75–88% of main-thread samples in the reader potential hang were in
`swift_conformsToProtocolMaybeInstantiateSuperclasses`: cold Swift conformance-cache
lookups. Callers were SwiftUI's stored-property `DynamicProperty` checks
(`DynamicPropertyCache.fields`), body-type resolution (`BodyAccessor.makeBody`, via
mangled-name requirement checks), and `Text` attribute-scope descriptions. JavaScriptCore
and Prism had no main-thread samples. An LLDB breakpoint on the runtime's cache insertion
counted 882 main-thread misses during one baseline reader open. Each one costs roughly
0.35 ms on the simulator. The app binary has only 2,675 conformance records, so the per-miss
cost is the scan over all loaded system images. Hardware may scan far less; that was not measured.

Loading an image that contains Swift conformances clears the whole runtime cache. When
XCTest attached, accessibility support loaded about 250 images. A warm-up run at launch was
therefore lost before the UI test opened a folder, so warm-up starts from the folder view.

### Change

- Textual: `StructuredText.prepareRendering(shouldContinue:)` runs on the caller's thread.
  For the default block views, styles and interaction modifiers, it resolves body types and
  `View`/`ViewModifier` conformances. It also checks their stored property types for
  `DynamicProperty`. It converts a one-character string through the SwiftUI and Textual
  attribute scopes and reflects four body fonts into the existing provider cache. See the
  [provenance](../Vendor/Textual/UPSTREAM.md).
- App: `ReaderWarmUp` does the same for the reader chrome, the document switch, the source
  view, inline images and Home's Recents section, then calls Textual. Each `FolderView`
  waits 1 s for its own first layout and then starts warm-up as a detached utility task.
  One run is in flight at a time, so a repeated run only hits caches. Leaving the folder
  within 1 s skips warm-up, and backgrounding the app cancels it between types.
- No view is created, no body or environment is evaluated, and nothing touches disk or the
  network. Types that are not listed are resolved on first display as before. Most remaining
  misses are SwiftUI-internal types, private Textual environment keys and closure-typed
  properties, which cannot be named here.

### Before and after

The build was Release with `ENABLE_TESTABILITY=YES`. Each run used this sequence:

1. Install the app and launch it once, discarding that first launch.
2. Launch a fresh `--demo` process and attach Time Profiler (`xctrace --attach RemoteFiles`, 45 s).
3. Run only `testBrowseReadRefreshAndReturn` with `TEST_RUNNER_REMOTEFILES_PROFILE_EXISTING_APP=1`.

Baseline (HEAD `e7ffec0`) and patched runs alternated, five of each. The measurement window
is 1.8 s from the UI test's synthesized tap on *Latest report*, aligned using the trace and
test start times.

| Reader open, 1.8 s window | Baseline | Warm-up |
| --- | ---: | ---: |
| Runs with a reader potential hang | 5 of 5 | 2 of 5 |
| Potential-hang duration | 368–530 ms (median 488) | 262 and 281 ms; none in 3 runs |
| Median main-thread busy samples (≈1 ms each) | 660 | 459 |
| Median main-thread samples with a conformance-lookup leaf | 326 | 144 |

The folder open, measured over 1.5 s from the *Projects* tap, was unchanged. Median busy
samples were 384 before and 390 after. Folder potential hangs occurred in both builds (3 of 5
and 5 of 5), and every one began before warm-up ran. Warm-up itself took 225–291
background-thread samples, about 1 s after the folder appeared.

An earlier batch of five pairs started warm-up immediately when the folder appeared. It
recorded 418–557 ms baseline reader hangs against one 322 ms hang in five patched runs. That
warm-up could overlap the folder's own first layout, which is why the 1 s delay was added.

These are simulator results under XCTest automation, which loads extra images. They show
less main-thread work and fewer, shorter reader hangs. They do not establish the sub-200 ms
cached-display target or any improvement on a physical device.

### Regression checks

- `swift test --package-path Vendor/Textual` passed 5 tests. Two are new warm-up tests: one
  covers off-thread, complete and repeatable runs, and one checks that it stops when asked.
- `swift test` ran 129 tests: 13 skipped, 0 failures.
- `REMOTEFILES_TEST_PORT=22422 scripts/test-openssh.sh xcodebuild … test` ran on the
  iPhone 18 Pro simulator:
  - Hosted: 194 tests, 2 skipped (device-only file protection and the latency benchmark).
  - UI: 23 tests, 14 passed and 9 opt-in real-server tests skipped, 0 failures.
- `ReaderWarmUpTests` covers three behaviours:
  - warm-up runs off the main thread, coalesces runs and repeats cheaply;
  - it stops between types when cancelled;
  - a rendered Markdown document's pixels are identical before and after warm-up.

Evidence (not committed) is in `/private/tmp/remotefiles-reader-evidence/`:

- `final2-{base,warm}-N.trace` with `-hangs.xml`, `-samples.xml`, `-test.log` and `.xcresult`.
  Warm run 2 was lost to an `xctrace` save hang, and run 6 replaces it.
- The earlier `final-*` batch.
- LLDB miss logs: `conf2-conformances.tsv` (baseline) and `conf11-conformances.tsv` (patched).
- Test logs: `ios-tests.log`, `swift-test.log` and `textual-tests.log`.

## Cause and implementation

The original Debug and Release recordings showed approximately 0.6 seconds of
cold-reader main-thread unresponsiveness. Main-thread samples implicated SwiftUI
view/type metadata and text layout, plus Textual's first JavaScriptCore/Prism
initialization. Markdown preparation already ran on its own actor; this was not
an SFTP or document-parsing stall.

Textual's shared tokenizer was an actor with a synchronous initializer. That
initializer still executed on its caller, so first access from SwiftUI created
a JavaScript context and loaded/evaluated Prism on the main thread before the
actor hop. The context is now a lazy, actor-isolated property first accessed by
`tokenize`. Initialization remains once per tokenizer, serialized by the actor;
failure still returns plain code tokens. Highlighting is retained.

The heterogeneous Markdown block switch now returns an `AnyView` explicitly at
each branch, avoiding a single nested conditional view type spanning every block
implementation. Type erasure is confined to that existing block boundary.
Block IDs, formatting, text selection and overflow behavior remain unchanged. The measurements below cover both changes together and do not isolate
the type-erasure change's contribution.

The small local fork is based on the exact original Textual commit; its MIT
license and Prism resources are retained. Only two production source files differ
from that upstream checkout. See [provenance](../Vendor/Textual/UPSTREAM.md).

## Before and after

| Measurement | Original | Patched |
| --- | ---: | ---: |
| iPhone 18 Pro simulator, iOS 27.0, Release: cold-reader potential-hang duration | 627.30 ms | 314.92 ms |
| Same simulator: reader-interval main-thread leaf samples in Swift protocol-conformance lookup | 189 | 172 |
| Physical iPhone 17 Pro, iOS 27.0 (24A437): potential hangs over 250 ms during 60-second journey | 0 | 0 |
| Physical iPhone: inclusive tokenizer main-thread samples | 38 | 0 |
| Physical iPhone: inclusive tokenizer background-thread samples | 1 | 39 |

These are individual before/after traces, not a statistically established 50%
speedup. CPU samples were approximately 1 ms; inclusive counts overlap and are
not elapsed-time allocations. The device result demonstrates moving work off the
main thread, not eliminating its CPU cost. The original simulator stall did not
reproduce on the physical phone, so no 0.6-second iPhone improvement is claimed.

Both physical builds used optimized Release with `ENABLE_TESTABILITY=YES`,
required by the hosted core tests' `@testable` imports. Simulator main-app builds
used ordinary Release. No compilation ran during either recording. Each journey
used a fresh process and the same demo report. The physical UI test activated the
already launched process so Instruments retained its attachment, then exercised
Home → Projects → report → Source → Rendered → Refresh → Projects → Home.

The simulator recording also included an earlier, separate navigation/runtime
startup event: 524.84 ms before and 494.99 ms after. It must not be mistaken for
the reader event. The residual 314.92 ms reader interval is dominated by Swift
protocol-conformance/metadata work and SwiftUI text/layout initialization. The
patch does not meet a universal no-hitch target. Representative large-document,
1,000-entry directory, cellular/Tailscale and sub-200 ms cached-display acceptance
remain outstanding.

## Regression checks

- Optimized simulator and signed physical-device builds passed. The patched app
  remains installed; the phone locked after testing, preventing the final normal relaunch.
- Final physical run: **27 core tests + 2 UI tests passed, zero failures**;
  **5 real-SFTP tests skipped** because the fixture is host-local.
- Three focused Textual tests passed: exact Swift token output, unsupported-language
  fallback, and eight concurrent first-use requests preserving Unicode text and
  keyword highlighting.
- The patched simulator reader was visually checked at the top and at its table
  and highlighted code block; rendered/source switching and scrolling succeeded.
- Root and Xcode dependency lockfiles retain matching arrays of 11 remote pins;
  Textual is now local and its original revision is recorded in its provenance.

## Reproduction and local evidence

Run the tokenizer regression tests:

```sh
swift test --package-path Vendor/Textual
```

Build and test the phone with the existing signing configuration:

```sh
xcodebuild build-for-testing -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -configuration Release -destination 'id=00008150-000434162182401C' \
  -derivedDataPath DerivedData-device -allowProvisioningUpdates ENABLE_TESTABILITY=YES
xcodebuild test-without-building -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -configuration Release -destination 'id=00008150-000434162182401C' \
  -derivedDataPath DerivedData-device -parallel-testing-enabled NO \
  -collect-test-diagnostics never
```

For profiling, install the corresponding Release app, terminate any prior
process, launch `dev.iris.RemoteFiles --demo`, and attach Time Profiler before
opening the report. In a separate terminal drive only the browse UI test using
`TEST_RUNNER_REMOTEFILES_PROFILE_EXISTING_APP=1` and
`-only-testing:RemoteFilesUITests/RemoteFilesUITests/testBrowseReadRefreshAndReturn`.
The environment override only affects the test harness, not app behavior.

Temporary evidence (not committed binary artifacts):

- `/private/tmp/remotefiles-device-before.trace` and `remotefiles-device-after.trace`:
  60-second Time Profiler recordings; adjacent `-hangs.xml` and `-samples.xml` exports.
- `/private/tmp/remotefiles-sim-before.trace` and `remotefiles-sim-after.trace`:
  40-second recordings; adjacent `-hangs.xml` and `-samples.xml` exports.
- `/private/tmp/remotefiles-device-before.xcresult` and `remotefiles-device-after.xcresult`:
  successful profiled UI journeys.
- `/private/tmp/remotefiles-performance-final.xcresult` and `.log`:
  final full device tests, completed 14:40:42 local time.
- `/private/tmp/remotefiles-textual-tests.log`: focused tokenizer tests.

Export tables with `xcrun xctrace export --input TRACE --xpath
'/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' --output FILE`;
use schema `time-profile` for sample stacks. Resolve XML `ref` attributes against
IDs and exclude sentinel rows without `tagged-backtrace` when counting samples.
