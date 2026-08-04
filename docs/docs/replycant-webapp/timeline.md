# Timeline

The timeline is the main view of the webapp. It displays all media items in a flat, scrollable grid ordered by capture date (oldest at top, newest at bottom).

## Architecture

### Layout

The grid uses arithmetic layout — every item's pixel position is computed from its index, the column count, and the tile size. There are no precomputed layout objects or position maps.

Given a container width, the column count targets ~6.75cm physical tiles (using the CSS reference pixel at 96 DPI). Tiles are square with a 2px gap. All position calculations are O(1):

- `tileSize = (containerWidth - (colCount - 1) * gap) / colCount`
- `row(i) = floor(i / colCount)`, `y(i) = row(i) * (tileSize + gap)`
- `totalHeight = ceil(itemCount / colCount) * (tileSize + gap) - gap`

### Sparse loading

The timeline never loads all items into memory. Instead it only needs two pieces of summary data to lay out the grid:

- **Total item count** — derived from `SUM(monthEntry.count)` via the month index
- **Month index with `globalOffset`** — each `MonthEntry` has a cumulative `globalOffset` (the global index of its first item), enabling O(1) month jumps and O(log months) index-to-month lookup

Individual timeline items are loaded on demand into a **sparse window**: a single contiguous region of loaded `TimelineItem[]` with a known `loadedOffset` (global index of the first loaded item). Tiles outside this window render as skeleton placeholders.

### Cursor-based pagination

Pages are fetched using stable marker-based cursors (`{ takenAt, key }`) rather than numeric offsets. This prevents position drift when items are added or removed during sync:

- **Sequential scroll**: when the viewport nears an edge of the loaded window, the next page is fetched using the edge cursor
- **Random-access jump** (month tap, anchor restore): the window is reset and a fresh page is loaded starting from the month's `firstTakenAt`

### Virtualization

Only the rows in the visible viewport (plus an 800px overscan buffer) are rendered. A tall spacer div sets the scrollable area height to `totalHeight`. Visible rows are absolutely positioned with `transform: translateY()`. The visible row range is computed from `scrollTop` via O(1) arithmetic.

### Scroll persistence

The viewport position is persisted in the URL hash as `#k=<itemKey>&o=<offsetPx>`, where `itemKey` is the key of the item at the top of the viewport and `offsetPx` is the sub-row pixel offset. This anchor is:

- Written on scroll via `requestAnimationFrame`-throttled `history.replaceState`
- Restored on page reload by finding the item key in the loaded window
- Restored after layout changes via `pendingAnchorRef`

Item keys are used instead of indices because keys are stable across add/remove operations during sync.

### Month navigation

A sidebar on the right shows month labels grouped by year. Clicking a month scrolls the grid to that month's first item using the `globalOffset` from the month index (O(1) lookup). The current month is derived from the top-visible global index via binary search on the `globalOffset` array.

Month data comes from a **gitdb derived store** (`timeline_month_counts`) that maintains `{ monthKey, count, firstTakenAt }` rows in IndexedDB, updated atomically alongside manifest writes.

### Handling database changes

On **fullReplace**: the window is cleared, the month index is refreshed, and the newest page is loaded.

On **incremental**: the month index is refreshed, then mutations are applied to the loaded window in-place — `loadedOffset` is adjusted for adds/removes before the window, deleted items are removed, added items within the window range are inserted maintaining sort order, and edge cursors are updated. This mirrors the iOS `applyIncrementalMutation` pattern.

### Data flow

```
useLibraryRuntime
  ├─ timelineItemCount: number  (derived from month index)
  ├─ timelineMonthIndex: MonthEntry[]  (with globalOffset)
  ├─ timelineWindow: { loadedOffset, loadedItems, olderCursor, newerCursor }
  ├─ loadOlderPage() / loadNewerPage()  (cursor-based)
  └─ seekToIndex()  (month jump / anchor restore)
       │
       ▼
TimelineView
  └─ <Timeline itemCount loadedOffset loadedItems monthIndex
       onLoadOlder onLoadNewer onSeekToIndex>
       ├─ arithmetic layout (colCount, tileSize, totalHeight)
       ├─ visible row range (O(1) from scrollTop)
       ├─ skeleton placeholders for unloaded tiles
       ├─ edge-triggered page loading
       ├─ scroll anchor (URL hash, pendingAnchorRef)
       └─ <MonthSidebar months currentMonthKey onSelectMonth>
```
