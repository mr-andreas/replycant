import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { MapPointRow } from "../gitdb";
import { buildMonthEntries, type MonthEntry, type TimelineItem } from "../../lib/timeline";
import type { SparseGridDataSource } from "../../lib/sparseGrid";
import type { GeoBounds } from "./mapClusters";

const PAGE_SIZE = 100;

interface PlaceWindow {
  loadedOffset: number;
  loadedItems: TimelineItem[];
}

interface UsePlaceTimelineOptions {
  points: MapPointRow[];
  bounds: GeoBounds;
  revision: number;
  loadItemsByKeys: (keys: string[]) => Promise<TimelineItem[]>;
}

export interface PlaceTimelineState {
  itemCount: number;
  monthIndex: MonthEntry[];
  loadedOffset: number;
  loadedItems: TimelineItem[];
  dataSource: SparseGridDataSource<TimelineItem>;
  loadOlderPage: () => void;
  loadNewerPage: () => void;
  seekToIndex: (index: number) => void;
}

const inBounds = (point: MapPointRow, bounds: GeoBounds): boolean =>
  point.latitude >= bounds.minLatitude
  && point.latitude <= bounds.maxLatitude
  && point.longitude >= bounds.minLongitude
  && point.longitude <= bounds.maxLongitude;

// Oldest first, with the key breaking ties, matching the main timeline.
const comparePoints = (left: MapPointRow, right: MapPointRow): number => {
  if (left.takenAt !== right.takenAt) return left.takenAt < right.takenAt ? -1 : 1;
  if (left.key !== right.key) return left.key < right.key ? -1 : 1;
  return 0;
};

// Photos inside the tile's box. Group boxes do not overlap, so this is
// the same set the tile counted.
export const selectPlaceMembers = (points: MapPointRow[], bounds: GeoBounds): MapPointRow[] =>
  points.filter((point) => inBounds(point, bounds)).sort(comparePoints);

// Month buckets for the place, in calendar order, so the sidebar offsets
// match the sorted member list.
const monthRows = (members: MapPointRow[]) => {
  const buckets = new Map<string, { count: number; firstTakenAt: string }>();
  for (const member of members) {
    const monthKey = member.takenAt.slice(0, 7);
    const existing = buckets.get(monthKey);
    if (existing) {
      existing.count += 1;
      if (member.takenAt < existing.firstTakenAt) existing.firstTakenAt = member.takenAt;
    } else {
      buckets.set(monthKey, { count: 1, firstTakenAt: member.takenAt });
    }
  }
  return [...buckets.entries()]
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0))
    .map(([monthKey, value]) => ({ monthKey, count: value.count, firstTakenAt: value.firstTakenAt }));
};

// Pages one place's photos through the same sparse grid as the library
// timeline. The member list is already in memory; only the rendered
// rows are loaded.
export const usePlaceTimeline = ({
  points,
  bounds,
  revision,
  loadItemsByKeys,
}: UsePlaceTimelineOptions): PlaceTimelineState => {
  const members = useMemo(
    () => selectPlaceMembers(points, bounds),
    [points, bounds, revision],
  );
  const monthIndex = useMemo(() => buildMonthEntries(monthRows(members)), [members]);
  const [windowState, setWindowState] = useState<PlaceWindow>({ loadedOffset: 0, loadedItems: [] });
  const windowRef = useRef(windowState);
  const membersRef = useRef(members);
  const generationRef = useRef(0);
  const loadingRef = useRef(false);
  windowRef.current = windowState;
  membersRef.current = members;

  // Replaces the loaded window with one page. Used for the first view
  // and for month jumps, where the previous window is no longer relevant.
  const loadSlice = useCallback(async (offset: number, generation: number) => {
    const list = membersRef.current;
    if (list.length === 0) return;
    const start = Math.max(0, Math.min(offset, list.length - 1));
    const slice = list.slice(start, start + PAGE_SIZE);
    const items = await loadItemsByKeys(slice.map((member) => member.key));
    if (generation !== generationRef.current) return;
    const next = { loadedOffset: start, loadedItems: items };
    windowRef.current = next;
    setWindowState(next);
  }, [loadItemsByKeys]);

  useEffect(() => {
    const generation = generationRef.current + 1;
    generationRef.current = generation;
    if (members.length === 0) {
      const empty = { loadedOffset: 0, loadedItems: [] as TimelineItem[] };
      windowRef.current = empty;
      setWindowState(empty);
      return;
    }
    const offset = Math.max(0, members.length - PAGE_SIZE);
    void loadSlice(offset, generation);
  }, [members, loadSlice]);

  const loadOlderPage = useCallback(() => {
    const current = windowRef.current;
    if (current.loadedOffset === 0 || loadingRef.current) return;
    const generation = generationRef.current;
    const start = Math.max(0, current.loadedOffset - PAGE_SIZE);
    const slice = membersRef.current.slice(start, current.loadedOffset);
    if (slice.length === 0) return;
    loadingRef.current = true;
    void (async () => {
      try {
        const items = await loadItemsByKeys(slice.map((member) => member.key));
        if (generation !== generationRef.current) return;
        if (windowRef.current.loadedOffset !== current.loadedOffset) return;
        const next = {
          loadedOffset: start,
          loadedItems: [...items, ...windowRef.current.loadedItems],
        };
        windowRef.current = next;
        setWindowState(next);
      } finally {
        loadingRef.current = false;
      }
    })();
  }, [loadItemsByKeys]);

  const loadNewerPage = useCallback(() => {
    const current = windowRef.current;
    const list = membersRef.current;
    const end = current.loadedOffset + current.loadedItems.length;
    if (end >= list.length || loadingRef.current) return;
    const generation = generationRef.current;
    const slice = list.slice(end, end + PAGE_SIZE);
    if (slice.length === 0) return;
    loadingRef.current = true;
    void (async () => {
      try {
        const items = await loadItemsByKeys(slice.map((member) => member.key));
        if (generation !== generationRef.current) return;
        if (windowRef.current.loadedOffset !== current.loadedOffset) return;
        const next = {
          loadedOffset: current.loadedOffset,
          loadedItems: [...windowRef.current.loadedItems, ...items],
        };
        windowRef.current = next;
        setWindowState(next);
      } finally {
        loadingRef.current = false;
      }
    })();
  }, [loadItemsByKeys]);

  // Jumps the window to a month. The page starts at the index when that
  // still leaves a full page, and earlier when the index is near the end.
  const seekToIndex = useCallback((index: number) => {
    const list = membersRef.current;
    if (list.length === 0) return;
    const generation = generationRef.current + 1;
    generationRef.current = generation;
    const start = Math.max(0, Math.min(index, Math.max(0, list.length - PAGE_SIZE)));
    void loadSlice(start, generation);
  }, [loadSlice]);

  const dataSource = useMemo<SparseGridDataSource<TimelineItem>>(() => ({
    itemCount: members.length,
    window: windowState,
    onLoadOlder: loadOlderPage,
    onLoadNewer: loadNewerPage,
    onSeekToIndex: seekToIndex,
  }), [loadNewerPage, loadOlderPage, members.length, seekToIndex, windowState]);

  return {
    itemCount: members.length,
    monthIndex,
    loadedOffset: windowState.loadedOffset,
    loadedItems: windowState.loadedItems,
    dataSource,
    loadOlderPage,
    loadNewerPage,
    seekToIndex,
  };
};
