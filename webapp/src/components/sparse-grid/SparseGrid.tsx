import {
  ForwardedRef,
  forwardRef,
  memo,
  ReactNode,
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  SparseGridAnchor,
  SparseGridHandle,
  SparseGridProps,
  SparseGridWindow,
} from "../../lib/sparseGrid";
import { OverlayScrollbar } from "../OverlayScrollbar";

const TILE_GAP = 2;
// Targets ~6.75cm tiles so the grid stays glanceable without packing too densely.
const TARGET_TILE_CM = 6.75;
const CM_PER_INCH = 2.54;
const OVERSCAN_PX = 800;
const EDGE_THRESHOLD = 24;
const RANDOM_SEEK_THRESHOLD = 300;

// Computes responsive column count so tile size stays physically legible.
const computeColumnCount = (widthPx: number): number => {
  const targetPx = (TARGET_TILE_CM / CM_PER_INCH) * 96;
  return Math.max(1, Math.round((widthPx + TILE_GAP) / (targetPx + TILE_GAP)));
};

// Computes square tile width so rows align to a fixed arithmetic grid.
const computeTileSize = (containerWidth: number, colCount: number): number =>
  (containerWidth - (colCount - 1) * TILE_GAP) / colCount;

// Computes virtual spacer height so native scrolling can address all rows.
const computeTotalHeight = (itemCount: number, colCount: number, tileSize: number): number => {
  if (itemCount === 0) return 0;
  const rowCount = Math.ceil(itemCount / colCount);
  return rowCount * (tileSize + TILE_GAP) - TILE_GAP;
};

// Resolves a loaded sparse item from a global index for viewport anchoring.
const itemAt = <TItem,>(
  globalIndex: number,
  loadedOffset: number,
  loadedItems: SparseGridWindow<TItem>["loadedItems"],
): TItem | null => {
  const localIndex = globalIndex - loadedOffset;
  if (localIndex < 0 || localIndex >= loadedItems.length) return null;
  return loadedItems[localIndex];
};

