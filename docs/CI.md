# CI policy and timing

[Build and test](DEVELOPMENT.md) · [Automated acceptance](AUTOMATED_ACCEPTANCE.md)

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
  the separate slow UI-journey target, not UIKit-based core tests.

Only the explicitly physical-device Data Protection assertion may skip in the
hosted core lane. Benchmark operations run once on loopback. Missing methods,
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
hashes, and lane. Related iOS lanes can restore each other's compiled work;
macOS and iOS caches remain separate. Successful compilation is saved even when
subsequent tests fail. Cancelled runs do not delay retirement to save a cache.

Logs, source identity, summaries and xcresults are uploaded for seven days on
success or failure. Failed method identifiers/assertions are printed immediately
in the job log. Cleanup touches only each job's disposable Simulator and generated
loopback fixture. New commits cancel superseded runs for the same PR or branch.
The quick jobs have a 35-minute infrastructure ceiling and acceptance jobs 45
minutes; these are failure bounds, not target durations. Each command retains
its own 30-minute deadline.

## Why the first workflow took nearly an hour

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
