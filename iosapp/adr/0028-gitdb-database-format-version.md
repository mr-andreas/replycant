# ADR-0028: GitDB database format version

## Status

Accepted

## Context

GitDB already versions per-manifest schemas (`apiVersion`) and the
encryption envelope (`REPLYCANT-ENC-V1`). It has no marker for the
repository layout itself: where manifests live, how KEK epochs are
stored, or how keys are unwrapped.

A future layout change would otherwise look like a generic decrypt or
path-not-found failure. Existing clients would keep writing old-format
data into a repo that had moved on.

This product is in alpha with no backwards-compatibility requirement.
Existing installations wipe state and start fresh.

## Decision

Every GitDB repository carries plaintext `gitdb/version` containing a
single integer. This binary pins version `1`.

1. **Reject-only.** Clients never branch on the number to select a
   decryption or path-layout code path. The file is unauthenticated, so
   a tampered value may only deny service.
2. **Exact equality.** Missing, malformed, or any other integer is
   fatal. Absent is not treated as "assume current."
3. **Per-sync.** iOS `ManifestSyncEngine.syncToHead` and webapp
   `SyncEngine` check the commit they are about to read. Rewind past a
   format change is blocked with a distinct error and does not move
   refs.
4. **No server enforcement.** gitd stays format-agnostic. A stale
   client reads the bumped marker and refuses before push.

iOS bootstrap and the integration seeder write the marker in the
initial commit. `git-replycant`, `replycant-importer`, and the
provisioner refuse a mismatch.

## Consequences

### Positive

- The first real layout change can bump the integer and have every
  current client fail closed.
- Manifest `apiVersion` stays scoped to resource schemas.

### Negative

- Version `1` does not protect already-shipped clients that ignore the
  file. Enforcement starts when the value is bumped to `2`.
- Existing repositories without the marker must wipe and re-onboard.

## References

- ADR-0023: Mandatory Encryption Without Plaintext Fallback
- [Database format version](../../docs/docs/gitdb/database-version.md)