// Renders an agnostic sparse virtualized grid with random seek and edge pagination.
const SparseGridInner = <TItem,>(
  {
    dataSource,
    getItemKey,
    renderItem,
    renderPlaceholder,
    onItemClick,
    initialAnchor,
    onViewportAnchorChange,
    onVisibleRangeChange,
    showScrollbar = false,
    getScrollLabel,
    className,
  }: SparseGridProps<TItem>,
  ref: ForwardedRef<SparseGridHandle>,
) => {
  const { itemCount, window: loadedWindow, onLoadOlder, onLoadNewer, onSeekToIndex } = dataSource;
  const { loadedOffset, loadedItems } = loadedWindow;
  const timelineRef = useRef<HTMLElement | null>(null);
  const firstMountRef = useRef(true);
  const pendingAnchorRef = useRef<SparseGridAnchor | null>(null);
  const pendingSeekIndexRef = useRef<number | null>(null);
  const lastScrollTopRef = useRef(0);
  const [width, setWidth] = useState(0);
  const [scrollTick, setScrollTick] = useState(0);

  const columnCount = useMemo(() => computeColumnCount(width || window.innerWidth), [width]);
  const tileSize = useMemo(() => computeTileSize(width || window.innerWidth, columnCount), [width, columnCount]);
  const rowHeight = tileSize + TILE_GAP;
  const totalHeight = useMemo(() => computeTotalHeight(itemCount, columnCount, tileSize), [itemCount, columnCount, tileSize]);

  // Converts item indices to scrollTop values so callers can jump by index.
  const scrollTopForIndex = useCallback(
    (index: number): number => Math.floor(index / columnCount) * rowHeight,
    [columnCount, rowHeight],
  );

  // Emits top-visible anchors so wrappers can persist deep-link location.
  const emitViewportAnchor = useCallback(() => {
    if (!onViewportAnchorChange) return;
    if (itemCount === 0) return;
    const timeline = timelineRef.current;
    if (!timeline) return;
    const scrollTop = timeline.scrollTop;
    const topRow = Math.max(0, Math.floor(scrollTop / rowHeight));
    const topIndex = Math.min(itemCount - 1, topRow * columnCount);
    const item = itemAt(topIndex, loadedOffset, loadedItems);
    if (!item) return;
    const offsetPx = Math.max(0, Math.round(scrollTop - topRow * rowHeight));
    onViewportAnchorChange({ itemKey: getItemKey(item), offsetPx, index: topIndex });
  }, [columnCount, getItemKey, itemCount, loadedItems, loadedOffset, onViewportAnchorChange, rowHeight]);

  // Requests pagination or random seek when viewport leaves the loaded window.
  const checkLoadEdges = useCallback(
    (scrollTop: number, viewportHeight: number) => {
      if (itemCount === 0) return;
      const topRow = Math.max(0, Math.floor(scrollTop / rowHeight));
      const bottomRow = Math.floor((scrollTop + viewportHeight) / rowHeight);
      const topIndex = topRow * columnCount;
      const bottomIndex = Math.min(itemCount - 1, bottomRow * columnCount + columnCount - 1);
      if (loadedItems.length === 0) {
        const previousSeekIndex = pendingSeekIndexRef.current;
        if (previousSeekIndex === null || Math.abs(previousSeekIndex - topIndex) > RANDOM_SEEK_THRESHOLD) {
          pendingSeekIndexRef.current = topIndex;
          onSeekToIndex(topIndex);
        }
        return;
      }

      const loadedEnd = loadedOffset + loadedItems.length;
      const viewportBeforeLoaded = bottomIndex < loadedOffset - RANDOM_SEEK_THRESHOLD;
      const viewportAfterLoaded = topIndex > loadedEnd + RANDOM_SEEK_THRESHOLD;
      if (viewportBeforeLoaded || viewportAfterLoaded) {
        pendingSeekIndexRef.current = topIndex;
        onSeekToIndex(topIndex);
        return;
      }
      pendingSeekIndexRef.current = null;
      if (topIndex < loadedOffset + EDGE_THRESHOLD && loadedOffset > 0) {
        onLoadOlder();
      }
      if (bottomIndex > loadedEnd - EDGE_THRESHOLD && loadedEnd < itemCount) {
        onLoadNewer();
      }
    },
    [columnCount, itemCount, loadedItems.length, loadedOffset, onLoadNewer, onLoadOlder, onSeekToIndex, rowHeight],
  );

  // Tracks container width so responsive column math updates on resize.
  useLayoutEffect(() => {
    const timeline = timelineRef.current;
    if (!timeline) return;
    const resizeObserver = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (!entry) return;
      setWidth(entry.contentRect.width);
    });
    resizeObserver.observe(timeline);
    setWidth(timeline.clientWidth);
    return () => resizeObserver.disconnect();
  }, []);

  // Captures pre-update anchors so reflows keep users on the same content.
  useLayoutEffect(() => {
    return () => {
      if (itemCount === 0 || loadedItems.length === 0) return;
      const scrollTop = lastScrollTopRef.current;
      const topRow = Math.max(0, Math.floor(scrollTop / rowHeight));
      const topIndex = Math.min(itemCount - 1, topRow * columnCount);
      const item = itemAt(topIndex, loadedOffset, loadedItems);
      if (!item) return;
      pendingAnchorRef.current = {
        itemKey: getItemKey(item),
        offsetPx: Math.max(0, Math.round(scrollTop - topRow * rowHeight)),
      };
    };
  }, [columnCount, getItemKey, itemCount, loadedItems, loadedOffset, rowHeight]);

  // Restores initial or preserved anchors after window/layout updates.
  useLayoutEffect(() => {
    const timeline = timelineRef.current;
    if (!timeline) return;

    if (firstMountRef.current) {
      if (width <= 0) return;
      if (initialAnchor && loadedItems.length === 0) return;
      firstMountRef.current = false;
      if (initialAnchor) {
        const idx = loadedItems.findIndex((item) => getItemKey(item) === initialAnchor.itemKey);
        const globalIdx = idx >= 0 ? loadedOffset + idx : loadedOffset;
        timeline.scrollTop = Math.max(0, Math.min(totalHeight, scrollTopForIndex(globalIdx) + initialAnchor.offsetPx));
      } else {
        timeline.scrollTop = totalHeight;
      }
      lastScrollTopRef.current = timeline.scrollTop;
      setScrollTick((v) => v + 1);
      emitViewportAnchor();
      checkLoadEdges(timeline.scrollTop, timeline.clientHeight);
      return;
    }

    const anchor = pendingAnchorRef.current;
    pendingAnchorRef.current = null;
    if (!anchor) return;
    const idx = loadedItems.findIndex((item) => getItemKey(item) === anchor.itemKey);
    if (idx < 0) return;
    const globalIdx = loadedOffset + idx;
    timeline.scrollTop = Math.max(0, Math.min(totalHeight, scrollTopForIndex(globalIdx) + anchor.offsetPx));
    lastScrollTopRef.current = timeline.scrollTop;
    setScrollTick((v) => v + 1);
    emitViewportAnchor();
  }, [checkLoadEdges, emitViewportAnchor, getItemKey, initialAnchor, loadedItems, loadedOffset, scrollTopForIndex, totalHeight, width]);

  // Re-validates edge loading once seek results land at a stale scroll position.
  useEffect(() => {
    if (itemCount === 0 || loadedItems.length === 0) return;
    const frame = requestAnimationFrame(() => {
      const timeline = timelineRef.current;
      if (!timeline) return;
      checkLoadEdges(timeline.scrollTop, timeline.clientHeight);
    });
    return () => cancelAnimationFrame(frame);
  }, [checkLoadEdges, itemCount, loadedItems.length, loadedOffset]);

  // Reports visible global range so wrappers can preload adjacent data.
  useEffect(() => {
    if (!onVisibleRangeChange) return;
    const timeline = timelineRef.current;
    if (!timeline) return;
    const scrollTop = lastScrollTopRef.current;
    const viewportHeight = timeline.clientHeight;
    const totalRows = Math.ceil(itemCount / columnCount);
    const firstViewportRow = Math.max(0, Math.floor(scrollTop / rowHeight));
    const lastViewportRow = Math.min(totalRows - 1, Math.floor((scrollTop + viewportHeight) / rowHeight));
    const firstIndex = itemCount > 0 ? Math.min(itemCount - 1, firstViewportRow * columnCount) : -1;
    const lastIndex = itemCount > 0
      ? Math.min(itemCount - 1, lastViewportRow * columnCount + columnCount - 1)
      : -1;
    onVisibleRangeChange({ firstIndex, lastIndex });
  }, [columnCount, itemCount, onVisibleRangeChange, rowHeight, scrollTick]);

  // Handles native scrolling and feeds both paging and anchor persistence.
  const handleScroll = useCallback(() => {
    const timeline = timelineRef.current;
    if (!timeline) return;
    lastScrollTopRef.current = timeline.scrollTop;
    setScrollTick((v) => v + 1);
    emitViewportAnchor();
    checkLoadEdges(timeline.scrollTop, timeline.clientHeight);
  }, [checkLoadEdges, emitViewportAnchor]);

  // Supports external month/anchor controls without leaking layout math.
  useImperativeHandle(ref, () => ({
    scrollToIndex: (index: number) => {
      const timeline = timelineRef.current;
      if (!timeline) return;
      const loadedEnd = loadedOffset + loadedItems.length;
      if (index < loadedOffset || index >= loadedEnd) {
        onSeekToIndex(index);
      }
      const y = scrollTopForIndex(index);
      timeline.scrollTop = Math.max(0, Math.min(totalHeight, y));
      lastScrollTopRef.current = timeline.scrollTop;
      setScrollTick((v) => v + 1);
      emitViewportAnchor();
    },
    scrollToAnchor: (anchor: SparseGridAnchor) => {
      const timeline = timelineRef.current;
      if (!timeline) return;
      const idx = loadedItems.findIndex((item) => getItemKey(item) === anchor.itemKey);
      if (idx < 0) return;
      const globalIdx = loadedOffset + idx;
      timeline.scrollTop = Math.max(0, Math.min(totalHeight, scrollTopForIndex(globalIdx) + anchor.offsetPx));
      lastScrollTopRef.current = timeline.scrollTop;
      setScrollTick((v) => v + 1);
      emitViewportAnchor();
      checkLoadEdges(timeline.scrollTop, timeline.clientHeight);
    },
  }), [checkLoadEdges, emitViewportAnchor, getItemKey, loadedItems, loadedOffset, onSeekToIndex, scrollTopForIndex, totalHeight]);

  const scrollTop = lastScrollTopRef.current;
  const viewportHeight = timelineRef.current?.clientHeight ?? 0;
  const topRow = Math.max(0, Math.floor(scrollTop / rowHeight));
  const topIndex = itemCount > 0 ? Math.min(itemCount - 1, topRow * columnCount) : -1;
  const totalRows = Math.ceil(itemCount / columnCount);
  const firstViewportRow = Math.max(0, Math.floor(scrollTop / rowHeight));
  const lastViewportRow = Math.min(
    totalRows - 1,
    Math.floor((scrollTop + viewportHeight) / rowHeight),
  );
  const firstVisibleRow = Math.max(0, Math.floor((scrollTop - OVERSCAN_PX) / rowHeight));
  const lastVisibleRow = Math.min(
    totalRows - 1,
    Math.floor((scrollTop + viewportHeight + OVERSCAN_PX) / rowHeight),
  );

  void scrollTick;

  const visibleRows: number[] = [];
  for (let row = firstVisibleRow; row <= lastVisibleRow; row += 1) {
    visibleRows.push(row);
  }

  const loadedEnd = loadedOffset + loadedItems.length;

  return (
    <div className={`sparse-grid-viewport${showScrollbar ? " sparse-grid-viewport--scrollbar" : ""}`}>
    <main
      ref={timelineRef}
      className={`${className ?? "timeline"}`}
      onScroll={handleScroll}
    >
      <div className="spacer" style={{ height: `${totalHeight}px` }} />
      <div className="rows-layer">
        {visibleRows.map((rowIdx) => {
          const startIdx = rowIdx * columnCount;
          const endIdx = Math.min(startIdx + columnCount, itemCount);
          const rowTop = rowIdx * rowHeight;
          const inViewport = rowIdx >= firstViewportRow && rowIdx <= lastViewportRow;

          return (
            <div
              key={rowIdx}
              className="image-row"
              style={{
                transform: `translateY(${rowTop}px)`,
                height: `${tileSize}px`,
                gridTemplateColumns: `repeat(${columnCount}, minmax(0, 1fr))`,
                gap: `${TILE_GAP}px`,
              }}
            >
              {Array.from({ length: endIdx - startIdx }, (_, colIdx) => {
                const index = startIdx + colIdx;
                const item = index >= loadedOffset && index < loadedEnd
                  ? loadedItems[index - loadedOffset]
                  : null;

                if (!item) {
                  return renderPlaceholder
                    ? <div key={index}>{renderPlaceholder(index)}</div>
                    : <div key={index} className="image-tile skeleton" />;
                }

                return (
                  <button
                    type="button"
                    key={getItemKey(item)}
                    className="image-tile"
                    onClick={() => onItemClick?.(item, index)}
                  >
                    {renderItem({ item, index, inViewport, tileSizePx: tileSize })}
                  </button>
                );
              })}
            </div>
          );
        })}
      </div>
    </main>
      {showScrollbar ? (
        <OverlayScrollbar
          scrollRef={timelineRef}
          getScrollLabel={() => (topIndex >= 0 ? getScrollLabel?.(topIndex) ?? null : null)}
        />
      ) : null}
    </div>
  );
};

const ForwardedSparseGrid = forwardRef(SparseGridInner) as <TItem>(
  props: SparseGridProps<TItem> & { ref?: ForwardedRef<SparseGridHandle> },
) => ReactNode;

export const SparseGrid = memo(ForwardedSparseGrid) as typeof ForwardedSparseGrid;
