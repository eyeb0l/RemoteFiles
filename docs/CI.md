# CI policy and timing

[Build and test](DEVELOPMENT.md) · [Automated acceptance](AUTOMATED_ACCEPTANCE.md) · [CI history](CI_HISTORY.md)

This page explains which checks a change receives, how to reproduce them, and
where to find the evidence. A green CI run covers only the jobs selected for
that change; it is not by itself evidence of a physical-device or real-server
check. For the full local suite and its failure rules, see
[Automated acceptance](AUTOMATED_ACCEPTANCE.md). Dated investigations of past
failures and the original timing baselines are in [CI history](CI_HISTORY.md).

## Tiers

| Tier | Jobs | Runs for |
|---|---|---|
| Repository checks, Linux, about one minute | Generated-project consistency, the Python selector and runner regressions, change classification, `git diff --check` across the complete change | Every PR, push to `main`, nightly run and manual dispatch |
| CI gate, Linux, no builds or test reruns | Requires successful repository checks and successful selected lanes; accepts unselected lanes only if successful or skipped | Every run, even after a dependency fails or skips |
| Quick, two Mac jobs in parallel, about 15 minutes | **Quick / macos-openssh**: every inventoried macOS core test with the loopback OpenSSH and bastion fixtures. **Quick / simulator-core**: every inventoried hosted iOS core test, with the fixture, on a disposable simulator | Every change outside documentation |
| UI, one Mac job, about 45 minutes | **Acceptance / simulator-ui**: the whole UI journey inventory on one disposable simulator | Every push to `main` with code, unless its exact tree already passed the UI journeys in a PR run; PRs that change UI journeys, `App/`, packages, vendored code, `Fixtures/` or demo resources; CI infrastructure; unknown paths; the `full-acceptance` label |
| Extended, two Mac jobs, about 30 minutes | **Acceptance / voiceover**: eight `XCUIVoiceOverService` journeys against production views in the generated `RemoteFilesAccessibility` fixture app. **Acceptance / release-device-compile**: unsigned optimized device build | Nightly at 02:30 UTC on `main`; the label or a manual dispatch; VoiceOver fixture changes (VoiceOver only); CI infrastructure; unknown paths |

The quick tier finds logic, transport, Keychain, persistence and reader regressions
within about fifteen minutes and rarely fails for environmental reasons. The UI and
extended tiers run on three-CPU hosted runners, failed about one first attempt in
three during October, and were re-run on the same commit 39 times, 22 of which then
passed without a code change. They now run once per merged change, nightly, and
before merge only when a change can be exercised nowhere else.

## Selection rules

`scripts/ci_scope.py` classifies the complete change: every commit of a PR, both
sides of a rename, and deletions. The first matching rule applies to each path, and
the change receives the broadest tier of any of its paths.

- Documentation and repository metadata start no Mac runner: `docs/`, `README.md`,
  `AGENTS.md`, `ROADMAP.md`, `PREVIEW_STATUS.md`, licences, `.gitignore`,
  `Vendor/*/UPSTREAM.md` and `design/`.
- CI infrastructure runs every lane, so a change to it proves itself: `.github/`,
  `scripts/ci_scope.py`, `scripts/ci_gate.py`, `scripts/test-acceptance.py`, `scripts/runner_finalization.py`,
  `scripts/test-openssh.sh` and `scripts/generate-project.py`.
- `Tests/VoiceOverFixtures/` adds VoiceOver.
- `Tests/RemoteFilesUITests/`, `App/`, `Package.swift`, every `Package.resolved`,
  vendored code, `Fixtures/` and `Sources/RemoteFilesCore/Resources/` add the UI tier,
  because only the UI lane builds the app target or exercises them.
- `Sources/`, `Tests/RemoteFilesCoreTests/`, the generated `RemoteFiles.xcodeproj`,
  other scripts (including the local `scripts/test-voiceover.sh`, which no lane
  executes) and the local-only fixture apps run the quick tier only.
- Any other path runs every lane.
- A push to `main` adds the UI tier to any code change, unless a PR run already passed
  the UI journeys on the same tree, as described below.
- The `full-acceptance` label, the nightly schedule, and a manual dispatch with
  **full_acceptance** on run every lane for any change. A dispatch with it off runs
  the quick tier.

A push to `main` skips the UI job, and only that, when one of the 50 most recent
successful `pull_request` runs of `ci.yml` meets every condition below. The selector
reads this from the GitHub API, using the workflow's `actions: read` permission.

- The run's head commit has the same tree as the pushed commit.
- The head branch belongs to this repository. A fork's run executes the fork's copy of
  the workflow, so it proves nothing.
- The latest attempt's **Acceptance / simulator-ui** job
  concluded `success`. A PR that was not selected for the UI tier skipped it, so its
  merge still runs the journeys.
- The head contains `main`'s previous tip. A `pull_request` run tests a merge of its head
  into its base, and that merge has the head's tree only when the head contains the base.
  Every `main` base the run can have used is at or before the previous tip.

