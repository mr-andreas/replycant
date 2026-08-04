import { ForwardedRef, forwardRef, memo, ReactNode, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState } from "react";
import { runtimeConfig } from "../lib/config";
import { readHashParams } from "../lib/hashState";
import { getPreloadedBlob } from "../lib/mediaFetchLimiter";
import { fetchAndCacheAuthenticatedMedia } from "../lib/preloadMedia";
import { MonthEntry, monthKeyForGlobalIndex, TimelineItem } from "../lib/timeline";
import { AuthImage } from "./AuthImage";
import { MonthSidebar } from "./MonthSidebar";
import { SparseGrid, SparseGridAnchor, SparseGridDataSource, SparseGridHandle, SparseGridRenderContext } from "./sparse-grid";

interface TimelineProps {
  itemCount: number;
  loadedOffset: number;
  loadedItems: TimelineItem[];
  dataSource?: SparseGridDataSource<TimelineItem>;
  monthIndex: MonthEntry[];
  onOpen: (index: number) => void;
  onLoadOlder: () => void;
  onLoadNewer: () => void;
  onSeekToIndex: (index: number) => void;
  mtlsHeaders: Record<string, string> | null;
  showMonthSidebar: boolean;
  monthSidebarInitialScrollTop?: number;
  onMonthSidebarScroll?: (scrollTop: number) => void;
  suspendHashSync?: boolean;
  rightPane?: ReactNode;
}

// Exposes timeline jump controls so parent views can restore user context after overlays close.
export interface TimelineHandle {
  scrollToIndex: (index: number) => void;
}

const formatDurationLabel = (duration?: number): string | null => {
  if (!duration || duration <= 0) return null;
  const totalSeconds = Math.round(duration);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  }
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
};

// Formats month labels for the fast-scroll hint bubble so coarse scrubs stay oriented.
const formatMonthScrollLabel = (monthKey: string): string => {
  const [year, month] = monthKey.split("-");
  const date = new Date(Date.UTC(Number(year), Number(month) - 1, 1));
  return date.toLocaleDateString(undefined, { month: "short", year: "numeric" });
};

// Clamps preload depth configuration so invalid runtime values never break timeline traversal.
const normalizePreloadCount = (value: number): number => {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.floor(value));
};

// Formats visible range dates so users can orient quickly while scrolling.
const formatViewportDate = (timestamp: string): string =>
  new Date(timestamp).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });

// Resolves sparse loaded items by global index so viewport labels stay data-window safe.
const loadedItemAtGlobalIndex = (
  globalIndex: number,
  loadedOffset: number,
  loadedItems: TimelineItem[],
): TimelineItem | null => {
  if (globalIndex < 0) return null;
  const localIndex = globalIndex - loadedOffset;
  if (localIndex < 0 || localIndex >= loadedItems.length) return null;
  return loadedItems[localIndex];
};

// Resolves a viewport edge label, preferring the exact loaded date but degrading
// to the always-available month index so fast scrubbing past the loaded window
// keeps the date bar visible instead of flickering to nothing.
const resolveViewportEdgeLabel = (
  globalIndex: number,
  loadedOffset: number,
  loadedItems: TimelineItem[],
  monthIndex: MonthEntry[],
): string | null => {
  if (globalIndex < 0) return null;
  const item = loadedItemAtGlobalIndex(globalIndex, loadedOffset, loadedItems);
  if (item) return formatViewportDate(item.timestamp);
  const monthKey = monthKeyForGlobalIndex(monthIndex, globalIndex);
  return monthKey ? formatMonthScrollLabel(monthKey) : null;
};

// Checks whether a month still intersects the viewport so sidebar clicks can
// stay selected until the user scrolls completely away from that month.
const isMonthVisibleInRange = (
  monthKey: string,
  monthIndex: MonthEntry[],
  firstIndex: number,
  lastIndex: number,
): boolean => {
  const month = monthIndex.find((entry) => entry.monthKey === monthKey);
  if (!month) return false;
  const monthLastIndex = month.globalOffset + month.count - 1;
  return month.globalOffset <= lastIndex && monthLastIndex >= firstIndex;
};

