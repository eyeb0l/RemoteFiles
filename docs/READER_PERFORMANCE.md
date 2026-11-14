# Cold-reader performance investigation

Measured 22 September 2026 with Xcode 27.0 (27A266a), Swift 6.4 and macOS
27.0 (26A428). This fixes synchronous syntax-highlighter startup on the main
thread and reduces the observed simulator reader stall. It does **not** establish
that all reader hitches or the preview's performance acceptance criteria are resolved.

## Markdown preparation: one parse (14 November 2026)

Measured on a MacBook Air (M3, 8 cores, 16 GB) with macOS 27.2.1 and Xcode 27.2, in a release
build. No simulator or iPhone figures were taken: expect the same proportions on a phone, not the
same seconds.

**What opening a document parsed.** `ReaderNavigationState.prepare` builds the reader's
`DocumentTextIndex`, which parsed the text with `AttributedString(markdown:)`. `DocumentContentView`
reused the index's parts, but then parsed the text again, with source positions, for
`EnhancedMarkdownPolicy.requiresEnhancedRendering` whenever it held `$`, `<`, `\` or `mermaid`.
Most READMEs do: one `<` in a code span is enough. It also prepared a document again when the limits
had refused it after parsing, only to learn that it failed. Now the index takes source positions when
that pre-check passes, decides the renderer, removes the positions (the runs they split join again,
and the document equals an ordinary parse's) and applies the policy. The content view takes the
index's parts, renderer choice and refusal. A content view without a matching index, as in tests and
fixtures, builds an index of its own.

| Path | Parses before | After |
| --- | ---: | ---: |
| Live or offline reader, text holding `$`, `<`, `\` or `mermaid` | 2 | 1 |
| Live or offline reader, text holding none of them | 1 | 1 |
| Document refused after parsing (too many runs, too deep) | 2 | 1 |
| Document refused before parsing (markers, table width) | 0 | 0 |
| Content view with no matching index, text holding one of them | 2 | 1 |

Counted with a copy of the core in which a counter wraps both `AttributedString(markdown:)` calls,
driven through the calls the reader makes, for every case below.

**Method.** A throwaway SwiftPM executable, not committed, depends on this package by path and is
built with `swift build -c release`. Each case and operation runs in a process of its own, three
times. The table gives the median wall time of the operation and the process's lifetime peak
physical footprint (`proc_pid_rusage`, `ri_lifetime_max_phys_footprint`), which includes 3 to 10 MiB
present before the document exists. **Open** is what the reader does: build the index, then what the
content view does with it (before: the renderer check, the scan for links to confirm and, for a
refused document, preparing it again). **Stops** cancels preparation 200 ms after it starts and
times the return, including those 200 ms.

| Case | Content | KiB | Runs |
| --- | --- | ---: | ---: |
| `readme-300k`, `readme-1900k` | Headings, prose with inline formatting and `Array<String>` in code, links, lists, tasks, code blocks, tables, some images | 300, 1,900 | 11,866, 74,688 |
| `prose-escapes` | Paragraphs with a `\\` and `` `a<b>` ``, so the renderer check reads every run | 1,899 | 135,738 |
| `runs` | `*a* ` × 99,990: just under the run limit | 390 | 199,979 |
| `links` | `[a](https://a.io)b ` × 99,990 | 1,855 | 199,980 |
| `markers` | `**a** ` × 62,490: just under the marker limit | 366 | 124,979 |
| `table` | 254 columns (255 bars) × 781 rows: under the bar and run limits | 389 | 198,374 |
| `nesting` | Paragraphs inside 31 quotes, to the 2 MiB cap | 2,046 | 16,124 |
| `images` | `![a](i.png) ` × 99,990: all but 128 become alternative text | 1,171 | 199,979 |
| `tasks` | `- [ ] a` × 124,990 | 976 | 124,990 |
| `brackets` | `[a ` × 249,990: unclosed, just under the marker limit | 732 | 1 |
| `table-refused` | 254 columns × 961 rows: refused for its runs after parsing | 479 | 244,094 |
| `links-refused` | `[a](u)b ` × 249,990: one counted marker gives two runs; refused after parsing | 1,953 | 499,980 |

| Case | Parse alone | Open before | Open after | Stops before | Stops after |
| --- | ---: | ---: | ---: | ---: | ---: |
| `readme-300k` | 0.12 s, 18 MiB | 0.32 s, 34 MiB | 0.20 s, 26 MiB | 0.21 s | 0.21 s |
| `readme-1900k` | 0.79 s, 100 MiB | 2.12 s, 172 MiB | 1.31 s, 130 MiB | 0.95 s | 0.96 s |
| `prose-escapes` | 1.28 s, 144 MiB | 3.23 s, 243 MiB | 1.97 s, 204 MiB | 1.43 s | 1.57 s |
| `runs` | 1.71 s, 193 MiB | 2.10 s, 193 MiB | 2.07 s, 193 MiB | 1.88 s | 1.67 s |
| `links` | 1.80 s, 195 MiB | 2.75 s, 195 MiB | 2.52 s, 195 MiB | 2.13 s | 1.91 s |
| `markers` | 1.04 s, 122 MiB | 1.30 s, 122 MiB | 1.26 s, 122 MiB | 1.15 s | 1.23 s |
| `table` | 2.39 s, 274 MiB | 2.85 s, 274 MiB | 2.81 s, 274 MiB | 2.63 s | 2.43 s |
| `nesting` | 0.14 s, 40 MiB | 0.32 s, 42 MiB | 0.20 s, 41 MiB | 0.21 s | 0.27 s |
| `images` | 1.82 s, 187 MiB | 4.30 s, 218 MiB | 4.07 s, 218 MiB | 3.66 s | 1.84 s |
| `tasks` | 1.33 s, 283 MiB | 3.97 s, 283 MiB | 3.38 s, 283 MiB | 3.17 s | 1.32 s |
| `brackets` | 0.07 s, 105 MiB | 0.11 s, 105 MiB | 0.07 s, 105 MiB | 0.20 s | 0.20 s |
| `table-refused` | 2.96 s, 337 MiB | 6.04 s, 337 MiB | 2.99 s, 337 MiB | 3.03 s | 3.04 s |
| `links-refused` | 4.73 s, 461 MiB | 9.26 s, 461 MiB | 4.62 s, 461 MiB | 4.76 s | 4.68 s |

A document that finishes within 200 ms stops at its end either way. **Stops after** was measured
before the pre-check change below, which `nesting` still paid then. The parse-alone figure for
`links-refused` is a single run.

**Where the time goes.** Foundation's parse is most of every case, and it alone sets the peak: in
every large case but `images` the parse's own footprint is within 2 MiB of the whole preparation's.
Parsing with source positions costs 10 to 35% more time and 10 to 40% more memory (`table`: 2.73 s
and 375 MiB), so the index asks for them only when the pre-check passes. After the parse, 200,000 runs cost about 0.3 s
of passes over them, each bare enumeration about 55 ms; merging passes would save at most about
0.1 s and wasn't done. Two policy steps cost as much as the parse: every image after the 128th
becomes its alternative text and every task marker a checkbox, each an `AttributedString` edit of
14 to 19 µs whatever the document's size (1.86 s for 99,862 images, 1.78 s for 124,990 tasks).

**Also changed.**

- **Cancellation.** Preparation checks before the parse, after it and through each pass. Cancelled
  200 ms in, `images` stops at 1.84 s instead of 3.66 s and `tasks` at 1.32 s instead of 3.17 s: the
  end of the parse, which cannot be interrupted. A cancelled index throws instead of recording the
  document as refused.
- **Links to confirm.** `ExternalLinkPolicy.linksNeedingConfirmation` ran on the main actor after
  preparation: 0.32 s for `links` and 0.05 s for `readme-1900k`. The index finds them on its own task.
- **Renderer pre-check.** The locale-aware search for `mermaid` took 0.12 s on 2 MiB holding no `$`,
  `<` or `\`. One pass over the bytes rules the rich renderer out first, in 3 ms, when none of those
  characters, `&` or the word in any ASCII case appear; without them the full check can only say no.

**Tried and rejected.**

- Rebuilding the string once from pieces instead of one `replaceSubrange` per image or task:
  1.83 s for `images` (0.49 s to build the replacements, 1.34 s to append) against 1.86 s, and
  1.85 s for `tasks` against 1.92 s, each including finding what to edit. Appending costs about what
  replacing does.
- Editing through the character view, which keeps the run's attributes: 1.70 s for `tasks`, 2.29 s
  for `images`.
- Parsing in pieces to lower the peak: block structure, link reference definitions and the
  identities that group headings and list items span the whole document, so the output would change.
  Not attempted.

**The limits: a proposal, not changed here.** The worst cases measured are 2.8 s and 274 MiB
(`table`) or 4.1 s (`images`) for a document the limits accept, and 4.6 s and 461 MiB for one
refused after parsing (`links-refused`). Real documents are far from either. Of 260 Markdown files
over 16 KB on the measuring Mac (changelogs, READMEs and documentation up to 1.0 MB), the most
demanding has 47,750 markers (a 1.0 MB changelog) and the most runs 28,862 (a 0.9 MB changelog).
Scaled to the 2 MiB cap, the densest would have about 100,000 markers and 65,000 runs. With
`maximumMarkers` at 125,000 and `maximumRuns` at 100,000, none of them would be refused, and the
same constructions would cost at most:

| Case at the proposed limits | Time | Peak |
| --- | ---: | ---: |
| Links, refused after parsing (`[a](u)b ` × 124,990: 249,980 runs) | 2.32 s | 232 MiB |
| Images (`![a](i.png) ` × 49,990) | 1.96 s | 119 MiB |
| Tasks (× 62,500) | 1.59 s | 143 MiB |
| Table (254 columns × 391 rows) | 1.39 s | 139 MiB |
| Runs (`*a* ` × 50,000) | 1.01 s | 98 MiB |

A 2 MiB document of unusually dense formatting, such as generated API references or a table of
several hundred thousand cells, would start showing **Rendered Preview Unavailable**. That is a
product decision, so the values stay as they are.

**Reproducing.** Make a SwiftPM executable outside the checkout that depends on this package by path
and imports `RemoteFilesCore`. Generate each case in the process, record `getrusage` and
`proc_pid_rusage` around one call (`AttributedString(markdown:)`, `DocumentPolicy.prepareMarkdown`,
`DocumentTextIndex(text:markdown:)`), build with `swift build -c release` and run each case in a
fresh process. To count parses, copy `Sources/RemoteFilesCore` and wrap both
`AttributedString(markdown:)` calls in a counter. Equivalence with the previous preparation is
checked by `DocumentTextIndexTests`, which keeps a verbatim copy of it.

## Interface overhaul: update cost and journey hangs (4 November 2026)

Measured on the iPhone 18 Pro simulator (iOS 27.2), Release with `ENABLE_TESTABILITY=YES`, against `72bec2d`. No physical-device profile was recorded.

**Source view.** `BoundedSourceTextView.updateUIView` used to build a new attributed string and compare it with the current text on every SwiftUI update, including each Find keystroke. It now returns at once unless the text, highlight, font, wrapping or reveal changed. Main-thread time per update, averaged over 40 updates of a hosted view that gets a new closure each time, as the reader's does:

| Document | Before | After |
| ---: | ---: | ---: |
| 64 KiB | 3.2 ms | 0.5 ms |
| 256 KiB | 7.9 ms | 0.5 ms |
| 1 MiB | 27.9 ms | 0.8 ms |
| 2 MiB | 53.6 ms | 0.6 ms |

`ResponsivenessTests.testSourceViewBuildsItsTextOncePerRealChange` fails if the early return is removed.

**Opening a folder.** Through `scripts/benchmark-latency.sh 40 0 3` (40 ms round trip, loopback OpenSSH), listing a folder takes a median 188 ms. A folder already listed ahead of time or remembered shows its rows without waiting for that, then checks them quietly.

**Whole journey: no measurable change.** A 60-second journey (open folders and reports, scroll 1,000 rows, type a filter) was driven by coordinates with no XCTest accessibility queries and profiled with Time Profiler. Builds alternated new, base, base, new, and so on over twelve runs; the first two were discarded as warm-up. Median potential-hang time was 10.4 s before and 10.1 s after, and the median count was 8 in both. The largest single hang, about 5 s, is the system's first software-keyboard setup, which no app code runs in. An earlier three-pair run that always measured the baseline first appeared to show a 25-30% improvement; that was run order. These figures are from a simulator with an automation runner attached, so they say little about absolute hangs on hardware.

**Rich previews.** Mermaid is 5.5 MB of script, parsed for every rich Markdown document until now. It's injected only for documents containing the word `mermaid`. In a hosted test, the page's total load was 3.6 s with it and 3.2 s without, of which about 3.3 s is WebKit starting its content process on the simulator. A shared in-memory data store did not shorten that and wasn't kept.

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

Build and test the phone with the existing signing configuration, replacing `DEVICE_UDID` with
the phone's identifier from `xcrun xctrace list devices`:

```sh
xcodebuild build-for-testing -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -configuration Release -destination 'id=DEVICE_UDID' \
  -derivedDataPath DerivedData-device -allowProvisioningUpdates ENABLE_TESTABILITY=YES
xcodebuild test-without-building -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -configuration Release -destination 'id=DEVICE_UDID' \
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