Any API error, timeout, rate limit or malformed response runs the UI job, and the job log
names the cause. The log also names the run behind a skip. A head that was behind `main`
at merge never qualifies, even if its test merge matched the merged tree, because the API
does not report which merge commit a run tested. The nightly run still executes every
lane on `main`.

Preview a decision with
`python3 -B scripts/ci_scope.py --base "$(git merge-base origin/main HEAD)" --head "$(git rev-parse HEAD)"`;
add `--main-push` to see what the merge will run. That preview assumes the UI job runs
unless `GITHUB_REPOSITORY=eyeb0l/RemoteFiles` is set, which checks the real evidence with
your `gh` login. `scripts/test_ci_scope.py` covers each rule.

## Required merge checks

Require **Repository checks** and **CI gate** on `main`, bound to the **GitHub
Actions** app (ID `15368`). Do not require individual Mac jobs: they intentionally
skip for changes outside their tier. GitHub accepts skipped required jobs, so
requiring those names alone would not prove that a selected lane actually ran.

The gate uses `always()` and directly depends on every other job. It reads the
repository job's explicit `true`/`false` scope outputs and the dependency results:

| Selection | Accepted result | Rejected result |
|---|---|---|
| Repository checks, always required | `success` | Anything else |
| Selected lane, including the aggregate quick matrix | `success` | `failure`, `cancelled`, `skipped`, missing or unknown |
| Unselected lane | `skipped` or `success` | `failure`, `cancelled`, missing or unknown |

Missing or malformed scope outputs fail the gate. A failed quick matrix child
fails the matrix job; `fail-fast: false` lets both quick lanes finish, and no job
uses `continue-on-error`. If quick checks fail and acceptance is skipped as a
consequence, the gate fails. Documentation-only PRs pass after repository checks
with all Mac jobs skipped. Nightly and full-acceptance runs still require every
selected lane. No test is executed again by the gate.

Protection must apply to administrators, block force pushes and deletions, and
require PRs with zero mandatory approvals. Keep **Require branches to be up to
date before merging** off: the gate requires the current PR's selected checks
without forcing another run after each unrelated merge. This does not guarantee
that a PR tested against an older base still works with newer changes; the push
and nightly runs continue to validate `main`. Repository administrators can still
edit the protection settings.

On 4 November 2026, the live branch API reported `protected: false`, both the
ruleset and effective branch-rule APIs returned empty collections, and GraphQL
reported no branch-protection rules. The protection below was then installed
with administration access and verified by reading the API back. Existing PRs
must incorporate the gate workflow before they can merge; the gate's own PR
provides it during this transition. The initial setup command was:

