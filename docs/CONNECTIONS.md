# Connections and security

[Documentation](README.md) · [RemoteFiles](../README.md)

Connect to an existing SSH/SFTP server, verify its identity, and understand how RemoteFiles handles credentials and local state.

## Connect a Unix system

Do these setup steps yourself on the server you intend to access. RemoteFiles connects over SSH/SFTP using an Ed25519, RSA or ECDSA identity. The app does not enable services or expose ports. Browsing is read only. The optional public-key installer writes only the selected account’s `~/.ssh/authorized_keys` after you confirm the account and public key; see [public-key installation](PUBLIC_KEY_INSTALLATION.md).

1. Enable SSH with an SFTP subsystem for the intended account using the system’s service configuration. On **macOS**, use **System Settings → General → Sharing → Remote Login**. On **Linux or another Unix system**, enable its OpenSSH server and SFTP subsystem according to that system’s documentation. Keep the server awake and reachable. The account must be able to read the chosen project directory.
2. In RemoteFiles, choose **Add Connection → Generate or Import Key**. Prefer a dedicated generated Ed25519 identity; copy/share its **public** key. Append that public key to the intended account’s `~/.ssh/authorized_keys` on the server (directory permission 700; file permission 600). Never copy a private key into that file. If the server already supports SSH password authentication, **Settings → SSH Keys → select identity → Install Public Key on Server** can append the public key after host verification and explicit confirmation.
3. If connecting away from home, install/sign in to Tailscale independently on both devices. Use the server’s MagicDNS hostname or Tailscale IP; ensure tailnet policy permits the configured SSH port (22 by default). This uses ordinary OpenSSH over Tailscale, **not the separate Tailscale SSH service**. Do not forward a router port. The connection editor’s **Show Tailscale Setup Tips** switch only shows this guidance; RemoteFiles does not route through Tailscale itself, so the connection uses whatever network path iOS provides to the hostname you enter.
4. Enter the server account’s username, hostname, identity and optional absolute project directory. An empty starting directory uses the server’s default directory; literal `~` is not expanded locally.
5. Verify the displayed server SHA-256 fingerprint using a trusted channel. On an OpenSSH server, the public host-key fingerprint can be inspected with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256` (choose the public file for the algorithm presented and the server’s configured host-key location). Accept trust only when it matches.
6. Open a folder and choose **Folder actions → Add Favourite**. Open a `.md` report. Use **Rendered / Source**, **Copy Source**, and **Refresh** from its actions menu.

The first connection on a local network may require iOS Local Network permission. A timeout alone does not identify whether the server is asleep, the tunnel is unavailable, a permission was denied, or network policy blocked access. Check these possible causes individually. Denial and Settings recovery were verified on the physical iPhone; see [device permissions and lifecycle evidence](DEVICE_PERMISSIONS_LIFECYCLE.md).

## Keys and trust

Generated Ed25519 keys and verified OpenSSH Ed25519, RSA and ECDSA import formats are documented in [KEY_SUPPORT.md](KEY_SUPPORT.md). Imports accept extensionless files and explicit paste. Encrypted originals remain encrypted in Keychain; an unlocked key is retained only for the foreground session. Passphrases are never persisted. Optional Face ID unlock keeps an unlocked copy readable only with the currently enrolled Face ID; see [Face ID unlock](KEY_SUPPORT.md#face-id-unlock). Keychain uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with synchronisation disabled. This does not imply hardware-backed Ed25519 protection.

Unknown hosts require explicit trust. Changed host keys block before account authentication. The reset flow removes trust and requires another verification; it does not silently accept the new key. A key used by a saved connection cannot be deleted.

Profiles, favourites, recent references, and public identity metadata are stored atomically in Application Support. Private material stays in Keychain. Recent files are references, not persistent offline copies. Swipe a recent entry and choose **Remove from Recents** to remove its saved reference; the remote file and favourites remain. The same action is available to VoiceOver. **Disconnect** returns Home, clears the navigation stack and cancels pending session work. In-memory cache is bounded to ten prepared directory listings and at most four documents / 6 MiB, and cleared on memory warnings or disconnect. Returning to a cached folder preserves its scroll position without a new listing; use pull-to-refresh or **Refresh** to check for remote changes. Networking and unlocked keys are retired on backgrounding.