interface TimelineHashAnchor {
  itemKey: string;
  offsetPx: number;
  takenAt: string | null;
}

// Reads hash state so timeline restores the same media row on reload and history navigation.
const parseHashAnchor = (): TimelineHashAnchor | null => {
  const params = readHashParams();
  const itemKey = params.get("k");
  const offsetPx = Number(params.get("o"));
  const takenAt = params.get("t");
  if (!itemKey || !Number.isFinite(offsetPx)) return null;
  return { itemKey, offsetPx: Math.max(0, Math.floor(offsetPx)), takenAt };
};

// Flat-grid timeline with arithmetic layout, sparse window, and month navigation.
const TimelineInner = ({
  itemCount,
  loadedOffset,
  loadedItems,
  dataSource: dataSourceProp,
  monthIndex,
  onOpen,
  onLoadOlder,
  onLoadNewer,
  onSeekToIndex,
  mtlsHeaders,
  showMonthSidebar,
  monthSidebarInitialScrollTop = 0,
  onMonthSidebarScroll,
  suspendHashSync = false,
  rightPane,
}: TimelineProps, ref: ForwardedRef<TimelineHandle>) => {
  const gridRef = useRef<SparseGridHandle | null>(null);
  const hashWriteScheduledRef = useRef(false);
  const currentMonthKeyRef = useRef<string | null>(null);
  const pinnedMonthKeyRef = useRef<string | null>(null);
  const [currentMonthKey, setCurrentMonthKey] = useState<string | null>(null);
  const [visibleRange, setVisibleRange] = useState<{ firstIndex: number; lastIndex: number } | null>(null);
  const [initialAnchor, setInitialAnchor] = useState<SparseGridAnchor | null>(() => {
    const hashAnchor = parseHashAnchor();
    if (!hashAnchor) return null;
    return { itemKey: hashAnchor.itemKey, offsetPx: hashAnchor.offsetPx };
  });

  // Keeps the external hash in sync with current viewport without adding history entries.
  const handleViewportAnchorChange = useCallback((anchor: SparseGridAnchor & { index: number }) => {
    if (itemCount === 0) return;
    const item = loadedItems[anchor.index - loadedOffset];
    if (!item) return;
    if (!pinnedMonthKeyRef.current) {
      const monthKey = monthKeyForGlobalIndex(monthIndex, anchor.index);
      if (currentMonthKeyRef.current !== monthKey) {
        currentMonthKeyRef.current = monthKey;
        setCurrentMonthKey(monthKey);
      }
    }
    if (suspendHashSync) return;
    if (hashWriteScheduledRef.current) return;
    hashWriteScheduledRef.current = true;
    requestAnimationFrame(() => {
      hashWriteScheduledRef.current = false;
      const params = readHashParams();
      params.set("k", anchor.itemKey);
      params.set("o", String(anchor.offsetPx));
      params.set("t", item.timestamp);
      params.delete("v");
      history.replaceState(null, "", `#${params.toString()}`);
    });
  }, [itemCount, loadedItems, loadedOffset, monthIndex, suspendHashSync]);

  // Re-applies hash anchors triggered by browser navigation.
  useEffect(() => {
    const handleHashChange = () => {
      const hashAnchor = parseHashAnchor();
      if (!hashAnchor) return;
      setInitialAnchor({ itemKey: hashAnchor.itemKey, offsetPx: hashAnchor.offsetPx });
      gridRef.current?.scrollToAnchor({ itemKey: hashAnchor.itemKey, offsetPx: hashAnchor.offsetPx });
    };
    window.addEventListener("hashchange", handleHashChange);
    return () => window.removeEventListener("hashchange", handleHashChange);
  }, []);

  // Jumps to a month anchor so sidebar navigation lands immediately in the right bucket.
  const scrollToMonth = useCallback(
    (monthKey: string) => {
      const entry = monthIndex.find((m) => m.monthKey === monthKey);
      if (!entry) return;
      pinnedMonthKeyRef.current = monthKey;
      if (currentMonthKeyRef.current !== monthKey) {
        currentMonthKeyRef.current = monthKey;
        setCurrentMonthKey(monthKey);
      }
      gridRef.current?.scrollToIndex(entry.globalOffset);
    },
    [monthIndex],
  );

  // Mirrors visible range so wrappers can preload nearby thumbnails efficiently.
  const handleVisibleRangeChange = useCallback((range: { firstIndex: number; lastIndex: number }) => {
    setVisibleRange(range);
    if (range.firstIndex < 0 || range.lastIndex < 0) return;
    const pinnedMonthKey = pinnedMonthKeyRef.current;
    if (pinnedMonthKey) {
      if (isMonthVisibleInRange(pinnedMonthKey, monthIndex, range.firstIndex, range.lastIndex)) {
        if (currentMonthKeyRef.current !== pinnedMonthKey) {
          currentMonthKeyRef.current = pinnedMonthKey;
          setCurrentMonthKey(pinnedMonthKey);
        }
        return;
      }
      pinnedMonthKeyRef.current = null;
    }
    const monthKey = monthKeyForGlobalIndex(monthIndex, range.firstIndex);
    if (currentMonthKeyRef.current === monthKey) return;
    currentMonthKeyRef.current = monthKey;
    setCurrentMonthKey(monthKey);
  }, [monthIndex]);

  // Stabilizes key resolution so grid anchor effects do not churn on wrapper rerenders.
  const getTimelineItemKey = useCallback((item: TimelineItem) => item.key, []);

  // Stabilizes click forwarding so tile selection stays decoupled from render loops.
  const handleItemClick = useCallback((_item: TimelineItem, index: number) => {
    onOpen(index);
  }, [onOpen]);

  // Maps top-visible index into month text so scrollbar scrubbing shows temporal context.
  const getScrollLabel = useCallback((topIndex: number): string => {
    const monthKey = monthKeyForGlobalIndex(monthIndex, topIndex);
    return monthKey ? formatMonthScrollLabel(monthKey) : "";
  }, [monthIndex]);

  // Keeps tile fetch policy aligned with SparseGrid virtualization so browser lazy-loading cannot defer visible thumbnail decode.
  const renderTimelineItem = useCallback(({ item }: SparseGridRenderContext<TimelineItem>) => {
    const durationLabel = formatDurationLabel(item.duration);
    return (
      <>
        <AuthImage
          src={item.thumbnailUrl}
          alt={item.timestamp}
          loading="eager"
          decoding="async"
          headers={mtlsHeaders}
          encryption={item.thumbnailEncryption}
        />
        {item.mediaType.toLowerCase().includes("video") && durationLabel ? (
          <span className="video-duration-badge">{durationLabel}</span>
        ) : null}
      </>
    );
  }, [mtlsHeaders]);

  // Preloads nearby LFS thumbnails so high-speed scrolling avoids blank tiles.
  useEffect(() => {
    if (!mtlsHeaders) return;
    if (loadedItems.length === 0) return;
    if (!visibleRange || visibleRange.firstIndex < 0 || visibleRange.lastIndex < 0) return;
    const preloadBeforeCount = normalizePreloadCount(runtimeConfig.timelinePreloadBeforeCount);
    const preloadAfterCount = normalizePreloadCount(runtimeConfig.timelinePreloadAfterCount);
    if (preloadBeforeCount === 0 && preloadAfterCount === 0) return;

    const minPreloadIndex = Math.max(0, visibleRange.firstIndex - preloadBeforeCount);
    const maxPreloadIndex = Math.min(itemCount - 1, visibleRange.lastIndex + preloadAfterCount);
    const candidates: TimelineItem[] = [];
    for (let globalIndex = minPreloadIndex; globalIndex <= maxPreloadIndex; globalIndex += 1) {
      if (globalIndex >= visibleRange.firstIndex && globalIndex <= visibleRange.lastIndex) continue;
      const localIndex = globalIndex - loadedOffset;
      if (localIndex < 0 || localIndex >= loadedItems.length) continue;
      const item = loadedItems[localIndex];
      if (!item || !item.thumbnailUrl.startsWith("/api/lfs/")) continue;
      if (getPreloadedBlob(item.thumbnailUrl, "preload")) continue;
      candidates.push(item);
    }
    if (candidates.length === 0) return;

    const controller = new AbortController();
    void (async () => {
      for (const item of candidates) {
        if (controller.signal.aborted) return;
        try {
          if (!item.thumbnailEncryption) continue;
          await fetchAndCacheAuthenticatedMedia({
            src: item.thumbnailUrl,
            headers: mtlsHeaders,
            encryption: item.thumbnailEncryption,
            signal: controller.signal,
            priority: "preload",
          });
        } catch {
          if (controller.signal.aborted) return;
        }
      }
    })();

    return () => {
      controller.abort();
    };
  }, [
    itemCount,
    loadedItems,
    loadedOffset,
    mtlsHeaders,
    visibleRange,
  ]);

  const dataSource = useMemo<SparseGridDataSource<TimelineItem>>(() => dataSourceProp ?? ({
    itemCount,
    window: {
      loadedOffset,
      loadedItems,
    },
    onLoadOlder,
    onLoadNewer,
    onSeekToIndex,
  }), [dataSourceProp, itemCount, loadedItems, loadedOffset, onLoadNewer, onLoadOlder, onSeekToIndex]);

  // Derives a human-readable viewport date span for quick temporal orientation.
  const viewportDateRange = useMemo(() => {
    if (!visibleRange) return null;
    const firstDate = resolveViewportEdgeLabel(visibleRange.firstIndex, loadedOffset, loadedItems, monthIndex);
    const lastDate = resolveViewportEdgeLabel(visibleRange.lastIndex, loadedOffset, loadedItems, monthIndex);
    if (firstDate && lastDate) return { start: firstDate, end: lastDate };
    if (firstDate) return { start: firstDate, end: firstDate };
    if (lastDate) return { start: lastDate, end: lastDate };
    return null;
  }, [loadedItems, loadedOffset, monthIndex, visibleRange]);

  // Keeps TimelineView decoupled from SparseGrid internals while still allowing targeted jumps.
  useImperativeHandle(ref, () => ({
    scrollToIndex: (index: number) => {
      gridRef.current?.scrollToIndex(index);
    },
  }), []);

  return (
    <div className="timeline-container">
      {showMonthSidebar && monthIndex.length > 0 ? (
        <MonthSidebar
          months={monthIndex}
          currentMonthKey={currentMonthKey}
          onSelectMonth={scrollToMonth}
          initialScrollTop={monthSidebarInitialScrollTop}
          onScroll={onMonthSidebarScroll}
        />
      ) : null}
      <div className="timeline-grid-pane">
        <SparseGrid
          ref={gridRef}
          dataSource={dataSource}
          getItemKey={getTimelineItemKey}
          initialAnchor={initialAnchor}
          onVisibleRangeChange={handleVisibleRangeChange}
          onViewportAnchorChange={handleViewportAnchorChange}
          onItemClick={handleItemClick}
          renderItem={renderTimelineItem}
          showScrollbar
          getScrollLabel={getScrollLabel}
        />
        {viewportDateRange ? (
          <div className="timeline-viewport-range" aria-live="polite">
            {viewportDateRange.start === viewportDateRange.end
              ? viewportDateRange.start
              : `${viewportDateRange.start} - ${viewportDateRange.end}`}
          </div>
        ) : null}
      </div>
      {rightPane}
    </div>
  );
};

export const Timeline = memo(forwardRef(TimelineInner));

Timeline.displayName = "Timeline";
