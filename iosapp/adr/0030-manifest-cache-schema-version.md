# ADR-0030: Manifest Cache Schema Version

## Status

Accepted

## Context

The SQLite manifest cache is a projection of the git repository. ADR-0014 made git the source of truth and the database a rebuildable index. Adding a column still breaks that, because tables are created with `CREATE TABLE IF NOT EXISTS`: an existing install keeps the old table and the new column is never added.

Rebuilding the index from git is already how a fresh install and a wipe work. A schema change can use that same path instead of a migration.

## Decision

`ManifestRegistry` carries an integer `schemaVersion`. The app sets it, and bumps it when registered columns, indexes, or the base table layout change.

`ManifestDatabase` stores that integer in SQLite's `user_version`. On open, any other value erases the database in place and records the new version. The erase drops the synced-commit marker, so the next sync takes the existing full-hydration path.

Launch checks that marker when a git checkout exists. If it is missing, the app shows the existing index-building progress and hydrates from the local repository. That covers a schema bump and a hydration that was interrupted.

This version is separate from `cacheFormatVersion`, which tracks the repository's `gitdb/version`.

## Consequences

### Positive

- A schema change does not need migration code or a reinstall.
- An older build opening a newer cache discards it instead of reading a shape it does not understand.
- An interrupted rebuild retries on the next launch.

### Negative

- The first launch after a bump rebuilds the whole index, which takes as long as the initial hydration.
- Erasing happens while opening the database, on the caller that first opens it.
