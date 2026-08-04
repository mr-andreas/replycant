# 0005 — Flat Grid Timeline

**Status:** Accepted

## Context

The webapp timeline grouped media items by calendar day, rendering a 36px date header before each day's grid rows. This diverged from the iOS app's flat grid and added layout complexity: the layout engine had to build per-day segments, maintain `anchorTopByKey` lookup maps, and binary-search through heterogeneous row types. The `buildMonthIndex` function scanned the full item list on every render, which would not scale to 100k-item timelines.

## Decision

Replace the day-grouped timeline with a flat grid matching the iOS layout:

- **Arithmetic layout.** All positions derive from `(itemIndex, columnCount, tileSize)` with O(1) computation — no precomputed maps or binary search.
- **Adaptive column count.** Target ~5cm physical tiles using the CSS reference pixel (96 DPI). Column count adjusts as the viewport resizes.
- **Square tiles.** Tile height equals computed tile width, filling the grid edge-to-edge with a 2px gap.
- **Key-based scroll anchor.** The URL hash stores `#k=<itemKey>&o=<offsetPx>` instead of the day-based `#d=<dayKey>&r=<rowInDay>&o=<offsetPx>`. Item keys are stable across add/remove operations.
- **Derived store for month index.** The `timeline_month_counts` gitdb derived store maintains `{ monthKey, count, firstTakenAt }` rows atomically alongside manifest writes. The UI reads this small precomputed table instead of scanning items at render time.

## Consequences

- Layout computation is O(1) per position instead of O(n) to build the full layout object.
- Month index reads are O(1) from IndexedDB instead of O(n) scans in the React render path.
- Old `#d=...` URL hash anchors no longer resolve (acceptable in alpha — no backwards compatibility).
- The `buildMonthIndex` function and `dayKey`-based types (`HeaderRow`, `firstImageRowByDay`, `buildAnchorKey`) are removed.
- Cross-platform consistency: webapp and iOS now use the same flat grid layout.
