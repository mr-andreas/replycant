# GitDB Package

GitDB is the iOS app's local Swift package that owns git-backed SQLite storage, manifest sync, key handling, and encrypted commit paths. LibGit2 stays vanilla git; the app owns manifest types such as `Original` and `ThumbnailSet`.

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

## Remote Operations

`GitDatabase` owns push and pull so remote updates share the repository
mutation lock with local commits:

- `push` / `pull` wait for the lock
- `tryPush` / `tryPull` return false when another mutation is already running
- An omitted branch name resolves to `HEAD` or `main`

Photo uploads go through `GitDatabase.commitManifests` so they share the
same `gitdb/version` guard as every other write.

## Commit Flow

`GitCommitService` remains responsible for:

- Building manifest and binary file paths
- Encrypting manifest payloads at commit time
- Writing commits and encrypted LFS pointers

Encrypted LFS objects use `EncryptedLFSPointer` so kek-epoch and wrapped-DEK
metadata stay in GitDB. LibGit2 only transports opaque bytes.

After successful writes, sync updates database rows so reads converge on HEAD.
