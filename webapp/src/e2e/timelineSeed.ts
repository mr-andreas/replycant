import type { Page } from "@playwright/test";
import { deriveBinaryPointerPath } from "../modules/gitdb/paths";
import { TEST_DEK_BASE64 } from "../modules/gitdb/testEncryption";

const DB_NAME = "gitdb-manifests-v1";
const ORIGINAL_STORE = "manifests_media_replycant_com_v1alpha1_Original";
const THUMBNAIL_STORE = "manifests_media_replycant_com_v1alpha1_ThumbnailSet";
const MONTH_STORE = "timeline_month_counts";
const POINTER_STORE = "lfs_pointers";
const API_VERSION = "media.replycant.com/v1alpha1";
const DEVICE_SPACE = "e2e-device";
const THUMB_SHA = "0000000000000000000000000000000000000000000000000000000000000001";

type MonthBucket = {
  monthKey: string;
  count: number;
  firstTakenAt: string;
};

type PointerRecord = {
  oid: string;
  size: number;
  kekEpoch: number;
  wrappedDek: string;
  dekBase64: string;
};

type SeedPayload = {
  originals: unknown[];
  thumbnails: unknown[];
  months: MonthBucket[];
  pointers: Array<[string, PointerRecord]>;
};

type TimelineSeedOptions = {
  uniqueThumbnailSha?: boolean;
  // Days between consecutive items so sparse seeds can still fill many months.
  dayStride?: number;
  // When set, build successive months with varied per-month counts instead of a flat stride.
  monthCount?: number;
  itemsPerMonth?: { min: number; max: number };
};

export type TimelineSeedResult = {
  itemCount: number;
  firstKey: string;
  lastKey: string;
  firstTakenAt: string;
  lastTakenAt: string;
};

const isoAtDayOffset = (offset: number): string => {
  const baseUtc = Date.UTC(2024, 0, 1, 12, 0, 0);
  return new Date(baseUtc + offset * 24 * 60 * 60 * 1000).toISOString();
};

// Deterministic 0..n-1 jitter so README month counts look natural but stay stable across runs.
const stableUnitJitter = (seed: number): number => {
  const x = Math.sin(seed * 12.9898 + 78.233) * 43758.5453;
  return x - Math.floor(x);
};

// Builds takenAt timestamps for seeds: either flat dayStride or varied per-month density.
const buildTakenAtSchedule = (itemCount: number, options: TimelineSeedOptions): string[] => {
  if (options.monthCount && options.monthCount > 0) {
    const monthCount = Math.floor(options.monthCount);
    const min = Math.max(1, Math.floor(options.itemsPerMonth?.min ?? 18));
    const max = Math.max(min, Math.floor(options.itemsPerMonth?.max ?? 48));
    const span = max - min + 1;
    const schedule: string[] = [];
    for (let monthIndex = 0; monthIndex < monthCount; monthIndex += 1) {
      const count = min + Math.floor(stableUnitJitter(monthIndex + 1) * span);
      const year = 2024 + Math.floor(monthIndex / 12);
      const month = monthIndex % 12;
      for (let item = 0; item < count; item += 1) {
        // Spread within the month; keep day in 1..28 so every month is valid.
        const day = 1 + Math.floor((item * 27) / Math.max(1, count));
        const hour = 8 + (item % 12);
        schedule.push(new Date(Date.UTC(year, month, day, hour, (item * 7) % 60, 0)).toISOString());
      }
    }
    return schedule;
  }

  const dayStride = Math.max(1, Math.floor(options.dayStride ?? 1));
  return Array.from({ length: itemCount }, (_, index) => isoAtDayOffset(index * dayStride));
};

