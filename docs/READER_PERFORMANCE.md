# Cold-reader performance investigation

Measured 22 September 2026 with Xcode 27.0 (27A266a), Swift 6.4 and macOS
27.0 (26A428). This fixes synchronous syntax-highlighter startup on the main
thread and reduces the observed simulator reader stall. It does **not** establish
that all reader hitches or the preview's performance acceptance criteria are resolved.

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
