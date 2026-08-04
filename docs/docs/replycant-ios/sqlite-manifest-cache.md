# SQLite Manifest Cache

Replycant iOS persists manifests in SQLite (via GRDB) through GitDB so timeline and manifest reads are local, deterministic, and fast across app launches.

## Components

- `ManifestDatabase`: stores registered manifest kinds in `manifests_{kind}` tables plus sync metadata.
- `ManifestSyncEngine`: syncs git commit transitions into database mutations.
- `ManifestRegistry`: app registers manifest kinds, extracted SQL columns, and indexes.
- `DefaultManifestManager`: runs app SQL queries through GitDB's generic query API.
- `TimelineManager`: consumes pagination and change events for sparse timeline rendering.

## Data Flow

```mermaid
flowchart TD
    SyncEngine["ManifestSyncEngine"] -->|"applyMutation / replaceAll"| ManifestDB["ManifestDatabase"]
    ManifestDB -->|"publishes ManifestDatabaseChange"| TimelineMgr["TimelineManager"]
    TimelineView["TimelineView"] -->|"ensureLoaded(around: index)"| TimelineMgr
    TimelineMgr -->|"count / offset page / cursor page / thumbnail batch via SQL"| ManifestDB
```

## Sparse Timeline Loading

- Timeline length is based on `countTimelineOriginals`.
- Grid cells are indexed by `0..<totalCount`.
- `TimelineManager` keeps one contiguous loaded region:
  - `loadedOffset` (global index of first loaded item)
  - `loadedItems`
  - `olderCursor` / `newerCursor`
- Random jump: clear region and load via `loadTimelinePage(offset:limit:)`.
- Sequential scroll: extend via `loadTimelinePage(before:)` or `loadTimelinePage(after:)`.
- New thumbnail sets are loaded with `loadThumbnailsByOriginalRefs` (`[String: ThumbnailSetManifest]`).

## Reactive Change Publishing

After every write, `ManifestDatabase` emits:

- `.incremental(ManifestMutation)` for surgical updates.
- `.fullReplace` for full cache rebuild/reset.

`ManifestMutation` includes:

- `added: [any Manifest]`
- `removed: [(kind: String, id: String)]`

This lets `TimelineManager` rebuild sparse state deterministically while app-specific projections remain query-driven.
