# GitDB Package

GitDB is the iOS app's local Swift package that owns git-backed SQLite storage, manifest sync, and encrypted commit paths.

## Purpose

GitDB provides one transactional boundary for manifest persistence:

- Creates and owns one SQLite database file
- Synchronizes git commit transitions into SQL rows
- Keeps pull/commit operations and DB convergence coupled
- Exposes generic typed manifest queries

GitDB is schema-agnostic: app code defines manifest schemas through registration.

## Registration API

At startup, the app registers each manifest kind with `ManifestRegistry`:

- Kind decoder (`kind` string -> `Manifest` type)
- SQL columns to extract from the manifest payload
- SQL indexes for those extracted columns
- Extractor closure (`Manifest` -> `[column: ManifestSQLValue]`)

This keeps app-specific schema details (for example `originalRef`, `guessedTakenAt`, `sha256`) out of GitDB internals.

## Dynamic Table Generation

`ManifestDatabase` creates one table per registered kind:

- Table name: `manifests_{kind}`
- Base columns: `id`, `deviceSpace`, `data`
- Registered extracted columns and indexes

`sync_metadata` is still used for synced commit hash tracking.

## Sync Flow

`ManifestSyncEngine` drives database convergence:

1. Read changed manifest YAML blobs between commits
2. Decrypt envelope payloads when needed
3. Extract `kind` and decode through `ManifestRegistry`
4. Extract registered SQL columns
5. Apply upserts/deletes across affected kind tables in one transaction

This preserves atomic multi-kind updates during pull.

## Query API

GitDB exposes generic query entrypoints:

- `query(T.self, sql:)` -> `[T]` (decodes from `data` column)
- `queryCount(sql:)` -> `Int`

The app owns SQL query shape and pagination logic, while GitDB owns execution and decoding.

## Change Notifications

`ManifestDatabase` publishes:

- `.incremental(ManifestMutation)` with `added` and `removed`
- `.fullReplace` for full-cache rebuild/reset

Timeline and sync UI code subscribe to these events to refresh local state.

## Commit Flow

`GitCommitService` remains responsible for:

- Building manifest and binary file paths
- Encrypting manifest payloads at commit time
- Writing commits and LFS pointers

After successful writes, sync updates database rows so reads converge on HEAD.
