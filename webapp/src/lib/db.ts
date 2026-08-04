import { DBSchema, IDBPDatabase, openDB } from "idb";
import { NormalizedOriginal, NormalizedThumbnail } from "../types/manifests";

interface ReplycantDb extends DBSchema {
  originals: {
    key: string;
    value: NormalizedOriginal;
    indexes: { byTakenAt: string };
  };
  thumbnails: {
    key: string;
    value: NormalizedThumbnail;
    indexes: { byOriginalKey: string };
  };
  meta: {
    key: string;
    value: { key: string; value: string };
  };
}

export interface CacheLoadResult {
  originals: NormalizedOriginal[];
  thumbByOriginalKey: Map<string, NormalizedThumbnail[]>;
  syncedCommitHash: string | null;
}

export interface CachePageOptions {
  limit: number;
  beforeTakenAt?: string | null;
}

export interface CachePageResult {
  originals: NormalizedOriginal[];
  thumbByOriginalKey: Map<string, NormalizedThumbnail[]>;
  syncedCommitHash: string | null;
  nextBeforeTakenAt: string | null;
  hasMore: boolean;
}

export interface ReplaceCacheOptions {
  crashAfterMarkInProgress?: boolean;
  crashDuringCommit?: boolean;
}

export interface IncrementalCacheMutation {
  removeOriginalKeys: string[];
  removeThumbnailKeys: string[];
  upsertOriginals: NormalizedOriginal[];
  upsertThumbnails: NormalizedThumbnail[];
}

export interface IncrementalCacheApplyOptions {
  expectedSyncedCommitHash: string | null;
  nextSyncedCommitHash: string;
  mutation: IncrementalCacheMutation;
}

export interface IncrementalCacheApplyResult {
  outcome: "applied" | "stale";
}

// Provides consistent timing across cache update logs without relying on optional browser APIs.
const nowMs = (): number => Date.now();

// Emits structured DB sync diagnostics so incremental/cas behavior can be traced in production.
const logDbSyncDebug = (event: string, fields: Record<string, unknown>): void => {
  const duration = typeof fields.durationMs === "number" ? `${(fields.durationMs / 1000).toFixed(2)}s ` : "";
  console.debug(`[replycant-db-sync] ${duration}${event}`, fields);
};

// Defines sync metadata keys so cache state can recover safely after interrupted writes.
const META_SYNC_STATE = "syncState";
const META_STAGED_COMMIT_HASH = "stagedCommitHash";
const META_SYNCED_COMMIT_HASH = "syncedCommitHash";
const META_LAST_SYNC_AT = "lastSyncAt";

// Ensures metadata reads default to a safe value when key has not been written yet.
const readMetaValue = async (
  db: IDBPDatabase<ReplycantDb>,
  key: string,
): Promise<string | null> => {
  const row = await db.get("meta", key);
  return row?.value ?? null;
};

// Exposes the committed sync revision so sync can compute commit-to-commit diffs from DB truth.
export const readSyncedCommitHash = async (db: IDBPDatabase<ReplycantDb>): Promise<string | null> =>
  readMetaValue(db, META_SYNCED_COMMIT_HASH);

// Clears interrupted sync markers so bootstrap never continues from ambiguous partial states.
export const recoverInterruptedCacheUpdate = async (
  db: IDBPDatabase<ReplycantDb>,
): Promise<boolean> => {
  const syncState = await readMetaValue(db, META_SYNC_STATE);
  if (syncState !== "in_progress") return false;
  const tx = db.transaction("meta", "readwrite");
  await tx.objectStore("meta").put({ key: META_SYNC_STATE, value: "idle" });
  await tx.objectStore("meta").delete(META_STAGED_COMMIT_HASH);
  await tx.done;
  return true;
};

// Marks intent to swap cache so interrupted operations are detectable after crashes.
const markCacheUpdateInProgress = async (
  db: IDBPDatabase<ReplycantDb>,
  stagedCommitHash: string,
): Promise<void> => {
  const tx = db.transaction("meta", "readwrite");
  await tx.objectStore("meta").put({ key: META_SYNC_STATE, value: "in_progress" });
  await tx.objectStore("meta").put({ key: META_STAGED_COMMIT_HASH, value: stagedCommitHash });
  await tx.done;
};

