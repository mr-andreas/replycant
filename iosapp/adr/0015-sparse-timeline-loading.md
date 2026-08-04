# ADR-0015: Sparse Timeline Loading with Reactive Database Changes

## Status

Accepted

## Context

The iOS timeline previously loaded all timeline originals and thumbnails into memory before rendering the grid. As libraries grow, that approach increases startup latency and memory pressure, and makes random-access scrolling expensive.

At the same time, incremental database writes (upload, pull, delete) need to update visible timeline state without forcing full reloads.

## Decision

iOS uses sparse timeline loading backed by `ManifestDatabase`:

- Timeline UI size comes from `countTimelineOriginals` (`COUNT(*)` over timeline-eligible originals).
- A single contiguous loaded region is maintained in `TimelineManager`.
- Random-access jumps use offset queries (`LIMIT/OFFSET`) and reset the loaded region.
- Sequential scrolling extends the current region using cursor queries keyed by `(guessedTakenAt, id)`.
- Thumbnail manifests are fetched in batches by `originalRef` for newly loaded originals.
- `ManifestDatabase` publishes `ManifestDatabaseChange` after writes:
  - `.incremental(ManifestMutation)` for surgical changes.
  - `.fullReplace` for full rebuild/reset paths.
- Incremental mutations classify manifests into `added`, `updated`, and `removed`, where `removed` carries full manifest bodies fetched from old commit state before delete.

## Consequences

### Positive

- Fast initial timeline startup with bounded memory usage.
- Stable sequential pagination under unrelated inserts/deletes through cursor-based loading.
- Immediate UI reactivity for uploads/pulls/deletes via one database change stream.
- Avoids expensive count re-queries on incremental mutations.

### Negative

- More complex timeline state management (loaded offset/region/cursors).
- Additional query surface in `ManifestDatabase` and loader protocols.
- Full-screen paging and preload behavior must tolerate unloaded indices.

## References

- ADR-0014: Manifest Database Cache for iOS
- `iosapp/iosapp/Managers/Manifest/ManifestDatabase.swift`
- `iosapp/iosapp/Managers/TimelineManager.swift`
