import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  clearIdentityRecord,
  createGitdbWorker,
  deriveBinaryPointerPath,
  GitdbWorkerClient,
  IDENTITY_STORAGE_KEY,
  SyncCommitSummary,
  SyncSnapshot,
} from "../gitdb";
import type {
  ManifestDatabaseChange,
  ManifestKindRegistration,
  ManifestMutation,
  MonthCountRow,
  RegisteredManifestRecord,
} from "../gitdb";
import { normalizeManifests, type ParsedManifestRecord } from "../../lib/manifest";
import type { NormalizedOriginal, NormalizedThumbnail, AnyManifest, ThumbnailSetManifest } from "../../types/manifests";
import { parseManifest } from "../../lib/manifest";
import type { LfsPointerFields } from "../gitdb";
import { SETUP_CONFIG_STORAGE_KEY } from "../../lib/config";
import { SetupMode } from "../onboarding/useOnboardingFlow";
import {
  buildMonthEntries,
  buildTimeline,
  MonthEntry,
  TimelineCursor,
  TimelineItem,
  totalCountFromMonthIndex,
} from "../../lib/timeline";
import type { SparseGridDataSource } from "../../lib/sparseGrid";


const REPLYCANT_DB_FALLBACK_NAMES = ["gitdb-sync-v1", "gitdb-entities", "replycant-git-v3", "gitdb-manifests-v1"];
const PAGE_SIZE = 100;
const PERIODIC_SYNC_PREFS_STORAGE_KEY = "replycant.periodic-sync-prefs";
const DEFAULT_PERIODIC_SYNC_INTERVAL_MS = 2_000;
const SUPPORTED_PERIODIC_SYNC_INTERVALS_MS = new Set([2_000, 5_000, 10_000, 30_000]);

const logAppDebug = (event: string, fields: Record<string, unknown>): void => {
  const duration = typeof fields.durationMs === "number" ? `${(fields.durationMs / 1000).toFixed(2)}s ` : "";
  console.debug(`[replycant-app] ${duration}${event}`, fields);
};
const RESET_CLONE_DEPTH_SESSION_KEY = "replycant-reset-initial-clone-depth";

type PeriodicSyncPrefs = {
  userEnabled: boolean;
  intervalMs: number;
};

// Restores sync-control preferences so app restarts keep the same polling behavior.
const readPeriodicSyncPrefs = (): PeriodicSyncPrefs => {
  const fallback: PeriodicSyncPrefs = {
    userEnabled: true,
    intervalMs: DEFAULT_PERIODIC_SYNC_INTERVAL_MS,
  };
  try {
    const raw = localStorage.getItem(PERIODIC_SYNC_PREFS_STORAGE_KEY);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw) as Partial<PeriodicSyncPrefs>;
    const intervalMs = Number(parsed.intervalMs);
    const userEnabled = parsed.userEnabled !== false;
    if (!SUPPORTED_PERIODIC_SYNC_INTERVALS_MS.has(intervalMs)) {
      return { userEnabled, intervalMs: fallback.intervalMs };
    }
    return { userEnabled, intervalMs };
  } catch {
    return fallback;
  }
};

// Persists sync-control preferences so manual tuning survives reloads.
const writePeriodicSyncPrefs = (prefs: PeriodicSyncPrefs): void => {
  localStorage.setItem(PERIODIC_SYNC_PREFS_STORAGE_KEY, JSON.stringify(prefs));
};
const parseHashAnchorTakenAt = (): string | null => {
  if (typeof window === "undefined") return null;
  if (!window.location.hash.startsWith("#")) return null;
  const params = new URLSearchParams(window.location.hash.slice(1));
  const takenAt = params.get("t");
  if (!takenAt) return null;
  return takenAt;
};

const deleteIndexedDbDatabase = async (name: string): Promise<void> =>
  new Promise<void>((resolve, reject) => {
    const request = indexedDB.deleteDatabase(name);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error ?? new Error(`Failed to delete IndexedDB database ${name}.`));
    request.onblocked = () => resolve();
  });

