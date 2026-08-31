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
gitdb/version    # plain text: "1\n"
```

Rules:

- one decimal integer, minimum `1`
- optional single trailing newline
- no sign, leading zeros, comments, or BOM
- a missing file is version `0` in code, the stand-in for old alpha
  libraries; a present file that fails these rules is malformed
- absence must be proven from a readable commit tree; a failed object
  read is a retryable sync error, not a missing-marker verdict

## Compatibility

The check is reject-only. No client branches on the number to pick an older
decryption path. The file is unauthenticated plaintext, so a hostile server
can change it; the only safe response is to stop.

Clients accept `{0, current}`. A newer marker means update the app. An
older present marker means run the migration tool, then let the client
rebuild its local cache. A malformed marker means this library cannot
be opened: create a new library. A marker that disappears after this
device already synced a higher format is treated as tampering: restore
the marker. An unreadable marker is a retryable sync failure, not a
verdict: absence is only concluded after the commit tree itself is
readable. gitd does not enforce the marker; it remains
format-agnostic storage.

Clients record the format they observed at the synced commit, not the
compiled pin. Observed greater than stored discards the cache and fully
rehydrates. Observed equal to stored stays incremental. They do not
apply an incremental tree diff across a layout change. If this device
also has unpublished commits, iOS refuses to rebase them and offers
discard-and-reset-to-remote instead of a full wipe.

## Who writes and who checks

iOS writes `gitdb/version` in the first-device bootstrap commit. The
integration seeder writes the same file, or omits it when seeding an
old-alpha fixture (`--database-version=0`). Every sync, clone, filter,
import, and provision path then reads the commit or worktree it is about
to use and refuses a value outside `{0, current}`.
