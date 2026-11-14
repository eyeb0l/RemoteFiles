# Security

## Reporting a vulnerability

Please report a suspected vulnerability privately, through
[GitHub's private vulnerability reporting](https://github.com/eyeb0l/RemoteFiles/security/advisories/new),
not in a public issue or pull request.

Useful in a report: the version or commit, what an attacker needs (a server you connect to,
a file you open, a position on the network), what they gain, and steps or a file that shows it.

## What the app is meant to guarantee

RemoteFiles is a read-only SFTP browser. These are the properties to hold it to:

- It connects only to a host whose key you have accepted, and tells you when that key changes.
- Private keys stay in the Keychain on the device, and are not shown, copied or indexed when
  they appear in a file.
- Browsing never writes to the server. Installing a public key is the one exception, and asks first.
- A file or folder cannot make the app read outside the folder you opened.
- Previews of HTML, Markdown and SVG run no script from the document and load nothing from the network.
- Every read, download and listing is bounded in size.

The feature pages under [`docs/`](docs/) describe each of these and its limits.
