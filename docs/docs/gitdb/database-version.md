# Database format version

GitDB repositories carry a plaintext marker at `gitdb/version`. The file
contains a single integer. Clients and tools are built against one version
and refuse to open any other.

This marker versions the **repository layout and crypto handling**, not
manifest schemas. Manifest shape stays under each resource's `apiVersion`.
Examples of a database-format bump:

- changing where manifests or binaries live
- changing how encryption keys are stored or unwrapped

## Format

```
gitdb/version    # plain text: "3\n"
```

Rules:

- one decimal integer, minimum `1`
- optional single trailing newline
- no sign, leading zeros, comments, or BOM
- a missing file is an error; a present file that fails these rules is
  malformed
- absence must be proven from a readable commit tree; a failed object
  read is a retryable sync error, not a missing-marker verdict

## Compatibility

The check is reject-only. No client branches on the number to pick an older
decryption path. The file is unauthenticated plaintext, so a hostile server
can change it; the only safe response is to stop.

Clients accept only the current version. A newer marker means update the
app. An older marker means restart the library server so it can upgrade
the database. The client keeps pulling and recovers once gitd migrates;
a newer, missing, or removed marker still stops sync. A malformed or
missing marker means this library cannot be opened: create a new library.
A cache that recorded a higher format than the marker now on the server
is treated as tampering: restore the marker. An unreadable marker is a
retryable sync failure, not a verdict: absence is only concluded after
the commit tree itself is readable.

## Boot-time migration

gitd migrates `main` before it serves anything. An empty repository is
left alone, so the first device can write the current marker. A missing,
malformed, or newer marker stops gitd. When the stored version is already
current, gitd does nothing.

Otherwise it applies each step from the stored version up to the current
one, in order, and publishes them as a single commit. Clients never see
an intermediate layout. A step may change only plaintext data: gitd does
not hold the KEK. The step from 1 to 2 rewrites each `pubkeys/*.pub` and
`*.age` pair into one key set. It copies the keys as they are, and it
stops without moving `main` if a key file is unpaired or unreadable,
because dropping it would revoke a device.

The step from 2 to 3 moves every `manifests/{space}/...` file to
`encryptionspaces/{space}/manifests/...` and every `binary/{space}/...`
file to `encryptionspaces/{space}/binary/...`. File contents do not change,
so ciphertext, LFS pointers, and LFS objects stay valid, and no key is
needed. Every moved space uses the global key set. The step stops without
moving `main` if a file sits directly under `manifests/` or `binary/`, or
if `encryptionspaces/` already exists. A library at version 1 goes through
both steps in the same commit.

The commit advances `main` only if it still points at the commit gitd read.

Clients record the format they observed at the synced commit, not the
compiled pin. Observed greater than stored discards the cache and fully
rehydrates. Observed equal to stored stays incremental. They do not
apply an incremental tree diff across a layout change. If this device
also has unpublished commits, iOS refuses to rebase them and offers
discard-and-reset-to-remote instead of a full wipe.

## Who writes and who checks

iOS writes `gitdb/version` in the first-device bootstrap commit. The
integration seeder writes the same file. Every sync, clone, filter,
import, and provision path then reads the commit or worktree it is about
to use and refuses any value other than the current version. gitd runs
the boot-time migration before it accepts a connection.
