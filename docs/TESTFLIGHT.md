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
on it. A commit that changes only documentation passes those with every lane that builds the app
skipped, so the command also looks back along `main` for the newest commit on which both
**Quick** lanes passed, and stops if anything CI would have built has changed since. That
covers a code commit whose run failed or was cancelled by the push after it. It needs your `gh` login to read those results and the
[deploy key](#deploy-key) to push the tag; `ssh` asks for the key's passphrase each time.

Xcode Cloud then runs `ci_scripts/ci_post_clone.sh`, which fails the build if the commit is
not on `main`. This also covers a manual start, but it cannot check CI results.

Tags are named `testflight/<version>-<n>`, for example `testflight/0.1.0-3`. `<n>` counts
releases of that version; it is not the build number. One ruleset stops `testflight/*` tags
being moved or deleted, so each one permanently records what shipped. A second lets only a
deploy key create them.

## Deploy key

A pushed `testflight/*` tag is built, signed and sent to testers with no further step, so an
ordinary login must not be able to push one. The **TestFlight tags need the deploy key** ruleset
rejects the tag from every account and token, and lets a deploy key through. The release
command pushes over SSH with that key alone.

Create the key once, with a passphrase that is not saved on the Mac:

```sh
ssh-keygen -t ed25519 -C "RemoteFiles TestFlight tags" -f ~/.ssh/remotefiles_testflight_deploy
gh repo deploy-key add ~/.ssh/remotefiles_testflight_deploy.pub --repo eyeb0l/RemoteFiles \
  --allow-write --title "TestFlight tags"
```

- **Another location:** pass `--key PATH` or set `REMOTEFILES_TESTFLIGHT_KEY`.
- **Passphrase:** the command refuses a key without one, because other tools on the Mac can
  read the file. It runs `ssh` without your SSH configuration, agent or an exported
  `GIT_SSH_COMMAND`, so the passphrase is asked for on the terminal each time and is not saved
  to the Keychain.
- **First use:** `ssh` asks you to accept GitHub's host key unless it is already in
  `~/.ssh/known_hosts`. Compare it with
  [GitHub's published fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
- **Any deploy key counts:** the ruleset cannot name one key, so do not add other deploy keys
  with write access to this repository.

This stops a stray or automated push. It does not bind an account with admin rights, which
can add a deploy key or change the ruleset.

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

`App/Info.plist` sets `ITSAppUsesNonExemptEncryption` to `NO`, so builds do not stop at App Store
Connect's export questionnaire. That key declares the following answers for every build:

| Question | Answer |
|---|---|
| Does the app use encryption? | **Yes** |
| What type of algorithms? | **Standard encryption algorithms, instead of or in addition to Apple's operating system encryption** |
| Available for distribution in France? | **No** |

On 4 November 2026, App Store Connect's App Encryption Documentation dialog responded to these answers
with: "Based on your answers, you don't need to upload any documents." It then pointed to the
`Info.plist` setting as the way to avoid answering with each submission.

The app bundles its SSH encryption through `swift-nio-ssh`, Citadel and `swift-crypto`, so it does not
use only the operating system's. Those algorithms are published standards such as AES, RSA, ECDSA,
Ed25519 and bcrypt, not proprietary ones. For standard algorithms,
[Apple's table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
requires a document only for France. This is our reading, not legal advice, and Apple leaves
responsibility for it with the developer. Repeat the questionnaire if any of these facts change,
including a proprietary algorithm being added.

Before releasing on the App Store, check this again:

- **France:** the `NO` depends on the app not being distributed there, so exclude France from the
  app's availability. To include it, upload the French encryption declaration and replace `NO` with
  `YES` plus the `ITSEncryptionExportComplianceCode` that Apple issues.
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
