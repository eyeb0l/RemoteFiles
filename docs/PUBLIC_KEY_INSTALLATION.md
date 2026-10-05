# Install a public key on a server

Open **Settings → SSH Keys**, select an Ed25519 identity and choose **Install Public Key on Server**. Enter the account, hostname, port and its SSH password. The server must already offer SSH password authentication; keyboard-interactive authentication alone is not supported. RemoteFiles does not enable password login or change server authentication settings.

Choose **Review Installation**, check the exact account, public key and SHA-256 fingerprint, then choose **Install Public Key**. Review and Cancel do not contact or write to the server. An unknown host requires fingerprint verification and a fresh review; a changed host key blocks installation. Host verification uses the same trusted endpoint store as browsing.

Only the canonical public Ed25519 key is sent. Private key material is never exported, unlocked or sent for this operation. The password is used for this connection only, is not saved in metadata or Keychain, and is cleared from the form on confirmation, cancellation, dismissal and backgrounding. Browsing remains read only.

The installer expects a Unix account using the standard `$HOME/.ssh/authorized_keys` path. It creates a missing `.ssh` directory with private permissions and appends a missing public key. It preserves every existing byte and key, including options on restricted entries. An existing matching key returns **already installed** without adding an unrestricted duplicate. It refuses symlinks, unsafe ownership, writable permissions or multiply linked key files. It does not repair existing permissions or replace files.

A short-lived account lock serializes cooperating installers. A server interruption can leave that lock behind; subsequent attempts fail closed. If this persists, inspect the account’s `.ssh/.remotefiles-key-install.lock` on the server. RemoteFiles never deletes a lock owned by another operation.

Cancellation closes this installation’s connection, but cannot undo an append already completed by the server. A lost reply therefore reports an unconfirmed outcome rather than success. Review and retry the same key: duplicate detection prevents a second complete entry. A partial interrupted append is preserved and a retry starts a new line before the complete key. Confirmed installation means the append and reread completed; it does not establish that the server’s authentication policy permits login with that key. Custom `AuthorizedKeysFile` locations require manual setup.

Automated coverage uses injected UI transport and disposable local home directories, plus host verification and password refusal on the isolated password-disabled OpenSSH fixture. These checks do not grant access to a real server or establish a password-enabled production-server installation.