const ORIGINAL_IDENTITY = { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" } as const;
const THUMBNAIL_IDENTITY = { apiVersion: "media.replycant.com/v1alpha1", kind: "ThumbnailSet" } as const;

const collectPointerPaths = (records: RegisteredManifestRecord[]): string[] => {
  const paths: string[] = [];
  for (const record of records) {
    const manifest = record.manifest as AnyManifest | null;
    if (!manifest) continue;
    if (manifest.kind === "Original") {
      paths.push(deriveBinaryPointerPath(manifest.metadata.deviceSpace, record.apiVersion, record.kind, manifest.metadata.name));
    } else if (manifest.kind === "ThumbnailSet") {
      const thumb = manifest as ThumbnailSetManifest;
      for (const entry of thumb.spec.thumbnails) {
        paths.push(deriveBinaryPointerPath(manifest.metadata.deviceSpace, record.apiVersion, record.kind, entry.name));
      }
    }
  }
  return paths;
};

const recordsToNormalized = (
  recordsByKind: Map<string, RegisteredManifestRecord[]>,
  pointerMap: Map<string, LfsPointerFields>,
): { originals: NormalizedOriginal[]; thumbnails: NormalizedThumbnail[] } => {
  const parsed: ParsedManifestRecord[] = [];
  for (const records of recordsByKind.values()) {
    for (const record of records) {
      const manifest = record.manifest as AnyManifest | null;
      if (!manifest) continue;
      let pointer: LfsPointerFields | null = null;
      let thumbnailPointers: Record<string, LfsPointerFields> | undefined;
      if (manifest.kind === "Original") {
        const path = deriveBinaryPointerPath(manifest.metadata.deviceSpace, record.apiVersion, record.kind, manifest.metadata.name);
        pointer = pointerMap.get(path) ?? null;
      } else if (manifest.kind === "ThumbnailSet") {
        const thumb = manifest as ThumbnailSetManifest;
        const entries: Record<string, LfsPointerFields> = {};
        for (const entry of thumb.spec.thumbnails) {
          const path = deriveBinaryPointerPath(manifest.metadata.deviceSpace, record.apiVersion, record.kind, entry.name);
          const ptr = pointerMap.get(path);
          if (ptr) entries[entry.name] = ptr;
        }
        if (Object.keys(entries).length > 0) thumbnailPointers = entries;
      }
      parsed.push({ manifest, pointer, thumbnailPointers });
    }
  }
  return normalizeManifests(parsed);
};

const groupThumbnailsByOriginal = (thumbnails: NormalizedThumbnail[]): Map<string, NormalizedThumbnail[]> =>
  thumbnails.reduce((map, item) => {
    const list = map.get(item.originalKey) ?? [];
    list.push(item);
    map.set(item.originalKey, list);
    return map;
  }, new Map<string, NormalizedThumbnail[]>());

// Sparse window of loaded timeline items with stable cursor-based edges.
export interface TimelineWindow {
  loadedOffset: number;
  loadedItems: TimelineItem[];
  olderCursor: TimelineCursor | null;
  newerCursor: TimelineCursor | null;
}

const EMPTY_WINDOW: TimelineWindow = {
  loadedOffset: 0,
  loadedItems: [],
  olderCursor: null,
  newerCursor: null,
};

const cursorFromItem = (item: TimelineItem): TimelineCursor => ({
  takenAt: item.timestamp,
  key: item.key,
});

// Compares sparse windows by stable timeline identity so no-op sync reloads
// do not trigger unnecessary grid/viewer re-renders.
const timelineWindowEquals = (left: TimelineWindow, right: TimelineWindow): boolean => {
  if (left.loadedOffset !== right.loadedOffset) return false;
  if (left.loadedItems.length !== right.loadedItems.length) return false;
  for (let i = 0; i < left.loadedItems.length; i += 1) {
    if (left.loadedItems[i].key !== right.loadedItems[i].key) return false;
    if (left.loadedItems[i].thumbnailUrl !== right.loadedItems[i].thumbnailUrl) return false;
  }
  return true;
};

// Parses an Original manifest key from a ThumbnailSet originalRef to match timeline item keys.
const parseOriginalKeyFromRef = (originalRef: string, fallbackDeviceSpace: string): string | null => {
  const bits = originalRef.split("/");
  const originalName = bits.at(-1);
  if (!originalName) return null;
  const deviceSpace = bits[0] ?? fallbackDeviceSpace;
  return `${deviceSpace}/${originalName}`;
};

// Reads takenAt from an Original manifest record so incremental range checks remain cheap.
const originalTakenAt = (record: RegisteredManifestRecord): string | null => {
  if (record.kind !== "Original") return null;
  const takenAt = (record.manifest as { spec?: { takenAt?: string } })?.spec?.takenAt;
  return typeof takenAt === "string" && takenAt.length > 0 ? takenAt : null;
};

// Checks whether one manifest record can affect currently loaded timeline rows.
const recordTouchesLoadedWindow = (
  record: RegisteredManifestRecord,
  loadedOriginalKeys: Set<string>,
  olderCursor: TimelineCursor,
  newerCursor: TimelineCursor,
): boolean => {
  if (record.kind === "Original") {
    const takenAt = originalTakenAt(record);
    if (!takenAt) return false;
    return takenAt >= olderCursor.takenAt && takenAt <= newerCursor.takenAt;
  }
  if (record.kind === "ThumbnailSet") {
    const originalRef = (record.manifest as { spec?: { originalRef?: string } })?.spec?.originalRef;
    if (typeof originalRef !== "string" || originalRef.length === 0) return false;
    const originalKey = parseOriginalKeyFromRef(
      originalRef,
      (record.manifest as { metadata?: { deviceSpace?: string } })?.metadata?.deviceSpace ?? "",
    );
    if (!originalKey) return false;
    return loadedOriginalKeys.has(originalKey);
  }
  return false;
};

// Detects when incremental mutation can be handled as offset-only without rebuilding loaded items.
const mutationTouchesLoadedWindow = (
  mutation: ManifestMutation,
  window: TimelineWindow,
): boolean => {
  if (window.loadedItems.length === 0 || !window.olderCursor || !window.newerCursor) return true;
  const loadedOriginalKeys = new Set(window.loadedItems.map((item) => item.key));
  for (const record of mutation.added) {
    if (recordTouchesLoadedWindow(record, loadedOriginalKeys, window.olderCursor, window.newerCursor)) return true;
  }
  for (const record of mutation.removed) {
    if (recordTouchesLoadedWindow(record, loadedOriginalKeys, window.olderCursor, window.newerCursor)) return true;
  }
  for (const update of mutation.updated) {
    if (recordTouchesLoadedWindow(update.previous, loadedOriginalKeys, window.olderCursor, window.newerCursor)) return true;
    if (recordTouchesLoadedWindow(update.current, loadedOriginalKeys, window.olderCursor, window.newerCursor)) return true;
  }
  return false;
};

interface UseLibraryRuntimeOptions {
  setupMode: SetupMode;
  rehydrationKey: number;
  mtlsHeaders: Record<string, string> | null;
  agePrivateKeyBase64: string | null;
  setSetupMode: (mode: SetupMode) => void;
  setSetupError: (message: string | null) => void;
}

export interface LibraryRuntimeState {
  snapshot: SyncSnapshot;
  timelineItemCount: number;
  timelineMonthIndex: MonthEntry[];
  timelineWindow: TimelineWindow;
  timelineDataSource: SparseGridDataSource<TimelineItem>;
  rewindCommits: SyncCommitSummary[];
  rewindActionBusy: "rewind" | "forward" | null;
  initializeEngine: () => Promise<GitdbWorkerClient>;
  handleSyncNow: () => Promise<void>;
  handleTogglePeriodicSync: (enabled: boolean) => Promise<void>;
  handleChangeSyncInterval: (intervalMs: number) => Promise<void>;
  handleResetToRemote: () => Promise<void>;
  handleJumpToCommit: (commitHash: string, options?: { isHead: boolean }) => Promise<void>;
  wipeReplycantState: (initialCloneDepth?: number, wipeKeypair?: boolean, wipeServerConfig?: boolean) => Promise<void>;
  loadOlderPage: () => void;
  loadNewerPage: () => void;
  seekToIndex: (index: number) => void;
}

const consumeResetCloneDepthOverride = (): number | undefined => {
  const storedDepth = sessionStorage.getItem(RESET_CLONE_DEPTH_SESSION_KEY);
  if (!storedDepth) return undefined;
  sessionStorage.removeItem(RESET_CLONE_DEPTH_SESSION_KEY);
  const parsed = Number.parseInt(storedDepth, 10);
  if (!Number.isInteger(parsed) || parsed < 1) return undefined;
  return parsed;
};

const originalRegistration: ManifestKindRegistration<AnyManifest> = {
  apiVersion: "media.replycant.com/v1alpha1" as const,
  kind: "Original" as const,
  decode: (rawYaml: string) => parseManifest(rawYaml),
  primaryKey: (decoded: AnyManifest) => {
    if (decoded.kind !== "Original") return decoded.metadata.name;
    return `${decoded.metadata.deviceSpace}/${decoded.metadata.name}`;
  },
  indexes: [{ name: "byTakenAt", fieldPath: "manifest.spec.takenAt" }],
};

const thumbnailSetRegistration: ManifestKindRegistration<AnyManifest> = {
  apiVersion: "media.replycant.com/v1alpha1" as const,
  kind: "ThumbnailSet" as const,
  decode: (rawYaml: string) => parseManifest(rawYaml),
  primaryKey: (decoded: AnyManifest) => {
    if (decoded.kind !== "ThumbnailSet") return decoded.metadata.name;
    return `${decoded.metadata.deviceSpace}/${decoded.metadata.name}`;
  },
  indexes: [{ name: "byOriginalRef", fieldPath: "manifest.spec.originalRef" }],
};

// Derives DPR so thumbnail selection balances sharpness and bandwidth.
const computeDpr = () => (typeof window !== "undefined" ? window.devicePixelRatio || 1 : 1);

export const useLibraryRuntime = ({
  setupMode,
  rehydrationKey,
  mtlsHeaders,
  agePrivateKeyBase64,
  setSetupMode,
  setSetupError,
}: UseLibraryRuntimeOptions): LibraryRuntimeState => {
  const periodicSyncPrefsRef = useRef<PeriodicSyncPrefs>(readPeriodicSyncPrefs());
  const [snapshot, setSnapshot] = useState<SyncSnapshot>({
    syncing: false,
    error: null,
    unrecoverableError: null,
    lastSyncAt: null,
    syncedCommitHash: null,
    periodicSyncPaused: !periodicSyncPrefsRef.current.userEnabled,
    periodicSyncUserEnabled: periodicSyncPrefsRef.current.userEnabled,
    syncIntervalMs: periodicSyncPrefsRef.current.intervalMs,
    isOffHead: false,
    requiresHardResetPermission: false,
    cloneProgress: null,
  });
  const [timelineMonthIndex, setTimelineMonthIndex] = useState<MonthEntry[]>([]);
  const [timelineWindow, setTimelineWindow] = useState<TimelineWindow>(EMPTY_WINDOW);
  const [rewindCommits, setRewindCommits] = useState<SyncCommitSummary[]>([]);
  const [rewindActionBusy, setRewindActionBusy] = useState<"rewind" | "forward" | null>(null);
  const engineRef = useRef<GitdbWorkerClient | null>(null);
  const engineInitPromiseRef = useRef<Promise<GitdbWorkerClient> | null>(null);
  const startupRetryRef = useRef(false);
  const snapshotRef = useRef(snapshot);
  const pollingAuthorizationRef = useRef(false);
  const bootstrapDoneRef = useRef(false);
  const mtlsHeadersRef = useRef<Record<string, string> | null>(mtlsHeaders);
  const agePrivateKeyRef = useRef<string | null>(agePrivateKeyBase64);
  const loadingPageRef = useRef(false);
  // Remembers an edge load that arrived while another page was in flight or was
  // discarded by a generation bump, so the viewport can self-heal without a scroll.
  const pendingEdgeLoadRef = useRef<"older" | "newer" | null>(null);
  const loadOlderPageRef = useRef<() => void>(() => {});
  const loadNewerPageRef = useRef<() => void>(() => {});
  const monthIndexRef = useRef<MonthEntry[]>(timelineMonthIndex);
  const windowRef = useRef<TimelineWindow>(timelineWindow);
  const timelineLoadGenerationRef = useRef(0);
  mtlsHeadersRef.current = mtlsHeaders;
  agePrivateKeyRef.current = agePrivateKeyBase64;

  // Replays a deferred edge load after the in-flight page settles so dropped
  // requests from commit switches still cover the viewport.
  const flushPendingEdgeLoad = useCallback(() => {
    const pending = pendingEdgeLoadRef.current;
    pendingEdgeLoadRef.current = null;
    if (pending === "older") {
      loadOlderPageRef.current();
      return;
    }
    if (pending === "newer") {
      loadNewerPageRef.current();
    }
  }, []);

  useEffect(() => {
    snapshotRef.current = snapshot;
  }, [snapshot]);

  useEffect(() => {
    monthIndexRef.current = timelineMonthIndex;
  }, [timelineMonthIndex]);

  useEffect(() => {
    windowRef.current = timelineWindow;
  }, [timelineWindow]);

  const timelineItemCount = useMemo(
    () => totalCountFromMonthIndex(timelineMonthIndex),
    [timelineMonthIndex],
  );

  const fullReplaceInFlightRef = useRef(false);
  const firstFullReplaceDoneRef = useRef(false);

  // Converts Original records + ThumbnailSets into TimelineItems for a small batch.
  const buildPageItems = useCallback(async (
    engine: GitdbWorkerClient,
    originals: RegisteredManifestRecord[],
  ): Promise<TimelineItem[]> => {
    if (originals.length === 0) return [];
    const originalRefs = originals.map((r) =>
      `${(r.manifest as AnyManifest).metadata.deviceSpace}/${r.apiVersion}/${r.kind}/${(r.manifest as AnyManifest).metadata.name}`,
    );
    const thumbRecords: RegisteredManifestRecord[] = [];
    for (const ref of originalRefs) {
      const results = await engine.query(THUMBNAIL_IDENTITY, { type: "index", indexName: "byOriginalRef", equals: ref }) as RegisteredManifestRecord[];
      thumbRecords.push(...results);
    }
    const allRecords = [...originals, ...thumbRecords];
    const paths = collectPointerPaths(allRecords);
    const pointerMap = paths.length > 0
      ? await engine.queryPointers(paths)
      : new Map<string, LfsPointerFields>();
    const recordsByKind = new Map<string, RegisteredManifestRecord[]>([
      ["media.replycant.com/v1alpha1::Original", originals],
      ["media.replycant.com/v1alpha1::ThumbnailSet", thumbRecords],
    ]);
    const { originals: normalizedOriginals, thumbnails } = recordsToNormalized(recordsByKind, pointerMap);
    const thumbMap = groupThumbnailsByOriginal(thumbnails);
    const dpr = computeDpr();
    return buildTimeline(normalizedOriginals, thumbMap, 280, dpr);
  }, []);

  // Loads a page of items starting at a given takenAt cursor position.
  const loadPageAfterCursor = useCallback(async (
    engine: GitdbWorkerClient,
    cursor: TimelineCursor | null,
    limit: number,
  ): Promise<TimelineItem[]> => {
    const range = cursor
      ? { lower: cursor.takenAt, lowerOpen: false }
      : undefined;
    const records = await engine.query(
      ORIGINAL_IDENTITY,
      { type: "cursor", indexName: "byTakenAt", range, direction: "next", limit: limit + 20 },
    ) as RegisteredManifestRecord[];
    // Skip past cursor tiebreaker
    let startIdx = 0;
    if (cursor) {
      for (let i = 0; i < records.length; i++) {
        const rec = records[i];
        const takenAt = (rec.manifest as { spec?: { takenAt?: string } })?.spec?.takenAt ?? "";
        if (takenAt < cursor.takenAt) { startIdx = i + 1; continue; }
        if (takenAt === cursor.takenAt && rec.key <= cursor.key) { startIdx = i + 1; continue; }
        break;
      }
    }
    const page = records.slice(startIdx, startIdx + limit);
    return buildPageItems(engine, page);
  }, [buildPageItems]);

  // Loads a page of items before a given cursor position (for backward scrolling).
  const loadPageBeforeCursor = useCallback(async (
    engine: GitdbWorkerClient,
    cursor: TimelineCursor,
    limit: number,
  ): Promise<TimelineItem[]> => {
    const range = { upper: cursor.takenAt, upperOpen: false };
    const records = await engine.query(
      ORIGINAL_IDENTITY,
      { type: "cursor", indexName: "byTakenAt", range, direction: "prev", limit: limit + 20 },
    ) as RegisteredManifestRecord[];
    // Skip past cursor tiebreaker (records are in reverse order)
    let startIdx = 0;
    for (let i = 0; i < records.length; i++) {
      const rec = records[i];
      const takenAt = (rec.manifest as { spec?: { takenAt?: string } })?.spec?.takenAt ?? "";
      if (takenAt > cursor.takenAt) { startIdx = i + 1; continue; }
      if (takenAt === cursor.takenAt && rec.key >= cursor.key) { startIdx = i + 1; continue; }
      break;
    }
    const page = records.slice(startIdx, startIdx + limit);
    page.reverse();
    return buildPageItems(engine, page);
  }, [buildPageItems]);

  // Loads a fresh region around a takenAt value, used for month jumps and anchor restore.
  const loadFreshRegion = useCallback(async (
    engine: GitdbWorkerClient,
    takenAt: string,
    loadedOffset: number,
    generation: number,
    limit = PAGE_SIZE,
  ): Promise<void> => {
    const startedAtMs = Date.now();
    const range = { lower: takenAt, lowerOpen: false };
    const records = await engine.query(
      ORIGINAL_IDENTITY,
      { type: "cursor", indexName: "byTakenAt", range, direction: "next", limit },
    ) as RegisteredManifestRecord[];
    const items = await buildPageItems(engine, records);
    if (generation !== timelineLoadGenerationRef.current) return;
    if (items.length === 0) {
      setTimelineWindow(EMPTY_WINDOW);
      return;
    }
    const newWindow: TimelineWindow = {
      loadedOffset,
      loadedItems: items,
      olderCursor: cursorFromItem(items[0]),
      newerCursor: cursorFromItem(items[items.length - 1]),
    };
    setTimelineWindow((current) => (timelineWindowEquals(current, newWindow) ? current : newWindow));
    logAppDebug("load-fresh-region-complete", { items: items.length, loadedOffset, durationMs: Date.now() - startedAtMs });
  }, [buildPageItems]);

  // Loads a fresh region by global index using month offset + cursor skip for precise random seeks.
  const loadFreshRegionAtIndex = useCallback(async (
    engine: GitdbWorkerClient,
    index: number,
    months: MonthEntry[],
    generation: number,
  ): Promise<void> => {
    if (months.length === 0) {
      setTimelineWindow(EMPTY_WINDOW);
      return;
    }
    const startedAtMs = Date.now();
    const totalCount = totalCountFromMonthIndex(months);
    const clampedIndex = Math.max(0, Math.min(index, Math.max(0, totalCount - 1)));
    let targetMonth: MonthEntry | null = null;
    for (let i = months.length - 1; i >= 0; i--) {
      if (months[i].globalOffset <= clampedIndex) {
        targetMonth = months[i];
        break;
      }
    }
    if (!targetMonth) {
      setTimelineWindow(EMPTY_WINDOW);
      return;
    }
    const withinMonthOffset = Math.max(0, clampedIndex - targetMonth.globalOffset);
    const records = await engine.query(
      ORIGINAL_IDENTITY,
      {
        type: "cursor",
        indexName: "byTakenAt",
        range: { lower: targetMonth.firstTakenAt, lowerOpen: false },
        direction: "next",
        skip: withinMonthOffset,
        limit: PAGE_SIZE,
      },
    ) as RegisteredManifestRecord[];
    const items = await buildPageItems(engine, records);
    if (generation !== timelineLoadGenerationRef.current) return;
    if (items.length === 0) {
      setTimelineWindow(EMPTY_WINDOW);
      return;
    }
    const loadedOffset = targetMonth.globalOffset + withinMonthOffset;
    setTimelineWindow({
      loadedOffset,
      loadedItems: items,
      olderCursor: cursorFromItem(items[0]),
      newerCursor: cursorFromItem(items[items.length - 1]),
    });
    logAppDebug("load-fresh-region-at-index-complete", { index: clampedIndex, items: items.length, loadedOffset, durationMs: Date.now() - startedAtMs });
  }, [buildPageItems]);

  const refreshMonthIndex = useCallback(async (): Promise<MonthEntry[]> => {
    const engine = engineRef.current;
    if (!engine) return [];
    const startedAtMs = Date.now();
    try {
      const rows = await engine.queryDerived<MonthCountRow>("timeline_month_counts", { type: "getAll" });
      if (Array.isArray(rows)) {
        const entries = buildMonthEntries(rows);
        setTimelineMonthIndex(entries);
        logAppDebug("refresh-month-index-complete", { months: entries.length, durationMs: Date.now() - startedAtMs });
        return entries;
      }
    } catch (error) {
      console.error("[replycant-app] month index refresh failed", error);
    }
    return [];
  }, []);

  // Loads initial page around the newest items after month index is ready.
  const loadInitialPage = useCallback(async (engine: GitdbWorkerClient, months: MonthEntry[], generation: number) => {
    const totalCount = totalCountFromMonthIndex(months);
    if (totalCount === 0) {
      setTimelineWindow(EMPTY_WINDOW);
      return;
    }
    const startedAtMs = Date.now();
    // Load the newest items (end of timeline)
    const records = await engine.query(
      ORIGINAL_IDENTITY,
      { type: "cursor", indexName: "byTakenAt", direction: "prev", limit: PAGE_SIZE },
    ) as RegisteredManifestRecord[];
    records.reverse();
    const items = await buildPageItems(engine, records);
    if (generation !== timelineLoadGenerationRef.current) return;
    if (items.length === 0) {
      setTimelineWindow(EMPTY_WINDOW);
      return;
    }
    const loadedOffset = Math.max(0, totalCount - items.length);
    const newWindow: TimelineWindow = {
      loadedOffset,
      loadedItems: items,
      olderCursor: cursorFromItem(items[0]),
      newerCursor: cursorFromItem(items[items.length - 1]),
    };
    setTimelineWindow(newWindow);
    logAppDebug("load-initial-page-complete", { items: items.length, loadedOffset, durationMs: Date.now() - startedAtMs });
  }, [buildPageItems]);

  // Reloads the currently visible sparse region from canonical cache state after incremental sync commits.
  const reloadCurrentWindow = useCallback(async (
    engine: GitdbWorkerClient,
    months: MonthEntry[],
    generation: number,
  ) => {
    const currentWindow = windowRef.current;
    if (currentWindow.loadedItems.length === 0 || !currentWindow.olderCursor) {
      await loadInitialPage(engine, months, generation);
      return;
    }

    const anchor = currentWindow.olderCursor;
    let anchorMonth: MonthEntry | null = null;
    for (let i = months.length - 1; i >= 0; i -= 1) {
      if (months[i].firstTakenAt <= anchor.takenAt) {
        anchorMonth = months[i];
        break;
      }
    }
    if (!anchorMonth) {
      await loadInitialPage(engine, months, generation);
      return;
    }

    let exactOffset = anchorMonth.globalOffset;
    if (anchor.takenAt > anchorMonth.firstTakenAt) {
      const countBefore = await engine.query(
        ORIGINAL_IDENTITY,
        {
          type: "count",
          indexName: "byTakenAt",
          range: {
            lower: anchorMonth.firstTakenAt,
            upper: anchor.takenAt,
            lowerOpen: false,
            upperOpen: true,
          },
        },
      );
      exactOffset += typeof countBefore === "number" ? countBefore : 0;
    }

    await loadFreshRegion(
      engine,
      anchor.takenAt,
      exactOffset,
      generation,
      Math.max(PAGE_SIZE, currentWindow.loadedItems.length),
    );
  }, [loadFreshRegion, loadInitialPage]);

  const handleManifestChange = useCallback((change: ManifestDatabaseChange) => {
    if (change.type === "fullReplace") {
      if (fullReplaceInFlightRef.current) return;
      fullReplaceInFlightRef.current = true;
      const shouldAttemptHashAnchorRestore = !firstFullReplaceDoneRef.current;
      firstFullReplaceDoneRef.current = true;
      const startedAtMs = Date.now();
      logAppDebug("manifest-change-full-replace-start", {});
      const engine = engineRef.current;
      if (!engine) {
        fullReplaceInFlightRef.current = false;
        return;
      }
      const generation = timelineLoadGenerationRef.current + 1;
      timelineLoadGenerationRef.current = generation;
      void (async () => {
        try {
          const months = await refreshMonthIndex();
          const anchorTakenAt = shouldAttemptHashAnchorRestore ? parseHashAnchorTakenAt() : null;
          if (anchorTakenAt) {
            let anchorMonth: MonthEntry | null = null;
            for (let i = months.length - 1; i >= 0; i--) {
              if (months[i].firstTakenAt <= anchorTakenAt) {
                anchorMonth = months[i];
                break;
              }
            }
            if (anchorMonth) {
              let exactOffset = anchorMonth.globalOffset;
              if (anchorTakenAt > anchorMonth.firstTakenAt) {
                const countBefore = await engine.query(
                  ORIGINAL_IDENTITY,
                  {
                    type: "count",
                    indexName: "byTakenAt",
                    range: {
                      lower: anchorMonth.firstTakenAt,
                      upper: anchorTakenAt,
                      lowerOpen: false,
                      upperOpen: true,
                    },
                  },
                );
                exactOffset += typeof countBefore === "number" ? countBefore : 0;
              }
              await loadFreshRegion(engine, anchorTakenAt, exactOffset, generation);
            } else {
              await loadInitialPage(engine, months, generation);
            }
          } else {
            await loadInitialPage(engine, months, generation);
          }
          logAppDebug("manifest-change-full-replace-complete", {
            durationMs: Date.now() - startedAtMs,
          });
        } catch (error) {
          console.error("[replycant-app] fullReplace failed", error);
        } finally {
          fullReplaceInFlightRef.current = false;
        }
      })();
      return;
    }

    if (
      change.mutation.added.length === 0
      && change.mutation.removed.length === 0
      && change.mutation.updated.length === 0
    ) {
      return;
    }

    // Reloads only when mutations intersect the loaded span; otherwise adjusts offset in place.
    const startedAtMs = Date.now();
    const engine = engineRef.current;
    if (!engine) return;
    const generation = timelineLoadGenerationRef.current + 1;
    timelineLoadGenerationRef.current = generation;
    const currentWindow = windowRef.current;
    const touchesLoadedWindow = mutationTouchesLoadedWindow(change.mutation, currentWindow);

    void (async () => {
      try {
        const months = await refreshMonthIndex();
        if (touchesLoadedWindow) {
          await reloadCurrentWindow(engine, months, generation);
        } else if (currentWindow.loadedItems.length > 0 && currentWindow.olderCursor) {
          const anchor = currentWindow.olderCursor;
          let anchorMonth: MonthEntry | null = null;
          for (let i = months.length - 1; i >= 0; i -= 1) {
            if (months[i].firstTakenAt <= anchor.takenAt) {
              anchorMonth = months[i];
              break;
            }
          }
          if (anchorMonth) {
            let exactOffset = anchorMonth.globalOffset;
            if (anchor.takenAt > anchorMonth.firstTakenAt) {
              const countBefore = await engine.query(
                ORIGINAL_IDENTITY,
                {
                  type: "count",
                  indexName: "byTakenAt",
                  range: {
                    lower: anchorMonth.firstTakenAt,
                    upper: anchor.takenAt,
                    lowerOpen: false,
                    upperOpen: true,
                  },
                },
              );
              exactOffset += typeof countBefore === "number" ? countBefore : 0;
            }
            if (generation !== timelineLoadGenerationRef.current) return;
            // Applies the offset to the current window even after a concurrent
            // edge merge, as long as the counted older cursor is still the anchor.
            setTimelineWindow((windowState) => {
              if (
                !windowState.olderCursor
                || windowState.olderCursor.key !== anchor.key
                || windowState.olderCursor.takenAt !== anchor.takenAt
              ) {
                return windowState;
              }
              if (windowState.loadedOffset === exactOffset) return windowState;
              return {
                loadedOffset: exactOffset,
                loadedItems: windowState.loadedItems,
                olderCursor: windowState.olderCursor,
                newerCursor: windowState.newerCursor,
              };
            });
          }
        }

        logAppDebug("manifest-change-incremental-complete", {
          added: change.mutation.added.length,
          removed: change.mutation.removed.length,
          updated: change.mutation.updated.length,
          durationMs: Date.now() - startedAtMs,
        });
      } catch (error) {
        console.error("[replycant-app] incremental mutation failed", error);
      }
    })();
  }, [refreshMonthIndex, reloadCurrentWindow]);

  const loadOlderPage = useCallback(() => {
    const engine = engineRef.current;
    const window = windowRef.current;
    if (!engine || !window.olderCursor || window.loadedOffset === 0) return;
    if (loadingPageRef.current) {
      pendingEdgeLoadRef.current = "older";
      return;
    }
    const generation = timelineLoadGenerationRef.current;
    const startOffset = window.loadedOffset;
    const startOlderCursor = window.olderCursor;
    loadingPageRef.current = true;
    void (async () => {
      try {
        const items = await loadPageBeforeCursor(engine, window.olderCursor!, PAGE_SIZE);
        if (items.length === 0) return;
        const currentWindow = windowRef.current;
        if (
          generation !== timelineLoadGenerationRef.current
          || currentWindow.loadedOffset !== startOffset
          || currentWindow.olderCursor?.key !== startOlderCursor?.key
          || currentWindow.olderCursor?.takenAt !== startOlderCursor?.takenAt
        ) {
          pendingEdgeLoadRef.current = "older";
          return;
        }
        const newOffset = Math.max(0, window.loadedOffset - items.length);
        const merged = [...items, ...window.loadedItems];
        // Sync the ref before replaying a pending edge load so the retry sees
        // the merged window instead of the pre-await snapshot.
        const nextWindow = {
          loadedOffset: newOffset,
          loadedItems: merged,
          olderCursor: cursorFromItem(merged[0]),
          newerCursor: cursorFromItem(merged[merged.length - 1]),
        };
        windowRef.current = nextWindow;
        setTimelineWindow(nextWindow);
      } catch (error) {
        console.error("[replycant-app] loadOlderPage failed", error);
      } finally {
        loadingPageRef.current = false;
        flushPendingEdgeLoad();
      }
    })();
  }, [flushPendingEdgeLoad, loadPageBeforeCursor]);

  const loadNewerPage = useCallback(() => {
    const engine = engineRef.current;
    const window = windowRef.current;
    const months = monthIndexRef.current;
    const totalCount = totalCountFromMonthIndex(months);
    if (!engine || !window.newerCursor || (window.loadedOffset + window.loadedItems.length >= totalCount)) return;
    if (loadingPageRef.current) {
      pendingEdgeLoadRef.current = "newer";
      return;
    }
    const generation = timelineLoadGenerationRef.current;
    const startOffset = window.loadedOffset;
    const startNewerCursor = window.newerCursor;
    loadingPageRef.current = true;
    void (async () => {
      try {
        const items = await loadPageAfterCursor(engine, window.newerCursor!, PAGE_SIZE);
        if (items.length === 0) return;
        const currentWindow = windowRef.current;
        if (
          generation !== timelineLoadGenerationRef.current
          || currentWindow.loadedOffset !== startOffset
          || currentWindow.newerCursor?.key !== startNewerCursor?.key
          || currentWindow.newerCursor?.takenAt !== startNewerCursor?.takenAt
        ) {
          pendingEdgeLoadRef.current = "newer";
          return;
        }
        const merged = [...window.loadedItems, ...items];
        // Sync the ref before replaying a pending edge load so the retry sees
        // the merged window instead of the pre-await snapshot.
        const nextWindow = {
          loadedOffset: window.loadedOffset,
          loadedItems: merged,
          olderCursor: cursorFromItem(merged[0]),
          newerCursor: cursorFromItem(merged[merged.length - 1]),
        };
        windowRef.current = nextWindow;
        setTimelineWindow(nextWindow);
      } catch (error) {
        console.error("[replycant-app] loadNewerPage failed", error);
      } finally {
        loadingPageRef.current = false;
        flushPendingEdgeLoad();
      }
    })();
  }, [flushPendingEdgeLoad, loadPageAfterCursor]);

  loadOlderPageRef.current = loadOlderPage;
  loadNewerPageRef.current = loadNewerPage;

  const seekToIndex = useCallback((index: number) => {
    const engine = engineRef.current;
    const months = monthIndexRef.current;
    if (!engine || months.length === 0) return;
    const generation = timelineLoadGenerationRef.current + 1;
    timelineLoadGenerationRef.current = generation;
    setTimelineWindow(EMPTY_WINDOW);
    void loadFreshRegionAtIndex(engine, index, months, generation);
  }, [loadFreshRegionAtIndex]);

  const initializeEngine = useCallback(async (): Promise<GitdbWorkerClient> => {
    if (engineInitPromiseRef.current) return engineInitPromiseRef.current;
    if (engineRef.current) return engineRef.current;
    const engine = createGitdbWorker({
      onSnapshot: setSnapshot,
      onManifestChange: handleManifestChange,
      mtlsHeadersProvider: () => mtlsHeadersRef.current,
      agePrivateKeyProvider: () => agePrivateKeyRef.current,
      initialCloneDepth: consumeResetCloneDepthOverride(),
      registrations: [originalRegistration, thumbnailSetRegistration],
    });
    engineRef.current = engine;
    const initPromise: Promise<GitdbWorkerClient> = (async () => {
      try {
        await engine.initialize();
        await engine.setSyncIntervalMs(periodicSyncPrefsRef.current.intervalMs);
        await engine.setUserPeriodicSyncPaused(!periodicSyncPrefsRef.current.userEnabled);
        return engine;
      } catch (error) {
        if (engineRef.current === engine) {
          engineRef.current = null;
        }
        throw error;
      }
    })();
    engineInitPromiseRef.current = initPromise;
    void initPromise.finally(() => {
      if (engineInitPromiseRef.current === initPromise) {
        engineInitPromiseRef.current = null;
      }
    });
    return initPromise;
  }, [handleManifestChange]);

  useEffect(() => {
    engineRef.current?.updateProviders(mtlsHeaders, agePrivateKeyBase64);
  }, [agePrivateKeyBase64, mtlsHeaders]);

  useEffect(() => {
    if (setupMode !== "rehydrating") return;
    let mounted = true;
    void (async () => {
      try {
        const engine = await initializeEngine();
        if (!mounted) return;
        const { hasCachedData } = await engine.bootstrapFromCache();
        if (!mounted) return;
        if (hasCachedData) {
          bootstrapDoneRef.current = true;
          startupRetryRef.current = true;
          setSetupMode("ready");
          void engine.syncNow("startup");
          return;
        }
        await engine.bootstrap();
        if (!mounted) return;
        bootstrapDoneRef.current = true;
        setSetupMode("ready");
      } catch (error) {
        if (!mounted) return;
        setSetupError(
          error instanceof Error
            ? `Sync failed: ${error.message}`
            : "Sync failed with an unknown error.",
        );
      }
    })();
    return () => {
      mounted = false;
    };
  }, [initializeEngine, rehydrationKey, setSetupError, setSetupMode, setupMode]);

  useEffect(() => {
    if (setupMode !== "ready") return;
    let mounted = true;
    if (!bootstrapDoneRef.current) {
      void (async () => {
        try {
          const engine = await initializeEngine();
          if (!mounted) return;
          await engine.bootstrap();
          bootstrapDoneRef.current = true;
        } catch (error) {
          if (!mounted) return;
          setSnapshot((previous) => ({
            ...previous,
            syncing: false,
            error:
              error instanceof Error
                ? `Startup failed: ${error.message}. Try Sync now to retry.`
                : "Startup failed with an unknown error.",
          }));
        }
      })();
    }

    const onVisibilityChange = () => {
      engineRef.current?.updateVisibility(document.hidden);
    };
    engineRef.current?.updateVisibility(document.hidden);
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      document.removeEventListener("visibilitychange", onVisibilityChange);
      mounted = false;
      engineRef.current?.shutdown();
      engineRef.current = null;
      engineInitPromiseRef.current = null;
    };
  }, [initializeEngine, setupMode]);

  useEffect(() => {
    if (setupMode !== "qr" || pollingAuthorizationRef.current) return;
    pollingAuthorizationRef.current = true;
    let cancelled = false;
    const timer = window.setInterval(() => {
      if (cancelled) return;
      void (async () => {
        try {
          const engine = await initializeEngine();
          const probe = await engine.probeOnboardingAuthorization();
          if (cancelled) return;
          if (probe.status === "authorized") {
            setSetupError(null);
            setSetupMode("rehydrating");
            window.clearInterval(timer);
            pollingAuthorizationRef.current = false;
            return;
          }
          if (probe.status === "pending_authorization") {
            setSetupError(null);
            return;
          }
          setSetupError(probe.message);
        } catch (error) {
          setSetupError(
            error instanceof Error ? `Authorization check failed: ${error.message}` : "Authorization check failed.",
          );
        }
      })();
    }, 2_500);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
      pollingAuthorizationRef.current = false;
    };
  }, [initializeEngine, setSetupError, setSetupMode, setupMode]);

  const handleSyncNow = useCallback(async () => {
    if (snapshotRef.current.isOffHead) {
      setSnapshot((previous) => ({
        ...previous,
        error: "Sync is unavailable while not on HEAD. Return to head to sync.",
      }));
      return;
    }
    try {
      const engine = await initializeEngine();
      await engine.syncNow("manual");
    } catch (error) {
      setSnapshot((previous) => ({
        ...previous,
        syncing: false,
        error:
          error instanceof Error
            ? `Manual sync failed: ${error.message}`
            : "Manual sync failed with an unknown error.",
      }));
    }
  }, [initializeEngine]);

  // Applies user auto-sync preference so periodic polling can be toggled from the commit pane.
  const handleTogglePeriodicSync = useCallback(async (enabled: boolean) => {
    const prefs = {
      ...periodicSyncPrefsRef.current,
      userEnabled: enabled,
    };
    periodicSyncPrefsRef.current = prefs;
    writePeriodicSyncPrefs(prefs);
    try {
      const engine = await initializeEngine();
      await engine.setUserPeriodicSyncPaused(!enabled);
    } catch (error) {
      setSnapshot((previous) => ({
        ...previous,
        error: error instanceof Error ? `Failed to update periodic sync: ${error.message}` : "Failed to update periodic sync.",
      }));
    }
  }, [initializeEngine]);

  // Applies user polling interval so sync cadence can be tuned from the commit pane.
  const handleChangeSyncInterval = useCallback(async (intervalMs: number) => {
    if (!SUPPORTED_PERIODIC_SYNC_INTERVALS_MS.has(intervalMs)) return;
    const prefs = {
      ...periodicSyncPrefsRef.current,
      intervalMs,
    };
    periodicSyncPrefsRef.current = prefs;
    writePeriodicSyncPrefs(prefs);
    try {
      const engine = await initializeEngine();
      await engine.setSyncIntervalMs(intervalMs);
    } catch (error) {
      setSnapshot((previous) => ({
        ...previous,
        error: error instanceof Error ? `Failed to update sync interval: ${error.message}` : "Failed to update sync interval.",
      }));
    }
  }, [initializeEngine]);

  const loadRewindCommitOptions = useCallback(async () => {
    const startedAtMs = Date.now();
    logAppDebug("load-rewind-commits-start", { limit: 30 });
    try {
      const engine = await initializeEngine();
      const commits = await engine.listRecentLocalCommits(30);
      setRewindCommits(commits);
      logAppDebug("load-rewind-commits-complete", { commits: commits.length, durationMs: Date.now() - startedAtMs });
    } catch (error) {
      logAppDebug("load-rewind-commits-failed", { durationMs: Date.now() - startedAtMs, error: error instanceof Error ? error.message : String(error) });
      setSnapshot((previous) => ({
        ...previous,
        error: error instanceof Error ? `Failed to load rewind commits: ${error.message}` : "Failed to load rewind commits.",
      }));
    }
  }, [initializeEngine]);

  useEffect(() => {
    if (setupMode !== "ready") return;
    if (startupRetryRef.current) return;
    if (snapshotRef.current.syncing || snapshotRef.current.lastSyncAt) return;
    startupRetryRef.current = true;
    void handleSyncNow();
  }, [handleSyncNow, setupMode]);

  useEffect(() => {
    if (setupMode !== "ready") return;
    void loadRewindCommitOptions();
  }, [loadRewindCommitOptions, setupMode, snapshot.syncedCommitHash]);

  const handleResetToRemote = useCallback(async () => {
    if (!window.confirm("Reset local sync state to the remote branch head? This discards local divergence.")) {
      return;
    }
    try {
      const engine = await initializeEngine();
      await engine.hardResetToRemoteAfterPermission();
    } catch (error) {
      setSnapshot((previous) => ({
        ...previous,
        syncing: false,
        error: error instanceof Error ? `Reset failed: ${error.message}` : "Reset failed with an unknown error.",
      }));
    }
  }, [initializeEngine]);

  // Routes commit jumps to rewind or forward so DevTools and commit-pane selection share one code path.
  const handleJumpToCommit = useCallback(async (commitHash: string, options?: { isHead: boolean }) => {
    const normalizedCommitHash = commitHash.trim();
    if (!normalizedCommitHash || rewindActionBusy) return;
    const startedAtMs = Date.now();
    try {
      logAppDebug("jump-to-commit-start", { commitHash: normalizedCommitHash, isHeadOption: options?.isHead ?? false, startedAtMs });
      const initializeStartedAtMs = Date.now();
      const engine = await initializeEngine();
      const initializeDurationMs = Date.now() - initializeStartedAtMs;
      const resolveHeadStartedAtMs = Date.now();
      const trackedRemoteHead = await engine.readTrackedRemoteHeadCommitHashOrNull();
      const resolveHeadDurationMs = Date.now() - resolveHeadStartedAtMs;
      const commitInputLower = normalizedCommitHash.toLowerCase();
      const matchingKnownCommits = commitInputLower.length < 40
        ? rewindCommits.filter((commit) => commit.hash.toLowerCase().startsWith(commitInputLower))
        : [];
      if (matchingKnownCommits.length > 1) {
        const prefixes = matchingKnownCommits.slice(0, 5).map((commit) => commit.hash.slice(0, 10));
        setSnapshot((previous) => ({
          ...previous,
          error: `Commit prefix '${normalizedCommitHash}' is ambiguous (${prefixes.join(", ")}...).`,
        }));
        logAppDebug("jump-to-commit-ambiguous-prefix", {
          commitHash: normalizedCommitHash,
          matches: matchingKnownCommits.length,
          sampleMatches: prefixes,
        });
        return;
      }
      const resolvedCommitHash = matchingKnownCommits.length === 1
        ? matchingKnownCommits[0].hash
        : normalizedCommitHash;
      const normalizedTrackedHead = trackedRemoteHead?.toLowerCase() ?? null;
      const normalizedInputHash = resolvedCommitHash.toLowerCase();
      const matchesTrackedHead = normalizedTrackedHead
        ? normalizedInputHash === normalizedTrackedHead || normalizedTrackedHead.startsWith(normalizedInputHash)
        : false;
      const jumpToHead = options?.isHead === true || matchesTrackedHead;
      logAppDebug("jump-to-commit-decision", {
        commitHash: normalizedCommitHash,
        resolvedCommitHash,
        trackedRemoteHead,
        matchesTrackedHead,
        jumpToHead,
        initializeDurationMs,
        resolveHeadDurationMs,
      });
      setRewindActionBusy(jumpToHead ? "forward" : "rewind");
      const actionStartedAtMs = Date.now();
      if (jumpToHead) {
        try {
          await engine.forwardToRemoteHeadAndResumePolling();
        } catch (error) {
          // Falls back to direct rewind so short-hash head jumps still succeed when origin refs are unavailable.
          logAppDebug("jump-to-commit-forward-fallback", {
            commitHash: resolvedCommitHash,
            error: error instanceof Error ? error.message : String(error),
          });
          await engine.rewindToCommitAndPausePolling(resolvedCommitHash);
        }
      } else {
        await engine.rewindToCommitAndPausePolling(resolvedCommitHash);
      }
      const actionDurationMs = Date.now() - actionStartedAtMs;
      logAppDebug("jump-to-commit-complete", {
        commitHash: resolvedCommitHash,
        jumpToHead,
        actionDurationMs,
        totalDurationMs: Date.now() - startedAtMs,
        commitRefresh: "scheduled_async",
      });
      void loadRewindCommitOptions();
    } catch (error) {
      logAppDebug("jump-to-commit-failed", {
        commitHash: normalizedCommitHash,
        durationMs: Date.now() - startedAtMs,
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    } finally {
      setRewindActionBusy(null);
    }
  }, [initializeEngine, loadRewindCommitOptions, rewindActionBusy, rewindCommits]);

  const wipeReplycantState = useCallback(async (initialCloneDepth?: number, wipeKeypair?: boolean, wipeServerConfig?: boolean) => {
    engineRef.current?.shutdown();
    engineRef.current = null;
    engineInitPromiseRef.current = null;
    if (Number.isInteger(initialCloneDepth) && (initialCloneDepth ?? 0) > 0) {
      sessionStorage.setItem(RESET_CLONE_DEPTH_SESSION_KEY, String(initialCloneDepth));
    } else {
      sessionStorage.removeItem(RESET_CLONE_DEPTH_SESSION_KEY);
    }
    if (wipeServerConfig) {
      localStorage.removeItem(SETUP_CONFIG_STORAGE_KEY);
    }
    if (wipeKeypair) {
      clearIdentityRecord();
      localStorage.removeItem(IDENTITY_STORAGE_KEY);
    }
    const databaseNames = new Set(REPLYCANT_DB_FALLBACK_NAMES);
    if (typeof indexedDB.databases === "function") {
      try {
        const knownDatabases = await indexedDB.databases();
        for (const database of knownDatabases) {
          if (database.name?.startsWith("gitdb") || database.name?.startsWith("replycant-git")) {
            databaseNames.add(database.name);
          }
        }
      } catch {
        // Keeps fallback database deletion path active when browsers block listing APIs.
      }
    }
    await Promise.allSettled([...databaseNames].map((name) => deleteIndexedDbDatabase(name)));
    window.location.reload();
  }, []);

  // Exposes timeline paging through a generic sparse-grid data contract.
  const timelineDataSource = useMemo<SparseGridDataSource<TimelineItem>>(() => ({
    itemCount: timelineItemCount,
    window: {
      loadedOffset: timelineWindow.loadedOffset,
      loadedItems: timelineWindow.loadedItems,
    },
    onLoadOlder: loadOlderPage,
    onLoadNewer: loadNewerPage,
    onSeekToIndex: seekToIndex,
  }), [loadNewerPage, loadOlderPage, seekToIndex, timelineItemCount, timelineWindow.loadedItems, timelineWindow.loadedOffset]);

  return useMemo(() => ({
    snapshot,
    timelineItemCount,
    timelineMonthIndex,
    timelineWindow,
    timelineDataSource,
    rewindCommits,
    rewindActionBusy,
    initializeEngine,
    handleSyncNow,
    handleTogglePeriodicSync,
    handleChangeSyncInterval,
    handleResetToRemote,
    handleJumpToCommit,
    wipeReplycantState,
    loadOlderPage,
    loadNewerPage,
    seekToIndex,
  }), [
    handleJumpToCommit,
    handleChangeSyncInterval,
    handleResetToRemote,
    handleSyncNow,
    handleTogglePeriodicSync,
    initializeEngine,
    loadNewerPage,
    loadOlderPage,
    rewindActionBusy,
    rewindCommits,
    seekToIndex,
    snapshot,
    timelineDataSource,
    timelineItemCount,
    timelineMonthIndex,
    timelineWindow,
    wipeReplycantState,
  ]);
};
