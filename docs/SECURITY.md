# Security

## Reporting a vulnerability

Please report a suspected vulnerability privately, through
[GitHub's private vulnerability reporting](https://github.com/eyeb0l/RemoteFiles/security/advisories/new),
not in a public issue or pull request.

Useful in a report: the version or commit, what an attacker needs (a server you connect to,
a file you open, a position on the network), what they gain, and steps or a file that shows it.

## What the app is meant to guarantee

RemoteFiles is an SFTP browser whose browsing is read-only and whose writes are each asked for. These are the properties to hold it to:

- It connects only to a host whose key you have accepted, and tells you when that key changes.
- Private keys stay in the Keychain on the device, and are not shown, copied or indexed when
  they appear in a file.
- Browsing, reading, searching and downloading never write to the server. The app writes only when asked: an upload or a copy between servers, and installing a public key, which asks first.
- An upload or copy writes only inside the folder you chose, under a hidden partial name until it is complete, and never replaces a file there without your answer. It never removes or renames anything else. One limit: this relies on the server refusing a taken name, which a hard link (`hardlink@openssh.com`) does in one step. In a folder where hard links aren't available, on any server including OpenSSH, the name is checked and the file then renamed, and a file someone else creates under that name in the instant between the two can be replaced ([names that are already taken](TRANSFERS.md#names-that-are-already-taken)).
- A file or folder cannot make the app read outside the folder you opened, or write outside the folder you chose.
- Previews of HTML, Markdown and SVG run no script from the document and load nothing from the network.
- Every read, download, upload, copy and listing is bounded in size.

The other pages in this folder describe each of these and its limits, starting from the [reader](READER.md), [connections](CONNECTIONS.md) and [folder browsing](FOLDER_BROWSING.md).
