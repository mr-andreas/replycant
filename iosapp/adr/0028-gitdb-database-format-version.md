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
single integer. This binary pins version `1`. An absent file is
version `0` in code, the stand-in for old alpha libraries.

1. **Reject-only.** Clients never branch on the number to select a
   decryption or path-layout code path. The file is unauthenticated, so
   a tampered value may only deny service.
2. **Accepted set.** Clients accept `{0, current}`, not exact equality
   and not `<= current`. A present file must still parse as an integer
   `>= 1`; `0` exists only as the meaning of absence. A future bump to
   `2` must not silently keep accepting `1`.
3. **Per-sync.** iOS `ManifestSyncEngine.syncToHead` and webapp
   `SyncEngine` check the commit they are about to read. Rewind into
   pre-marker history is allowed; rewind onto an unsupported integer
   is blocked.
4. **No server enforcement.** gitd stays format-agnostic. A stale
   client reads the bumped marker and refuses before push.
5. **Forward migration is append-only.** A later migration tool adds
   one commit that moves the layout and bumps the marker together.
   Clients persist the format they actually observed at the synced
   commit, not the compiled pin. Observed greater than stored forces
   full rehydration. Observed less than stored is a stripped marker
   and is refused. Unpublished local commits that cannot be rebased
   onto a new format are discarded only after the user confirms
   reset-to-remote.

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
- Existing repositories without the marker open as version `0` and
  keep working until a migration tool writes `1`.
- Clients must ship the cache-format checkpoint and reset-to-remote
  recovery before any repository is bumped to a new integer. A build
  cannot recognize a version that did not exist when it shipped.
- An older library on an updated client is no longer a dead end: the
  user runs the migration tool, then the client rehydrates.

## References

- ADR-0023: Mandatory Encryption Without Plaintext Fallback
- [Database format version](../../docs/docs/gitdb/database-version.md)
