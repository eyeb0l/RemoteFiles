# Save Original to Files

The reader has a standalone **Save Original to Files** toolbar action. It streams
the remote file to a private temporary directory, then presents the native Files
export picker as a copy. The file is never decoded as preview text, highlighted,
or downsampled. Exact bytes and the selected filename/extension are preserved,
including a selected symlink alias after its preview resolves to a canonical file.
Unsupported preview types and empty files can still be exported.

Only regular files can export, including files outside the connection’s starting
folder. The file and its folder must still resolve to exactly the canonical paths
you chose, so a file or folder replaced by a symbolic link leading elsewhere is
rejected. Saved search results
must remain inside their original canonical index root instead.
The SFTP transport checks REALPATH for the configured root and target, rejects
escaping symlinks, rechecks stable root/target paths after opening, reads metadata
from the open handle, and enforces the 128 MiB limit on every received chunk. The
exporter also checks advertised, returned and final disk size. There is at most
one transfer or prepared output. Preparation times out after 180 seconds. A
cancelled worker cannot publish a late file or permit an overlapping transfer
until it drains. If the server doesn't confirm closing the transfer within 5 seconds,
as when the network has gone, the SSH connection is closed so the drain completes
locally. Disconnect retires the transport and drains the old exporter before
creating a replacement.

This confinement is a client policy for a trusted SSH server. Portable SFTP v3
cannot atomically open a child beneath an anchored directory without following
links, so an account namespace controlled by a concurrent adversary requires a
server-side jail, immutable root, or an atomic server helper.

The action changes to **Cancel Export Preparation** during download. Navigation
away, backgrounding, disabled state, selected input changes and exporter/service
replacement invalidate preparation and dismiss a prepared picker. Temporary
files have private permissions and iOS complete-file protection, are excluded
from backup, and are removed on picker completion/cancel/dismissal. Prepared
files expire after ten minutes; abandoned previous-process outputs are removed
on next exporter use. The destination copy belongs to the user’s chosen Files
provider after the native picker completes.

The existing image **Share** action continues to share downsampled display
pixels. Use **Save Original to Files** when original image or PDF bytes matter.

## Verification

`OriginalFileExportTests` exercises exact Unicode/CRLF/whitespace/binary bytes,
filename and canonical-alias preservation, empty/unknown-size files, byte bounds,
nonregular entries, confinement, unsafe filenames, cancellation, single-transfer
serialization, stale leases, timeout, expiry and prior-process cleanup. SFTP
fixture tests cover real exact-byte streaming and canonical symlink escape.
`AppModelLifecycleTests` checks production background cancellation/drain, cache
clearing and replacement exporter behavior with an in-process transport. These
checks do not establish physical app background socket timing.

The ordinary demo UI suite checks native picker cancellation/dismissal, reopening and continued
reader actions. A real save into a Files provider, reopened byte/name comparison,
physical background/disconnect during preparation and picker presentation, and
accessibility gestures remain explicit acceptance steps. See
[automated acceptance](AUTOMATED_ACCEPTANCE.md) for the runner and required evidence.