// Builds deterministic manifest and pointer rows so timeline e2e can load encrypted media.
const buildSeedPayload = (itemCount: number, options: TimelineSeedOptions = {}): SeedPayload => {
  const schedule = buildTakenAtSchedule(itemCount, options);
  const monthMap = new Map<string, MonthBucket>();
  const originals: unknown[] = [];
  const thumbnails: unknown[] = [];
  const pointers: Array<[string, PointerRecord]> = [];

  for (let i = 0; i < schedule.length; i += 1) {
    const name = `orig-${String(i).padStart(4, "0")}`;
    const key = `${DEVICE_SPACE}/${name}`;
    const takenAt = schedule[i]!;
    const monthKey = takenAt.slice(0, 7);
    const sha = `${String(i).padStart(64, "0")}`.slice(-64);
    const thumbnailSha = options.uniqueThumbnailSha ? sha : THUMB_SHA;
    const originalRef = `${DEVICE_SPACE}/${API_VERSION}/Original/${name}`;
    const thumbName = `thumb-${name}.jpg`;

    const existing = monthMap.get(monthKey);
    if (existing) {
      existing.count += 1;
      if (takenAt < existing.firstTakenAt) existing.firstTakenAt = takenAt;
    } else {
      monthMap.set(monthKey, { monthKey, count: 1, firstTakenAt: takenAt });
    }

    originals.push({
      apiVersion: API_VERSION,
      kind: "Original",
      key,
      manifest: {
        apiVersion: API_VERSION,
        kind: "Original",
        metadata: {
          name,
          deviceSpace: DEVICE_SPACE,
        },
        spec: {
          id: `id-${name}`,
          sha256: sha,
          path: `/camera/${name}.jpg`,
          filesize: 1024,
          mediaType: "image",
          width: 1200,
          height: 800,
          isFavorite: false,
          isHidden: false,
          createdAt: takenAt,
          takenAt,
          mimeType: "image/jpeg",
        },
        status: {},
      },
    });

    thumbnails.push({
      apiVersion: API_VERSION,
      kind: "ThumbnailSet",
      key: `${DEVICE_SPACE}/thumbs-${name}`,
      manifest: {
        apiVersion: API_VERSION,
        kind: "ThumbnailSet",
        metadata: {
          name: `thumbs-${name}`,
          deviceSpace: DEVICE_SPACE,
        },
        spec: {
          originalRef,
          thumbnails: [
            {
              name: thumbName,
              sha256: thumbnailSha,
              width: 280,
              height: 280,
              filesize: 512,
            },
          ],
        },
        status: {},
      },
    });

    // Unique oid when uniqueThumbnailSha so preload churn exercises distinct LFS URLs.
    pointers.push([
      deriveBinaryPointerPath(DEVICE_SPACE, API_VERSION, "ThumbnailSet", thumbName),
      {
        oid: thumbnailSha,
        size: 512,
        kekEpoch: 1,
        wrappedDek: "e2e-wrapped-dek",
        dekBase64: TEST_DEK_BASE64,
      },
    ]);
  }

  const months = Array.from(monthMap.values()).sort((a, b) => a.monthKey.localeCompare(b.monthKey));
  return { originals, thumbnails, months, pointers };
};

// Exported for unit tests that verify README month-density schedules stay varied.
export const previewTakenAtSchedule = (
  itemCount: number,
  options: TimelineSeedOptions = {},
): string[] => buildTakenAtSchedule(itemCount, options);

// Seeds IndexedDB directly so timeline e2e tests can bypass expensive git sync setup.
export const seedTimelineIndexedDb = async (
  page: Page,
  itemCount = 1000,
  options: TimelineSeedOptions = {},
): Promise<TimelineSeedResult> => {
  const schedule = buildTakenAtSchedule(itemCount, options);
  const payload = buildSeedPayload(itemCount, options);
  const resolvedCount = schedule.length;
  const firstKey = `${DEVICE_SPACE}/orig-0000`;
  const lastKey = `${DEVICE_SPACE}/orig-${String(Math.max(0, resolvedCount - 1)).padStart(4, "0")}`;
  const firstTakenAt = schedule[0] ?? isoAtDayOffset(0);
  const lastTakenAt = schedule[resolvedCount - 1] ?? firstTakenAt;

  await page.evaluate(
    async ({ dbName, originalStore, thumbnailStore, monthStore, pointerStore, payload: seed }) => {
      await new Promise<void>((resolve, reject) => {
        const request = indexedDB.open(dbName);
        request.onerror = () => reject(request.error ?? new Error("failed to open indexeddb"));
        request.onsuccess = () => {
          const db = request.result;
          if (
            !db.objectStoreNames.contains(originalStore)
            || !db.objectStoreNames.contains(thumbnailStore)
            || !db.objectStoreNames.contains(monthStore)
            || !db.objectStoreNames.contains(pointerStore)
          ) {
            db.close();
            reject(new Error("required timeline stores are not present"));
            return;
          }
          const tx = db.transaction(
            [originalStore, thumbnailStore, monthStore, pointerStore],
            "readwrite",
          );
          tx.onerror = () => reject(tx.error ?? new Error("seed transaction failed"));
          tx.onabort = () => reject(tx.error ?? new Error("seed transaction aborted"));
          tx.oncomplete = () => {
            db.close();
            resolve();
          };
          const originalObjectStore = tx.objectStore(originalStore);
          const thumbnailObjectStore = tx.objectStore(thumbnailStore);
          const monthObjectStore = tx.objectStore(monthStore);
          const pointerObjectStore = tx.objectStore(pointerStore);
          originalObjectStore.clear();
          thumbnailObjectStore.clear();
          monthObjectStore.clear();
          pointerObjectStore.clear();
          for (const record of seed.originals) originalObjectStore.put(record);
          for (const record of seed.thumbnails) thumbnailObjectStore.put(record);
          for (const row of seed.months) monthObjectStore.put(row);
          for (const [path, pointer] of seed.pointers) pointerObjectStore.put(pointer, path);
        };
      });
    },
    {
      dbName: DB_NAME,
      originalStore: ORIGINAL_STORE,
      thumbnailStore: THUMBNAIL_STORE,
      monthStore: MONTH_STORE,
      pointerStore: POINTER_STORE,
      payload,
    },
  );

  return {
    itemCount: resolvedCount,
    firstKey,
    lastKey,
    firstTakenAt,
    lastTakenAt,
  };
};
