# Documentation

[← RemoteFiles](../README.md)

## Start here

- [Connections and security](CONNECTIONS.md): SSH/SFTP setup, Tailscale, host verification, credentials, and local state.
- [Build and test](DEVELOPMENT.md): Xcode setup, signing, dependencies, test commands, and fixture isolation. Run shell examples from the repository root.
- [Reader and preview behavior](READER.md): formats, resource limits, syntax highlighting, navigation, and export.
- [Contributor guide](../AGENTS.md): repository structure and contribution conventions.

## Feature guides

- [Folder browsing](FOLDER_BROWSING.md): symbolic links, sorting, and searching names or file contents in subfolders.
- [SSH key support](KEY_SUPPORT.md) and [public-key installation](PUBLIC_KEY_INSTALLATION.md).
- [Remote images](REMOTE_IMAGES.md), [audio and video](AUDIO_VIDEO.md), and [static HTML](HTML_PREVIEWS.md).
- [Document links](DOCUMENT_LINKS.md), [original-file export](ORIGINAL_EXPORT.md), and [JSON/SVG previews](READER.md#json-and-svg-previews).
- [Offline files and folders](OFFLINE_FILES.md): complete folder snapshots, individual copies, explicit updates, links between saved documents, local previews and storage limits.
- [App icon](APP_ICON.md): assets, appearance variants, and export workflow.

## Architecture and performance

- [SSH transport investigation](SSH_SPIKE.md) and [renderer investigation](RENDERER_SPIKE.md).
- [Reader performance](READER_PERFORMANCE.md) and [Markdown viewport rendering](markdown-viewport-rendering.md).
- Vendored dependency provenance: [Citadel](../Vendor/Citadel/UPSTREAM.md) and [Textual](../Vendor/Textual/UPSTREAM.md).

## Verification and project status

- [CI policy and timing](CI.md): quick PR checks, broader acceptance triggers and build caches.
- [Automated acceptance](AUTOMATED_ACCEPTANCE.md): runner usage, required test lanes, and retained evidence.
- [Manual acceptance](MANUAL_ACCEPTANCE.md), [real-server acceptance](REAL_SERVER_ACCEPTANCE.md), and [device permissions/lifecycle](DEVICE_PERMISSIONS_LIFECYCLE.md).
- [Project status](../PREVIEW_STATUS.md): recorded results and outstanding acceptance.
- [Roadmap](../ROADMAP.md): deferred work.

Acceptance documents include historical evidence; consult their dates and stated limitations when interpreting results.

- [Jump hosts](JUMP_HOSTS.md): single-bastion SSH routing and independent trust.
- [iPad workspace](IPAD.md): library, folder and reader in an adaptive split view.
