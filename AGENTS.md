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

## Commit & Pull Request Guidelines

Use short imperative subjects, such as `Add persistent line wrapping controls to source reader`. Keep commits focused. PRs should explain the behavior change, link relevant issues, report validation and remaining limitations, and include screenshots for UI changes. Update affected feature documentation.

## Security & Configuration

Preserve read-only browsing, canonical folder boundaries, bounded transfers, and explicit host-key trust. Public-key installation requires explicit confirmation. Keep private keys in Keychain and exclude credentials, private attachments, and generated test/build output from commits.
