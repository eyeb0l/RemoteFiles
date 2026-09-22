# SSH identity and server-key support

RemoteFiles generates dedicated Ed25519 keys with Swift Crypto and imports single-key OpenSSH Ed25519 private files. Private-key decryption uses Citadel; the app's small container-header reader only identifies formats and rejects unsupported configurations before decryption. File extensions are not used to identify keys.

The implementation is based on [Citadel's pinned OpenSSH parser](https://github.com/orlandos-nl/Citadel/blob/ae8562f895de06ccb86fdb1cbb65fd99c8976e12/Sources/Citadel/OpenSSHKey.swift). Its bcrypt restriction is a dependency limit, not a recommendation for choosing protection on existing keys.

| Identity format | Preview behaviour |
| --- | --- |
| Generated Ed25519 | Supported; private seed stored only in Keychain |
| OpenSSH Ed25519, unencrypted (`none`) | Supported; original private representation stored only in Keychain |
| OpenSSH Ed25519, AES-256-CTR + bcrypt 1–31 rounds | Supported; includes ordinary `ssh-keygen` defaults in the tested matrix |
| OpenSSH Ed25519, AES-128-CTR + bcrypt 1–31 rounds | Supported |
| bcrypt rounds 32 or greater | Rejected with an unsupported-configuration message |
| AES-CBC, other encryption/KDF formats | Rejected |
| RSA, ECDSA, security-key identities, PEM/PKCS#8, multiple keys | Deferred; rejected |
| Public key only | Explicitly identified; cannot authenticate without its private identity |

The host's installed `ssh-keygen` generates temporary test keys at runtime. Tests cover unencrypted and default encrypted import, AES-128-CTR, missing/wrong passphrases, unsupported bcrypt-32 and AES-CBC, malformed/public-only input, public-key/fingerprint parity with `ssh-keygen`, encrypted representation preservation, and foreground session clearing. These tests prove parsing/storage contracts; SSH authentication against a server is a separate transport integration test. See `PREVIEW_STATUS.md` for actual execution results and SDK/device limitations.

The preview does not ask users to remove protection from existing keys or silently substitute account passwords. If an existing encrypted key is unsupported, generate a dedicated app identity and manually authorise its public key instead.

## Secret lifecycle

Only non-secret identity metadata (ID, name, algorithm, canonical public key, fingerprint, encrypted flag, and an opaque Keychain account reference) appears in the metadata JSON. Private material is stored as a generic-password Keychain item under the app's service, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable = false`. No key material is stored in UserDefaults or ordinary files. Keychain failure is an error, never a fallback to plaintext storage. This is device-local Keychain protection; it is not a claim of hardware-backed Ed25519.

An encrypted import retains its original encrypted representation in Keychain. Its passphrase is used for validation/unlock but is never retained by `IdentityStore` or persisted. An unlocked cryptographic key may be cached during the active foreground connection session. Disconnect/background clears that cache and invalidates in-flight unlocks. Swift memory management cannot promise forensic zeroisation of every temporary string or framework copy. Import validation itself does not seed the session cache. The UI must clear its passphrase field after completion or dismissal, and the transport must close its authentication/session references on disconnect.

## Public keys and host trust

Public keys use NIOSSH's canonical OpenSSH serialisation, including the SSH algorithm and length-prefixed wire representation. SHA-256 fingerprints hash that full SSH public-key wire representation; they do not hash a raw Curve25519 public byte array.

Trust is scoped to normalised hostname/address and port. Unknown keys block connection and expose a fingerprint for explicit acceptance. Trusted keys persist atomically in a separate versioned metadata document. A changed key blocks and cannot be overwritten by the unknown-key acceptance method. Reset removes trust; a subsequent connection must still be independently verified and explicitly accepted. A corrupt trust document blocks loading rather than silently discarding previous trust. The asynchronous transport validator completes without holding a networking event loop open for UI interaction.
