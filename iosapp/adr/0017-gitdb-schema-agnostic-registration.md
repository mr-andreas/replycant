# ADR-0017: GitDB Schema-Agnostic Registration Architecture

## Status

Accepted

## Context

GitDB contained app-specific schema types (`OriginalManifest`, `ThumbnailManifest`) and hard-coded table/query behavior. This made GitDB non-reusable and coupled storage internals to Replycant media domain details.

At the same time, the app requires a single SQLite database and transactional multi-table updates during pull/sync so commit transitions across multiple manifest kinds remain atomic.

## Decision

Adopt a registration-based architecture where:

- GitDB keeps ownership of one SQLite database and sync engine.
- The app registers manifest kinds in `ManifestRegistry` with:
  - Decoder by `kind`
  - Extracted SQL column definitions
  - Index definitions
  - Column extractor closures
- `ManifestDatabase` dynamically creates `manifests_{kind}` tables from registrations.
- `ManifestSyncEngine` decodes manifests via registry and applies upserts/deletes transactionally across all affected kind tables.
- GitDB exposes generic query APIs (`query`, `queryCount`) instead of app-specific query methods.

App-specific manifest schemas move to the app target.

## Consequences

### Positive

- GitDB no longer depends on app schema types.
- Pull/sync still update many manifest kinds atomically in one transaction.
- New manifest kinds can be added without modifying GitDB internals.
- App retains full control over indexed projections and query shape.

### Negative

- App code must maintain registration definitions and SQL query text.
- Query correctness now depends on alignment between registration columns and app SQL.