// Ensures manifest reads stay snappy by maintaining indexed timeline tables.
export const openReplycantDb = async (): Promise<IDBPDatabase<ReplycantDb>> =>
  openDB<ReplycantDb>("replycant", 1, {
    upgrade(database) {
      const originals = database.createObjectStore("originals", { keyPath: "key" });
      originals.createIndex("byTakenAt", "takenAt");
      const thumbnails = database.createObjectStore("thumbnails", { keyPath: "key" });
      thumbnails.createIndex("byOriginalKey", "originalKey");
      database.createObjectStore("meta", { keyPath: "key" });
    },
  });

// Replaces cached rows atomically so UI never mixes different sync revisions.
export const replaceCache = async (
  db: IDBPDatabase<ReplycantDb>,
  originals: NormalizedOriginal[],
  thumbnails: NormalizedThumbnail[],
  syncedCommitHash: string,
  options: ReplaceCacheOptions = {},
): Promise<void> => {
  const startedAtMs = nowMs();
  logDbSyncDebug("replace-cache-start", {
    syncedCommitHash,
    originals: originals.length,
    thumbnails: thumbnails.length,
  });
  await markCacheUpdateInProgress(db, syncedCommitHash);
  if (options.crashAfterMarkInProgress) {
    throw new Error("Simulated crash after in-progress marker was persisted.");
  }

  const tx = db.transaction(["originals", "thumbnails", "meta"], "readwrite");
  await tx.objectStore("originals").clear();
  await tx.objectStore("thumbnails").clear();
  for (const original of originals) {
    await tx.objectStore("originals").put(original);
  }
  for (const thumbnail of thumbnails) {
    await tx.objectStore("thumbnails").put(thumbnail);
  }
  if (options.crashDuringCommit) {
    tx.abort();
    await tx.done.catch(() => undefined);
    throw new Error("Simulated crash while committing cache transaction.");
  }
  await tx.objectStore("meta").put({ key: META_SYNC_STATE, value: "idle" });
  await tx.objectStore("meta").delete(META_STAGED_COMMIT_HASH);
  await tx.objectStore("meta").put({ key: META_SYNCED_COMMIT_HASH, value: syncedCommitHash });
  await tx.objectStore("meta").put({ key: META_LAST_SYNC_AT, value: new Date().toISOString() });
  await tx.done;
  logDbSyncDebug("replace-cache-complete", {
    syncedCommitHash,
    originals: originals.length,
    thumbnails: thumbnails.length,
    durationMs: nowMs() - startedAtMs,
  });
};

