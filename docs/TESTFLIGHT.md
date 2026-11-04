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

Until `ITSAppUsesNonExemptEncryption` is set, a build shows **Missing Compliance** in TestFlight and
testers cannot install it until App Store Connect's questionnaire is answered. Answer it like this,
matching by meaning because Apple does not publish the exact wording:

| Question | Answer |
|---|---|
| Does the app use encryption? | **Yes** |
| What type of algorithms? | **Standard encryption algorithms, instead of or in addition to Apple's operating system encryption** |
| Available on the App Store in France? | **No**, while the app is not released there |

The app bundles its SSH encryption through `swift-nio-ssh`, Citadel and `swift-crypto`, so it does not
use only the operating system's. Those algorithms are published standards such as AES, RSA, ECDSA,
Ed25519 and bcrypt, not proprietary ones. For standard algorithms,
[Apple's table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
requires a document only for the App Store in France. This is our reading, not legal advice, and Apple
leaves responsibility for it with the developer. Change the answers if any of these facts change.

### Stop answering for every build

When App Store Connect reports that no documentation is required, add this to `App/Info.plist`:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

[Apple says](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
`NO` covers encryption exempt from documentation requirements, and its overview says to update the
plist when none is required. Third-party guides disagree for bundled libraries, so confirm that result
in App Store Connect first; the key then declares it for every later build.

Before releasing on the App Store, check this again:

- **In France:** upload the French encryption declaration and replace `NO` with `YES` plus the
  `ITSEncryptionExportComplianceCode` that Apple issues.
- **US annual report:** the sources conflict on whether a finished mass-market app needs a BIS
  self-classification report, due by 1 February. Ask an export lawyer or BIS.

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
