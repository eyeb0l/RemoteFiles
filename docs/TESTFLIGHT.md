# Release to TestFlight

[CI policy](CI.md) · [Build and test](DEVELOPMENT.md)

Betas are built, signed and uploaded by Xcode Cloud. A build starts only when a
`testflight/*` tag is pushed or someone starts one by hand on such a tag, never for a pull
request or an ordinary push to `main`.

## Release a build

```sh
python3 -B scripts/testflight_release.py         # Shows the commit, version and tag.
python3 -B scripts/testflight_release.py --push  # Pushes the tag, which starts the build.
```

The command defaults to the tip of `main`; use `--commit SHA` for an earlier commit on `main`.
It stops unless the commit is on `main` and both **Repository checks** and **CI gate** passed
on it. A docs-only commit passes those with its Mac lanes skipped, so check that the last code
commit's run passed too. It needs your `git` and `gh` logins.

Xcode Cloud then runs `ci_scripts/ci_post_clone.sh`, which fails the build if the commit is
not on `main`. This also covers a tag pushed by hand or a manual start, but it cannot check CI
results.

Tags are named `testflight/<version>-<n>`, for example `testflight/0.1.0-3`. `<n>` counts
releases of that version; it is not the build number. A ruleset stops `testflight/*` tags
being moved or deleted, so each one permanently records what shipped.

## Version and build numbers

- **Build number:** Xcode Cloud assigns one to every build, counting up from 1, and App Store
  Connect shows it as `0.1.0 (42)`. Failed builds use a number too, so gaps are normal. Do not
  edit `CURRENT_PROJECT_VERSION`, which stays at 1 for local builds. If this version was already
  uploaded by another route with a higher build number, set a higher value in App Store Connect →
  Xcode Cloud → Settings → Build Number.
- **Version:** change `MARKETING_VERSION` in `scripts/generate-project.py`, run the generator and
  merge that change before releasing. It must be one to three period-separated integers.

## Xcode Cloud configuration

Xcode Cloud workflows live in App Store Connect, not in this repository, so this page is their
record. The saved `TestFlight` workflow was read back on 4 November 2026:

| Workflow setting | Value |
|---|---|
| General | **Restrict Editing** on |
| Environment | Latest Release for Xcode and macOS, **Clean** on. Xcode 27.2 hides Clean; change it in App Store Connect's workflow editor |
| Start conditions | **Tag Changes** and **Manual Start - Tag**, both for tags beginning with `testflight/`. No Branch Changes or Pull Request Changes |
| Actions | Only **Archive - iOS**, scheme `RemoteFiles`, distribution preparation **App Store Connect**, which allows internal and external testers and the App Store |
| Post-actions | **TestFlight Internal Testing - iOS**: the `Internal` group |

The `Internal` group has automatic distribution off, so the post-action is the only route for a
build to reach testers. App Store Connect does not let that group setting change later. The app
record uses bundle ID `dev.iris.RemoteFiles` and SKU `remotefiles`.

Xcode requires a Manual Start condition and has no control to remove it, so it is limited to the
same tags. A manual start skips the release command's CI check, but the `main` guard still runs.

Xcode also created an `Internal TestFlight Build` workflow, which is deactivated. Leave it off. Do not
add other workflows without changing `ci_scripts/ci_post_clone.sh`: Xcode Cloud runs it for all of
them, and it fails any build of a commit that is not on `main`.

External testers need a TestFlight External Testing post-action, test information and Beta App Review.

### If setting this up again

Xcode 27.2 does not follow Apple's documented first-run order, so check these points:

1. After you select the product, Xcode goes straight to **Setup Complete** and saves a workflow that
   builds every push to `main`. Do not press **Start First Build**. Choose **Close**, then correct the
   workflow in Integrate → Manage Workflows before anything is pushed.
2. Save the start conditions before adding Archive, which opens a **Create App** sheet when the app
   has no record yet. Xcode may then rewrite `project.pbxproj`; run `scripts/generate-project.py` to
   restore it, because Repository checks require the generated output.
3. Xcode may warn that the scheme `RemoteFiles` "may only exist locally", although it is committed.
   The warning appeared with the project open from a Git worktree; the first build will show whether
   it matters.

## Export compliance

The app does its own encryption through SSH and `swift-crypto`, not only through the operating
system, so it does not automatically qualify for Apple's simple exemption. The project therefore
leaves `ITSAppUsesNonExemptEncryption` unset, and a build shows **Missing Compliance** in TestFlight
until you answer App Store Connect's questionnaire for it.

This is your legal decision. Follow [Apple's export compliance guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).
Once you know the answer, add the key to `App/Info.plist` to stop being asked. Do not set it to
`NO` just to clear the prompt.

## Privacy manifest

`App/PrivacyInfo.xcprivacy` declares the required-reason APIs the app uses, and declares no
tracking or data collection. Keep it accurate when adding one of these APIs:

| Category | Reason | Use |
|---|---|---|
| File timestamps | `C617.1` | Metadata of the app's own caches, downloads, offline files and indexes |
| Disk space | `E174.1` | Refusing a download that would not fit on the device |
| User defaults | `CA92.1` | The app's own preferences |

## Why Xcode Cloud

| | Xcode Cloud | GitHub Actions workflow |
|---|---|---|
| Credentials to store | None; Apple holds the cloud-managed signing certificate | An App Store Connect key in the secrets of a public repository. Developers report that cloud signing needs its Admin role; the alternative is a certificate and profile to renew as well |
| Build numbers | Assigned automatically | Must be derived and kept unique in the workflow |
| Cost | Within the 25 monthly hours included with the membership | Free on standard runners for a public repository |
| Configuration | In App Store Connect, not reviewable in a PR, so recorded on this page | In the repository |

Avoiding a long-lived, high-privilege key decided this; the configuration is the cost. A clean
unsigned archive took 2–4 minutes on a development Mac. Xcode Cloud's speed is unmeasured, but even
30 minutes a build would allow 50 builds a month. Pull requests remain on GitHub Actions.
