# Repository Guidelines

## Project Structure & Module Organization

RemoteFiles is a native SwiftUI, read-only SFTP browser targeting iOS 27. `App/` contains app/test-host entry points and icon assets. `Sources/RemoteFilesCore/` owns transport, persistence, trust, and document policies; `Sources/RemoteFilesUI/` contains views and presentation state. Bundled samples live in `Sources/RemoteFilesCore/Resources/`. `Tests/` holds core XCTest suites, UI tests, and specialized fixture apps. Use `docs/` for feature policies, `scripts/` for verification, and `Fixtures/` for synthetic inputs. Vendored Citadel/Textual changes require corresponding `Vendor/*/UPSTREAM.md` provenance updates.

## Build, Test, and Development Commands

Use Xcode 27 or newer. Open `RemoteFiles.xcodeproj`, select the shared `RemoteFiles` scheme and an available iOS 27 simulator, then Run. Use `--demo` or Settings → Explore Demo for sample data.

```sh
# Compile for a simulator; substitute an available device name.
xcodebuild -project RemoteFiles.xcodeproj -scheme RemoteFiles \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
swift test                          # Package tests; server cases may skip.
scripts/test-openssh.sh swift test   # Tests with isolated OpenSSH fixtures.
python3 scripts/generate-project.py # Regenerate Xcode project after adding tests.
```

Commit both resolved lockfiles when dependencies change. See `README.md` for signed hosted iOS tests; Keychain tests require an ad-hoc-signed simulator host.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, and descriptive filenames matching their primary type. Keep transport/policy logic in Core and view behavior in UI. The package uses Swift tools 6 with Swift 5 language mode. No repository-wide formatter or linter configuration is provided; match neighboring code and run `git diff --check`.

## Testing Guidelines

Use XCTest classes named `*Tests` and behavior-focused `test...` methods. Add regressions for changed behavior, including cancellation, limits, and lifecycle where relevant. No percentage coverage threshold is defined. For integration acceptance, follow `docs/AUTOMATED_ACCEPTANCE.md`; retain logs and distinguish skipped tests, simulator results, and physical-device evidence.

## CI & Automated Acceptance

GitHub Actions (`.github/workflows/ci.yml`) runs **Repository checks** on every PR and `main` push: runner/scope regressions, generated-project consistency, and `git diff --check` across every commit. `scripts/ci_scope.py` then chooses the Mac lanes; documentation-only changes start none. Code changes run **Quick / macos-openssh** and **Quick / simulator-core** (the `RemoteFilesCoreCI` scheme) in parallel. Reader, preview/security, navigation, dependency, vendored, app-configuration, fixture, CI, and unknown paths also run **Acceptance / simulator-ui**, **voiceover**, and **release-device-compile** after the quick lanes pass; the `full-acceptance` label forces them. Preview the decision with `python3 -B scripts/ci_scope.py --base "$(git merge-base origin/main HEAD)" --head "$(git rev-parse HEAD)"`.

The runner, `scripts/test-acceptance.py`, fails closed: every inventoried XCTest method must report a result, so run `python3 scripts/generate-project.py` after adding tests. A new skip fails unless the method is in `SIMULATOR_ALLOWED_SKIPS` and its reason is documented in `docs/AUTOMATED_ACCEPTANCE.md`. Reproduce a lane locally with `python3 -B scripts/test-acceptance.py --lane simulator-core --simulator SIMULATOR_UDID --output /private/tmp/remotefiles-NEW_RUN`, using a fresh directory outside the checkout, `--allow-dirty` for uncommitted work, one run per simulator, and `--port 22223` if 22222 is taken. Run Python with `-B` so no `__pycache__` appears in `scripts/`.

Investigate a failure before rerunning it. `gh run view RUN_ID --log-failed` prints the failing methods; the `validation-<lane>-<run>-<attempt>` artifact keeps full logs, xcresults, and the fixture's `<lane>-sshd.log` for seven days. Rerun only a failure shown to be unrelated, and say so in the PR; there are no automatic retries. Fixture SFTP tests disconnect in `addTeardownBlock`, not `defer`, so the reported error is the real one. New commits cancel superseded runs on the same branch, including `main`. Update `docs/CI.md` when changing a lane, timing budget, or allowed skip.

Hosted macOS runners are slow and heavily loaded: three logical CPUs, 7 GiB of RAM, and load averages from about 77 to the hundreds after simulator boot. There, WebKit content processes have taken 13 seconds or more to launch, fixture SSH authentication 2.5 seconds, and a trivial remote command 1.5 seconds. Budget every new wait for that. When an operation must succeed, never give the test a shorter timeout than the production code allows; only tests of a deadline itself use short bounds. Make UI waits outlast the app's own guard so the app reports the failure. Give a test's first WebKit navigation a cold-start bound, as `docs/CI.md` describes. Production guards catch hangs, so size them for slow but healthy devices. When a timeout fails in CI, read the timings in the lane artifact before changing a limit. To reproduce slow WebKit locally, pause each new `com.apple.WebKit.WebContent` process of a dedicated simulator with `SIGSTOP` for about 13 seconds.

## Commit & Pull Request Guidelines

Use short imperative subjects, such as `Add persistent line wrapping controls to source reader`. Keep commits focused. PRs should explain the behavior change, link relevant issues, report validation and remaining limitations, and include screenshots for UI changes. Update affected feature documentation. Resolve `RemoteFiles.xcodeproj/project.pbxproj` conflicts by taking `main`'s copy and rerunning `scripts/generate-project.py`, never by hand. For stacked PRs, retarget the dependent PR to `main` before deleting its base branch; deleting the base first closes it.

## Security & Configuration

Preserve read-only browsing, canonical folder boundaries, bounded transfers, and explicit host-key trust. Public-key installation requires explicit confirmation. Keep private keys in Keychain and exclude credentials, private attachments, and generated test/build output from commits.