```sh
gh api --method PUT repos/eyeb0l/RemoteFiles/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "checks": [
      {"context": "Repository checks", "app_id": 15368},
      {"context": "CI gate", "app_id": 15368}
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

For repositories with existing protection, preserve their other requirements
instead of replacing them with this initial setup. Verify the result with
`gh api repos/eyeb0l/RemoteFiles/branches/main/protection`: both checks must appear
with the expected app ID, `enforce_admins.enabled` must be `true`, and
`required_status_checks.strict` must be `false`. Without administration access,
use Settings → Branches → Add branch protection rule, pattern `main`, and apply
the requirements above. Run `python3 -B -m unittest discover -s scripts -p 'test_ci_gate.py' -v`
for the focused gate and workflow-wiring regressions.

## Lanes

Each Mac job runs one `scripts/test-acceptance.py --lane` against its dedicated
checkout, with a fresh evidence directory and shared build caches. The core, UI and
VoiceOver lanes record source identity and toolchain/device inventory while their
disposable simulator is still shut down, run `build-for-testing` for
`generic/platform=iOS Simulator`, boot the device only after the build succeeds,
wait up to eight minutes for the 1-minute load average to fall below 40 per logical
CPU, then run the same products with `test-without-building`. A failed build never
boots the device or executes cached products. Each command receives a 30-minute
deadline, except the UI lane's test execution, which receives 60 minutes for the whole
journey inventory. Job ceilings are 45 minutes for the quick lanes and Release, 60 for
VoiceOver and 120 for UI; methods receive 180/240-second allowances. The OpenSSH
fixture surrounds core and UI test execution.

Each lane inventories the XCTest methods in its platform-specific sources and fails
on a missing, extra, repeated, failed or unexpectedly skipped result, or an
xcresult/log count mismatch. Only `SIMULATOR_ALLOWED_SKIPS` in the runner and the
explicit real-server opt-in methods may skip. The macOS lane runs `swift test` with
the fixture. The VoiceOver lane runs the `RemoteFilesAccessibility` scheme: a fixture
app around the production reader and image views and the
`RemoteFilesAccessibilityUITests` bundle it hosts, generated in the real project so
they share DerivedData and the compilation cache with the app and UI targets. Its
journeys use local fixtures only, so no OpenSSH fixture runs and no method may skip;
when the lane fails it also retains `svg-rendering.log`, the SVG preview's lifecycle
log. The Release lane compiles the app for `generic/platform=iOS` without signing.
There are no automatic retries anywhere.

## Runner timing budgets

Hosted `xcode-27-arm64` runners have three logical CPUs and 7 GiB of RAM. Their
1-minute load average reaches 400 to 600 in the minutes after a simulator boots and
sits near 100 while tests run. Measured there: WebKit content processes have taken
13 seconds or more to launch, fixture SSH authentication 2.5 seconds, a trivial
remote command 1.5 seconds, and app termination between UI tests over a minute.
Budget every wait for that:

- Give a test's first WebKit navigation a 60-second cold-start bound; later
  navigations keep their ordinary waits.
- When an operation must succeed, never give the test a shorter wait than the
  production guard, and make UI waits outlast the app's own guard so the app reports
  the failure. The HTML preview guard is 30 seconds; SVG keeps 15 and Markdown 20.
- Only tests of a deadline itself use short bounds.
- When a timeout fails in CI, read `phase-timings.json`, `<lane>-load.log` and the
  method durations in the lane artifact before changing a limit.
- To reproduce slow WebKit locally, pause each new `com.apple.WebKit.WebContent`
  process of a dedicated simulator with `SIGSTOP` for about 13 seconds.

## Caches and evidence

Each job records its exact clean commit and source manifest, then verifies that
builds leave source and lockfiles unchanged; dirty direct-checkout runs are rejected.
Build caches live outside the evidence folder under one key per toolchain,
architecture, platform, lane, dependency hash and source hash. A restore falls back
to the same lane's most recent entry, then to any lane of the platform. Only pushes to
`main` and the nightly run save new entries, so PR branches build on top of the latest
merged state and the repository's cache budget holds a recent entry for every lane. A push that skips the UI journeys saves no UI
entry, so the UI lane restores the nightly run's or an earlier merge's.
Xcode's native compilation cache and its CAS are stored inside the cache root, and IDE
indexing is disabled for CI builds.

Phase timings record source preparation, toolchain queries, device inventory, boot
and settle separately with host load averages; `<lane>-load.log` samples the busiest
processes every 15 seconds; `/usr/bin/time -l` records CPU, memory and page faults
per command. Logs, each fixture-backed lane's complete `<lane>-sshd.log`, summaries
and xcresults are uploaded for seven days as `validation-<lane>-<run>-<attempt>`.
Failed method identifiers and assertions are printed in the job log. New commits
cancel superseded runs for the same PR or branch; the nightly run has its own
concurrency group, so a merge neither cancels it nor is cancelled by it.

## Local reproduction

Run a single lane with fresh evidence outside the checkout:

```sh
python3 -B scripts/test-acceptance.py --lane macos-openssh \
  --output /private/tmp/remotefiles-macos-NEW_RUN
python3 -B scripts/test-acceptance.py --lane simulator-core \
  --simulator SIMULATOR_UDID --output /private/tmp/remotefiles-core-NEW_RUN
python3 -B scripts/test-acceptance.py --lane simulator-ui \
  --simulator SIMULATOR_UDID --output /private/tmp/remotefiles-ui-NEW_RUN
```

Other choices are `voiceover`, `release-device-compile`, and the combined
`simulator` lane. Repeat `--lane` to select disjoint inventories; the
combined Simulator lane cannot be mixed with its core/UI subsets. Omit `--lane`
to retain the complete local acceptance run. Use `--allow-dirty` only when the
report should identify a working-tree snapshot rather than an exact commit.
`--ui-shard 1` or `--ui-shard 2` requires exactly `--lane simulator-ui` and runs a
shorter local check: shards alternate the sorted method identifiers, include new
methods automatically and each build the complete UI target, and a shard report is
explicitly partial UI evidence. CI no longer shards. Run both shards for full UI
evidence, using separate fresh output directories and never running two jobs on one
device.

## Investigating a failure

`gh run view RUN_ID --log-failed` prints the failing methods; the artifact keeps
the full logs, xcresults and the fixture's server log. Investigate before rerunning,
and rerun only a failure shown to be unrelated, naming the method and the suspected
cause in the PR. A same-commit rerun that passes is not a diagnosis. Treat an app
termination failure or a `simctl bootstatus` timeout as runner infrastructure once
the log shows that pattern. A UI or VoiceOver failure on `main` after a merge
belongs to that merge: fix it forward or show it unrelated. Past investigations,
with the runs they cite, are in [CI history](CI_HISTORY.md).

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

The local `scripts/test-voiceover.sh` launcher runs the same scheme with one
`xcodebuild test`, and the scheme also runs from Xcode. It supports macOS’s stock Bash
when its optional package setting is absent. Launcher regressions also check that
argument paths with spaces survive and that collecting lifecycle logs cannot turn a
failed Xcode run into success.

The other local fixture launchers (`test-small-features.py`, `test-image-open.sh` and
`test-reading-anchors.py`) still swap sources in a disposable project copy. Those
copies rebase `App/Info.plist` to the source checkout, along with their package and
source references. The project-preparation regression executes all three launchers'
preparation code and verifies the app and accessibility fixture configurations still
resolve the original plist, including checkout paths with spaces. Test hosts retain
their generated plists.
