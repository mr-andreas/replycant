# ADR-0038: Key sets and an exact database version

## Status

Accepted. Supersedes the version-0 stand-in and the "no server
enforcement" rule in
[ADR-0028](0028-gitdb-database-format-version.md).

## Context

ADR-0028 treated a missing `gitdb/version` as version 0 and left gitd
format-agnostic. Every library now has a marker, and format 2 replaces
the loose `pubkeys/*.pub` and `*.age` files with one key set per
holder. A client that still accepts a missing marker would open a
library the server no longer considers valid.

The server migration cannot seal a display name, because gitd does not
hold the KEK. Each device already stores the name it shows locally.

## Decision

1. Clients accept only the compiled database version. A missing or
   malformed marker is an error. An older marker tells the user to
   restart the library server. A newer marker tells them to update
   the app.
2. This device writes and reads `pubkeys/<name>.yaml` key sets. The
   display name is sealed with the KEK. A key set with no display
   name, or one this device cannot open, is shown as its slug.
3. After a sync, if this device's own key set has no display name, the
   device commits one from the name it already stores. It does not
   rename anyone else's key, and a failure does not fail the sync.

## Consequences

### Positive

- A library without a marker no longer looks like a supported old
  format.
- A library migrated by the server gains this device's name on the
  next sync, without a second migration tool.

### Negative

- A build that still accepts version 0 or version 1 will not open a
  library this app creates, and this app will not open a library
  those builds last wrote until the server has migrated it.

## References

- ADR-0028: GitDB database format version
- [Encryption](../../docs/docs/gitdb/encryption.md)
