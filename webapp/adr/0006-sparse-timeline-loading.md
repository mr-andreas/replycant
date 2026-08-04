# 0006 — Sparse Timeline Loading

**Status:** Accepted

## Context

The timeline eagerly loaded all Original and ThumbnailSet manifests into memory on startup. For a 20k-item library this took ~7 seconds (6s in pointer resolution alone for 90k+ records) and held all items in memory permanently. The grid only needs ~40 visible tiles at any time.

## Decision

Replace eager full-load with sparse on-demand loading:

- **Summary-only startup.** On fullReplace, only the month index (from derived store) and total count are loaded. No `getAll` on Originals or ThumbnailSets.
- **Sparse window.** A single contiguous region of `TimelineItem[]` is kept in memory with a known `loadedOffset`. Tiles outside this window render as skeleton placeholders.
- **Cursor-based pagination.** Pages are fetched using `{ takenAt, key }` cursor markers via IDB index range queries, not numeric offsets. This prevents position drift when items are added/removed during sync.
- **Month index with `globalOffset`.** Each `MonthEntry` carries a cumulative `globalOffset` enabling O(1) month jumps and O(log n) index-to-month lookup without item data.
- **Incremental mutation.** On sync, mutations are applied to the loaded window in-place: `loadedOffset` is adjusted for adds/removes before the window, items within the window are inserted/removed/updated, and edge cursors are refreshed.

## Consequences

- Startup time drops from ~7s to <100ms for summary loading, plus ~50ms for the first visible page.
- Memory usage is bounded by the loaded window size (~100-200 items) instead of the full library.
- The `FullscreenViewer` receives the sparse window instead of the full items array; items outside the window are unavailable until paged in.
- `timelineOriginals` and `timelineThumbnails` are removed from `LibraryRuntimeState`.
- The architecture mirrors the iOS app's `TimelineManager` sparse loading pattern.
