# Private keys in text files

[← Documentation index](README.md)

Any file can hold a private key: an extensionless `id_rsa`, a hidden `.server.key`, a `server.pem.txt`, or a log someone pasted a key into. RemoteFiles reads text files by their content, so it looks for keys in the content too. A key it recognizes is hidden before the text reaches a view, a cache or a search index.

[Certificate files](CERTIFICATE_PREVIEWS.md) such as `.pem` have their own route and never become text at all.

## What you see

| The file holds | What opens |
| --- | --- |
| Only private keys | **Contains a Private Key**, with no text. There is no Source, Find, Copy Source or reading position. |
| A key among other text | The document, with the key's text replaced by `•` and a notice above it saying how many keys are hidden. Everything else reads, renders and searches as usual. VoiceOver reads a line of dots as a count, such as "70 dots". |
| Text that only mentions a key | The document, unchanged. |

**Save Original to Files** and **Share Original** still copy the whole file, key included. They are explicit, and the notice says so.

There is deliberately no way to reveal a key in the app. Revealing would put it back in the state that Find, Copy Source, the document cache and VoiceOver read, and each would need its own exception. Saving the original covers that need, outside the app.

To see both states, open **TLS certificates** in Explore Demo and choose `Deploy notes.txt` or `id_demo`. Their keys are synthetic.

## What counts as a key

Detection is `PrivateKeyRedaction` in `RemoteFilesCore`. These are recognized:

- PEM blocks whose label contains `PRIVATE KEY`, in any case, including `RSA`, `EC`, `DSA`, `ENCRYPTED`, `OPENSSH` and PGP's `PRIVATE KEY BLOCK` and older `SECRET KEY BLOCK`, with or without headers like `Proc-Type`.
- SSH.COM `---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----` blocks.
- PuTTY `.ppk` content: the private lines and their MAC. Its public lines stay visible in a longer document.
- A whole PEM key encoded as base64, such as `client-key-data` in a kubeconfig or `tls.key` in a Kubernetes secret. A certificate beside it stays visible.
- The body of an OpenSSH key without its markers.

**A marker isn't enough.** Documentation, tests and this repository's own source mention the markers, so a key needs base64 after its marker: at least 40 characters, on a line with a run of at least 32 that isn't a plain identifier, and which makes up most of that line. A block with an end marker is judged as a whole, and most of it must be key text. One without an end marker, such as a key cut off at the end of a file, ends at its first line that isn't key text.

The marker can be surrounded by almost anything real files do: indentation, CRLF, comment and mail prefixes, quoted strings in source code, log timestamps, HTML line breaks, a line flattened with spaces, and JSON with escaped `\n` or `\/`, as in a Google service account file.

The markers themselves stay, along with headers such as `DEK-Info`, so you can see that a key was there. Searching for `PRIVATE KEY` finds a document with a key in it, at the right line. It doesn't find a file that holds nothing but a key.

### What decides this design

Measured on 6 November 2026 with a prototype of this rule, over 231,203 text files from this repository, Homebrew and `/usr/share`. 52 distinct files that would open as text contained a marker.

| Approach | Result for those 52 files |
| --- | --- |
| Refuse on a marker | All 52 unreadable, including 7 of this repository's own source files, the OpenSSL manual and npm's configuration docs. |
| Refuse on a real-looking block | 19 unreadable, one of them 109 KB for about 2 KB of example keys. |
| Hide key blocks | 33 unchanged. 19 readable with an example key hidden: a median of 4.3% of the file, at most 38%. |

These are package trees rather than real servers, so they measure false positives better than they measure every way a key can appear.

## What this doesn't catch

This recognizes key formats. It isn't a secret scanner, and a format it doesn't know is shown as text, as it always was.

- JSON Web Keys, WireGuard and age keys, API tokens and passwords aren't recognized.
- A key in PKCS #8 without its markers isn't recognized, because nothing distinguishes it from other base64.
- A key wrapped at under 32 characters a line isn't recognized.
- A key under a prefix longer than the key text beside it, such as a long log prefix, is found only when each line ends with at least 40 characters of the key. Its short last line is found when it starts in the same column as the lines above; under a prefix of varying width it stays visible.
- A key written with HTML entities in place of its dashes (`&#45;&#45;&#45;&#45;&#45;BEGIN …`) in an `.html` file isn't recognized in the source, and the rendered preview decodes the entities and shows it.
- An example key in a tutorial is hidden, because it can't be told from a real one. Save the original to read it.
- UTF-16 or Latin-1 text isn't checked, because it never opens as text. It shows **Can't display this file**.
- A key in an image or on a PDF page is still visible when you open that file. Text extracted from them for search is checked a page at a time, so the part of a key that continues onto another page can reach a saved index, and OCR can misread a key so that it no longer matches.
- A `.key` file is unchanged: it has no preview and is never read for search.
- A saved offline copy keeps the file's original bytes in the protected library, as do folders saved offline that happen to include a key. They are hidden when read, not removed.
- Bytes are in memory while a file is read and decoded, and are then dropped.

## Where it applies

`DocumentPolicy.decode` hides keys, and every text route goes through it.

| Route | What happens |
| --- | --- |
| Reader and offline reader | Only hidden text reaches the view, Find, Headings, Copy Source and static HTML or SVG rendering. |
| Document cache | A document with a key isn't cached, and an older copy of its path is dropped. It is read again next time. Neither is text the app couldn't decode, since that can't be checked. |
| Reading positions | The saved hash covers the hidden text, so it no longer depends on a key. Offsets and line numbers don't change, because each hidden character becomes one `•` and line breaks stay. A document with a key starts from the top once after this change, as its hash is different. Other files keep their place. |
| Content search over SFTP | Keys are hidden before matching, and before a search clips text to its budget. |
| Server search helper | It returns a whole file if its bytes match, and the app decodes and matches it again, so a key's text can't become a result even from a hostile server. The helper itself is unchanged. |
| Saved search indexes | A key file is indexed with no text and doesn't make an index partial. An index saved by an older version is cleaned and rewritten on disk as soon as it is next read, because updating it would otherwise keep the text of an unchanged file indefinitely. |
| Markdown images | A reference such as `![](id_rsa)` could download any file into the [image cache on disk](REMOTE_IMAGES.md). A file not named as media now has to be a real image, or it is discarded. An older copy goes when that reference is next opened, or with the cache's normal retention. A key named like a picture, such as `key.png`, isn't checked. |

## Limits

Detection scans the whole of the 2 MiB a text preview can read. A larger file isn't read as text at all, so a marker can't fall past the end of a read. The scan is a single forward pass, so hostile input stays linear. Hiding a character takes three bytes instead of one in UTF-8, so a document with large keys in it uses a search's text budget slightly sooner.

## Tests

`PrivateKeyRedactionTests` covers formats, encodings, what must stay untouched, offsets and hostile input, and `PrivateKeyRouteTests` the routes through the policy. `FileContentSearchTests`, `ServerFolderSearchTests`, `SearchIndexStoreTests`, `SearchDocumentExtractorTests`, `OfflineFileTests`, `RemoteResourceTests` and `AppModelLifecycleTests` each cover their own route, including the real helper script. Keys in the tests are pseudorandom bytes, and markers are assembled at run time so secret scanners don't flag them.
