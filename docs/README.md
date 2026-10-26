# RemoteFiles documentation

[← Project overview](../README.md)

Choose a guide by what you want to do.

> **Reading the evidence:** Feature guides explain behavior and limits. Investigation and acceptance records also contain dated results; those results are not claims about the current build.

## Use the app

- [Connect to a server](CONNECTIONS.md): what you need, authentication, host-key trust and local data.
- [Use a jump host](JUMP_HOSTS.md): connect through one SSH bastion and verify both hosts.
- [Manage SSH keys](KEY_SUPPORT.md) or [install a public key](PUBLIC_KEY_INSTALLATION.md) on a compatible server. Installation is a separately confirmed server change; browsing is read only.
- [Browse and search folders](FOLDER_BROWSING.md): sorting, hidden files, symbolic links and search limits.
- [Read and preview files](READER.md): supported formats, navigation, source, sharing and size limits.
- [Save files and folders for offline use](OFFLINE_FILES.md): snapshots, updates, storage limits and offline links.
- [Use the iPad workspace](IPAD.md): navigate the library, folder and reader in different window sizes.

For a closer look at specific behavior, see [document links](DOCUMENT_LINKS.md), [saving original files](ORIGINAL_EXPORT.md), [remote Markdown images](REMOTE_IMAGES.md), [audio and video](AUDIO_VIDEO.md) and [static HTML](HTML_PREVIEWS.md).

## Build, change and verify the app

- [Build and test](DEVELOPMENT.md): Xcode, signing, fixtures and local commands. Run shell examples from the repository root.
- [Contributor guide](../AGENTS.md): project layout and repository conventions.
- [CI policy](CI.md): which lanes run, timing and how to reproduce them.
- [Automated acceptance](AUTOMATED_ACCEPTANCE.md): runner usage, required results, allowed skips and evidence.
- [Manual acceptance](MANUAL_ACCEPTANCE.md), [real-server acceptance](REAL_SERVER_ACCEPTANCE.md) and [device permissions and lifecycle](DEVICE_PERMISSIONS_LIFECYCLE.md): device and network checks that automated tests do not replace.
- [App icon](APP_ICON.md): assets, appearance variants and export workflow.

## Understand decisions and history

- [Project status](../PREVIEW_STATUS.md) records dated build and acceptance results; [roadmap](../ROADMAP.md) describes deferred work.
- [SSH transport investigation](SSH_SPIKE.md) and [renderer investigation](RENDERER_SPIKE.md) document earlier dependency choices and their verification.
- [Reader performance](READER_PERFORMANCE.md) and [Markdown viewport rendering](markdown-viewport-rendering.md) explain specific performance and layout work.
- Vendored dependency provenance: [Citadel](../Vendor/Citadel/UPSTREAM.md) and [Textual](../Vendor/Textual/UPSTREAM.md).
