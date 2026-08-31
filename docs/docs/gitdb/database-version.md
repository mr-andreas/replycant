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
- a missing or malformed file is fatal; clients do not assume the current
  version

## Compatibility

The check is reject-only. No client branches on the number to pick an older
decryption path. The file is unauthenticated plaintext, so a hostile server
can change it; the only safe response is to stop.

A newer marker means update the app. A missing, malformed, or older marker
means this library cannot be opened: create a new library. Resyncing the
same remote will not help. gitd does not enforce the marker; it remains
format-agnostic storage.

## Who writes and who checks

iOS writes `gitdb/version` in the first-device bootstrap commit. The
integration seeder writes the same file. Every sync, clone, filter, import,
and provision path then reads the commit or worktree it is about to use and
refuses a mismatch.
