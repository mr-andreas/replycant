# ADR-0014: Manifest Database Cache for iOS

## Status

Accepted

## Context

The iOS app currently reads manifests directly from git blobs and relies on an in-memory cache (`CachedManifestLoader`) to reduce repeated YAML parsing. This approach has two problems:

1. Manifest reads after app restart are cold and require full git traversal/parsing again.
2. Pull and commit flows require each caller to manually clear/reload caches.

The web app already uses a persistent manifest cache with commit-based synchronization. iOS needs the same behavior so all reads come from a local database while git remains the source of truth for writes and history.

## Decision

iOS will persist manifests in a SQLite database (GRDB) and synchronize it to git HEAD.

- All manifest reads are served from the database.
- Writes are git-first: commit to git, then update database state.
- Pull/rebase flow synchronizes the database from the previous synced commit to new HEAD using manifest-tree diffing.
- Full hydration supports progress callbacks for UI progress bars.
- Timeline queries exclude rows where `guessedTakenAt` is null.
- Timeline ordering is deterministic: `ORDER BY guessedTakenAt, id`.
- Original manifest dedup checks use indexed `sha256`.

## Consequences

### Positive

- Faster warm starts and repeated reads due to persistent local cache.
- Deterministic timeline ordering and direct SQL filtering for timeline eligibility.
- Cleaner callers through a higher-level `ManifestManager` interface.
- Incremental sync avoids full rehydration on small pull deltas.
- Content-based dedup by SHA-256 avoids re-uploading renamed or cross-device duplicates.

### Negative

- Additional storage layer and synchronization logic increase complexity.
- Schema/index changes require migration handling.
- Sync correctness now depends on commit-transition logic and database mutation integrity.

## References

- ADR-0003: Manifest-based Git Database
- ADR-0012: KEK/DEK Envelope Encryption with age Key Wrapping
