# Certificate previews

[← Documentation index](README.md)

Opening a certificate file shows a native summary of what it states: the fields a developer or sysadmin usually wants, without reaching for `openssl x509 -text`. It is a viewer. It does not evaluate trust, and it never shows a private key.

## What can be opened

| Extension | What happens |
| --- | --- |
| `.pem`, `.crt`, `.cer`, `.der` | A summary of each certificate, in PEM or DER. The content decides which, because `.cer` and `.crt` are commonly either. |
| `.p7b`, `.p7c` | A summary of each certificate in a PKCS #7 bundle, in PEM or DER. |
| `.csr` | A summary of a PKCS #10 signing request: its subject, key, signature algorithm and requested extensions. |
| `.p12`, `.pfx` | Not opened. These are password-protected containers that usually hold a private key, so the app asks for no password and explains that **Save Original to Files** (or **Share Original** for a saved copy) still works. |
| `.key` | Unchanged: no preview. Saving the original still works. |

A file is read by its structure, not its name, so a `.crt` holding a bundle or a `.der` holding a request still shows correctly. A file that is only named `pem`, with no extension, stays a text candidate like other extensionless files, and [a key in it is still hidden](PRIVATE_KEYS_IN_TEXT.md).

The summary shows each certificate's subject, issuer, validity dates, serial number, Subject Alternative Names, public key algorithm and size, signature algorithm, basic constraints, key usage, extended key usage, whether it is self-signed, and its SHA-256 and SHA-1 fingerprints. Hold a row to copy its value. A file with several certificates summarizes the first in full and lists the rest under **Also in This File**; each opens in a sheet. File order is kept, so a chain's leaf normally comes first, but nothing reorders a bundle to find one.

To see every state, open **TLS certificates** in Explore Demo. Its samples are synthetic.

## What the preview doesn't claim

Nothing here means a certificate should be trusted, and the summary says so.

- **No chain or signature check.** It doesn't verify signatures, build a chain, or check revocation. There is no green state, no seal and no "verified" wording.
- **Self-signed** means the issuer and subject names match. The signature itself isn't checked.
- **Validity** compares the dates with the device's clock: **Expired**, **Not Yet Valid** or **Within Its Dates**. That last state says only that today falls between the two dates.
- **Basic constraints** repeats what the certificate says about itself, whoever issued it. A certificate without them is shown as "not stated" rather than as a leaf.
- It never offers to install a certificate on the device.

## Private keys

A `.pem` can hold a private key beside its certificates, so these files have a different route from text documents.

- **The preview says so.** A file with a private key shows **Contains a Private Key** above any certificates, which are still summarized, and warns that saving or sharing the original copies the whole file.
- **Key blocks are skipped unread.** The scanner counts a block whose label contains `PRIVATE KEY` and never decodes its body, so the summary can only hold a count. Binary PKCS #1, PKCS #8, SEC 1 and DSA keys are recognized by shape, and also only counted.
- **There is no text route.** This kind has no Source view, Find, Headings, Copy Source or reading position, and `DocumentPolicy.decode` refuses it, including for files with a leading dot. The reader never holds these bytes as text.
- **The bytes aren't kept.** A connected read goes to the parser and is dropped. It doesn't use the document cache or the [image cache on disk](REMOTE_IMAGES.md), which also refuses these files if a Markdown image points at one. Only the summary is retained. An offline copy stays in the protected library you chose to save it to.
- **Save and share are explicit.** **Save Original to Files** and **Share Original** copy the whole file, key included.

### Search and private keys

Content search, saved search indexes and the server-side helper never read these extensions. `.pem` and the others are in `DocumentPolicy.searchExcludedExtensions`, because the helper otherwise treats any dotfile, such as `.server.pem`, as text. Before certificate previews, a hidden `.pem` counted as text in the reader and in search. An index saved then may still hold such a file's text on the device: searches now ignore it, and it goes the next time that index is updated or rebuilt. File names are still found by name search.

This route covers files recognized by extension. An extensionless `id_rsa`, a hidden `.server.key`, a `server.pem.txt` or a key pasted into any text file goes the text route instead, where the key is found by its content and hidden. See [private keys in text files](PRIVATE_KEYS_IN_TEXT.md).

## Limits

The parser reads untrusted bytes off the main actor. Damaged or hostile input gives a calm explanation instead of a crash.

| Limit | Value | When reached |
| --- | --- | --- |
| File | 2 MiB | **Too Large to Preview**; the transport stops reading. |
| A DER file or PKCS #7 bundle | 1 MiB | **Too Large to Preview**, or counted as unreadable in a PEM. Parsing costs about 100 bytes of memory per DER element. |
| One certificate | 256 KiB | Counted as unreadable; the rest of the file still shows. |
| Certificates in a file | 200 | The rest are counted as not shown. A key after the limit is still reported. |
| A displayed field | 1 KiB | Clipped with an ellipsis. Serial numbers show 64 bytes. |
| Name attributes | 32 per name | Counted as not shown. |
| Subject Alternative Names | 256 | Counted as not shown. |
| Extended key usages and extensions | 32 and 128 | Ignored past the limit. |

Every displayed string has control and formatting characters replaced with `�`, so a NUL in `bank.example\0.evil.example` or a right-to-left override can't disguise a name. An extension that can't be read is counted and the others still show. An unknown algorithm or attribute shows its object identifier. A certificate whose outline is damaged is counted as unreadable, and a file with nothing readable shows **No Certificate Found**.

PEM blocks are found by their markers in a single pass over the bytes, so any line ending, a block on one line, non-UTF-8 text around it, and a UTF-16 byte order mark all work. The label `TRUSTED CERTIFICATE` is read up to the end of the certificate, ignoring OpenSSL's settings after it. Bundles written with BER's indefinite lengths are accepted; a certificate must otherwise be DER.

## Why not swift-certificates or Security.framework?

Parsing uses `swift-asn1`, with a small field reader on top in `CertificatePreview.swift`. It was already in the lockfile at 1.7.3 through swift-crypto, so promoting it to a direct dependency added no new code to the app, and neither lockfile changed.

- **Security.framework** gives iOS little more than a subject summary and a public key.
- **swift-certificates** was evaluated at its source of 5 November 2026. `Certificate.PublicKey` throws `unsupportedPublicKeyAlgorithm` for anything but RSA, P-256/P-384/P-521 and Ed25519, and its RSA path goes through a swift-crypto initializer that rejects keys under 2048 bits, so the whole certificate fails. A viewer exists to show those certificates: a 1024-bit RSA root, a DSA key or an Ed448 key. It would also add about 18,000 lines of source, including chain verification this feature must not offer.
- **A wholly hand-written DER reader** would have meant writing tag and length parsing for hostile input, when swift-asn1 is tested, bounded to 50 levels and already linked.

The cost is about 750 lines here, including the summary types and name tables, which have to be kept correct by the tests rather than by a library. Those tests compare fields and fingerprints with OpenSSL's report, and truncate and corrupt real certificates.

PKCS #7 and CSR support were kept because they turned out cheap with that reader: about 20 lines each, with no new dependency. Decoding the fields needs no signature verification.

## Tests

`CertificatePreviewTests` and `CertificatePolicyTests` cover parsing, limits, hostile input, and the routes a key must not take; `FileContentSearchTests`, `ServerFolderSearchTests` and `RemoteResourceTests` check that search, the server helper and the disk cache refuse these files. Fixtures are synthetic, and key markers in test source are assembled at run time so secret scanners don't flag them.