// Applies key-scoped cache mutations only when commit hash still matches expected old value.
export const applyIncrementalCacheUpdateWithCas = async (
  db: IDBPDatabase<ReplycantDb>,
  options: IncrementalCacheApplyOptions,
): Promise<IncrementalCacheApplyResult> => {
  const startedAtMs = nowMs();
  logDbSyncDebug("incremental-cas-start", {
    fromCommitHash: options.expectedSyncedCommitHash,
    toCommitHash: options.nextSyncedCommitHash,
    removeOriginalKeys: options.mutation.removeOriginalKeys.length,
    removeThumbnailKeys: options.mutation.removeThumbnailKeys.length,
    upsertOriginals: options.mutation.upsertOriginals.length,
    upsertThumbnails: options.mutation.upsertThumbnails.length,
  });
  const tx = db.transaction(["originals", "thumbnails", "meta"], "readwrite");
  const metaStore = tx.objectStore("meta");
  const currentSyncedHash = (await metaStore.get(META_SYNCED_COMMIT_HASH))?.value ?? null;
  if (currentSyncedHash !== options.expectedSyncedCommitHash) {
    tx.abort();
    await tx.done.catch(() => undefined);
    logDbSyncDebug("incremental-cas-stale", {
      fromCommitHash: options.expectedSyncedCommitHash,
      currentSyncedHash,
      toCommitHash: options.nextSyncedCommitHash,
      durationMs: nowMs() - startedAtMs,
    });
    return { outcome: "stale" };
  }

  await metaStore.put({ key: META_SYNC_STATE, value: "in_progress" });
  await metaStore.put({ key: META_STAGED_COMMIT_HASH, value: options.nextSyncedCommitHash });

  const originalsStore = tx.objectStore("originals");
  for (const key of options.mutation.removeOriginalKeys) {
    await originalsStore.delete(key);
  }
  for (const original of options.mutation.upsertOriginals) {
    await originalsStore.put(original);
  }

  const thumbnailsStore = tx.objectStore("thumbnails");
  const thumbnailsByOriginal = thumbnailsStore.index("byOriginalKey");
  for (const originalKey of options.mutation.removeOriginalKeys) {
    const thumbnailKeys = await thumbnailsByOriginal.getAllKeys(originalKey);
    for (const thumbnailKey of thumbnailKeys) {
      await thumbnailsStore.delete(thumbnailKey);
    }
  }
  for (const key of options.mutation.removeThumbnailKeys) {
    await thumbnailsStore.delete(key);
  }
  for (const thumbnail of options.mutation.upsertThumbnails) {
    await thumbnailsStore.put(thumbnail);
  }

  await metaStore.put({ key: META_SYNC_STATE, value: "idle" });
  await metaStore.delete(META_STAGED_COMMIT_HASH);
  await metaStore.put({ key: META_SYNCED_COMMIT_HASH, value: options.nextSyncedCommitHash });
  await metaStore.put({ key: META_LAST_SYNC_AT, value: new Date().toISOString() });
  await tx.done;
  logDbSyncDebug("incremental-cas-applied", {
    fromCommitHash: options.expectedSyncedCommitHash,
    toCommitHash: options.nextSyncedCommitHash,
    removeOriginalKeys: options.mutation.removeOriginalKeys.length,
    removeThumbnailKeys: options.mutation.removeThumbnailKeys.length,
    upsertOriginals: options.mutation.upsertOriginals.length,
    upsertThumbnails: options.mutation.upsertThumbnails.length,
    durationMs: nowMs() - startedAtMs,
  });
  return { outcome: "applied" };
};

// Reads timeline and thumbnail records together to avoid extra query round-trips.
export const loadCache = async (db: IDBPDatabase<ReplycantDb>): Promise<CacheLoadResult> => {
  const originals = await db.getAllFromIndex("originals", "byTakenAt");
  const thumbnails = await db.getAll("thumbnails");
  const thumbByOriginalKey = new Map<string, NormalizedThumbnail[]>();
  for (const thumbnail of thumbnails) {
    const list = thumbByOriginalKey.get(thumbnail.originalKey) ?? [];
    list.push(thumbnail);
    thumbByOriginalKey.set(thumbnail.originalKey, list);
  }
  const syncedCommitHash = await readMetaValue(db, META_SYNCED_COMMIT_HASH);
  return { originals, thumbByOriginalKey, syncedCommitHash };
};

// Loads one newest-first originals page so startup can render quickly before hydrating full history.
export const loadCachePage = async (
  db: IDBPDatabase<ReplycantDb>,
  options: CachePageOptions,
): Promise<CachePageResult> => {
  const safeLimit = Math.max(1, Math.floor(options.limit));
  const store = db.transaction("originals", "readonly").store;
  const index = store.index("byTakenAt");
  const range = options.beforeTakenAt ? IDBKeyRange.upperBound(options.beforeTakenAt, true) : undefined;
  const newestFirstRows: NormalizedOriginal[] = [];
  let cursor = await index.openCursor(range, "prev");
  while (cursor && newestFirstRows.length < safeLimit + 1) {
    newestFirstRows.push(cursor.value);
    cursor = await cursor.continue();
  }

  const hasMore = newestFirstRows.length > safeLimit;
  const pageNewestFirst = hasMore ? newestFirstRows.slice(0, safeLimit) : newestFirstRows;
  const originals = pageNewestFirst.reverse();
  const thumbByOriginalKey = new Map<string, NormalizedThumbnail[]>();
  for (const original of originals) {
    const thumbnails = await db.getAllFromIndex("thumbnails", "byOriginalKey", original.key);
    thumbByOriginalKey.set(original.key, thumbnails);
  }

  const syncedCommitHash = await readMetaValue(db, META_SYNCED_COMMIT_HASH);
  return {
    originals,
    thumbByOriginalKey,
    syncedCommitHash,
    nextBeforeTakenAt: hasMore && originals.length > 0 ? originals[0].takenAt : null,
    hasMore,
  };
};
