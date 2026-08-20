# ADR-0027: Pre-hydration bootstrap commits

## Status

Accepted

## Context

ADR-0016 requires every HEAD mutation to route through GitDB and to
synchronize the SQL manifest cache in the same operation. Recovery
needs to commit a new device key and re-wrapped KEK epochs immediately
after a shallow clone, before any index exists.

Calling `commitFiles` on that path triggered a full hydration because
the cache had never been synced. Recovery then wiped the cache and
hydrated again after push, so the first index build was discarded and
the device-key push waited on it.

## Decision

Keep ADR-0016's rule that HEAD mutations go through GitDB. Add
`GitDatabase.commitFilesWithoutSync` as a bootstrap-only exception:

- Valid only while `syncedCommitHash` is nil.
- Throws if the cache has already been hydrated.
- Callers must converge with `syncToHead` (or `hydrateIndex`)
  immediately afterwards.

Recovery uses this API for the key-rewrap commit, pushes, then builds
the media index once.

## Consequences

- Recovery no longer builds the media index twice.
- The new device key reaches the server before indexing starts.
- A runtime guard prevents later call sites from skipping sync.
