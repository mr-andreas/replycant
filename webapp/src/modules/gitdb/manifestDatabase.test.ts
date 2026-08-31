import "fake-indexeddb/auto";
import { openDB } from "idb";
import { beforeEach, describe, expect, it } from "vitest";
import type { RegisteredManifestRecord } from "./manifestRegistry";
import { deriveManifestStoreName, type ManifestKindRegistration } from "./manifestRegistry";
import {
  ManifestDatabase,
  type DerivedStoreDefinition,
  type DerivedStoreContext,
  type ManifestDatabaseMutation,
} from "./manifestDatabase";
import type { LfsPointerFields } from "./encryption";

const TEST_DB = "gitdb-manifest-db-test";

const originalRegistration: ManifestKindRegistration = {
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "Original",
  decode: () => null,
  primaryKey: () => "",
  indexes: [{ name: "byTakenAt", fieldPath: "manifest.takenAt" }],
};

const thumbnailRegistration: ManifestKindRegistration = {
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "ThumbnailSet",
  decode: () => null,
  primaryKey: () => "",
  indexes: [{ name: "byOriginalKey", fieldPath: "manifest.originalKey" }],
};

const makeRecord = (kind: string, key: string, manifest: unknown): RegisteredManifestRecord => ({
  apiVersion: "media.replycant.com/v1alpha1",
  kind,
  key,
  manifest,
});

interface MonthCountRow {
  monthKey: string;
  count: number;
}

// Builds a month-count aggregate by walking Original.byTakenAt keys so rebuild stays memory-bounded.
const monthCountsDerivedStore: DerivedStoreDefinition = {
  name: "timeline_month_counts",
  keyPath: "monthKey",
  rebuild: async ({ manifests, derived }: DerivedStoreContext) => {
    const counts = new Map<string, number>();
    for await (const { key } of manifests.openKeyCursor(
      { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
      { indexName: "byTakenAt" },
    )) {
      const monthKey = String(key).slice(0, 7);
      counts.set(monthKey, (counts.get(monthKey) ?? 0) + 1);
    }
    for (const [monthKey, count] of counts) {
      await derived.put({ monthKey, count });
    }
  },
  applyMutation: async ({ derived }, mutation: ManifestDatabaseMutation) => {
    const monthKeyOf = (record: RegisteredManifestRecord): string | null => {
      if (record.kind !== "Original") return null;
      const takenAt = (record.manifest as { takenAt?: string }).takenAt;
      return typeof takenAt === "string" ? takenAt.slice(0, 7) : null;
    };
    const adjust = async (monthKey: string, delta: number) => {
      const existing = (await derived.get(monthKey)) as MonthCountRow | undefined;
      const nextCount = (existing?.count ?? 0) + delta;
      if (nextCount <= 0) {
        await derived.delete(monthKey);
        return;
      }
      await derived.put({ monthKey, count: nextCount } satisfies MonthCountRow);
    };

    for (const record of mutation.removed) {
      const monthKey = monthKeyOf(record);
      if (monthKey) await adjust(monthKey, -1);
    }
    for (const record of mutation.added) {
      const monthKey = monthKeyOf(record);
      if (monthKey) await adjust(monthKey, 1);
    }
    for (const update of mutation.updated) {
      const previousMonthKey = monthKeyOf(update.previous);
      const currentMonthKey = monthKeyOf(update.current);
      if (previousMonthKey === currentMonthKey) continue;
      if (previousMonthKey) await adjust(previousMonthKey, -1);
      if (currentMonthKey) await adjust(currentMonthKey, 1);
    }
  },
};

// Cleans up the test database before each test.
const deleteDb = async () =>
  new Promise<void>((resolve, reject) => {
    const req = indexedDB.deleteDatabase(TEST_DB);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
    req.onblocked = () => resolve();
  });

describe("ManifestDatabase", () => {
  beforeEach(deleteDb);

  it("reads cache format 0 when the metadata row has no format field", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      expect(await db.readCacheFormatVersion()).toBe(0);
    } finally {
      await db.close();
    }
  });

  it("persists cache format on replaceCache and incremental apply", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
      ]);
      await db.replaceCache(records, "commit-1", { cacheFormatVersion: 0 });
      expect(await db.readCacheFormatVersion()).toBe(0);

      const result = await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [makeRecord("Original", "photo-2", { takenAt: "2026-01-02T00:00:00Z" })],
          updated: [],
          removed: [],
        },
        cacheFormatVersion: 1,
      });
      expect(result.outcome).toBe("applied");
      expect(await db.readCacheFormatVersion()).toBe(1);
    } finally {
      await db.close();
    }
  });

  it("round-trips records through replaceCache and loadCache", async () => {
    const db = new ManifestDatabase([originalRegistration, thumbnailRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
        makeRecord("Original", "photo-2", { takenAt: "2026-01-02T00:00:00Z" }),
      ]);
      records.set("media.replycant.com/v1alpha1::ThumbnailSet", [
        makeRecord("ThumbnailSet", "thumb-1", { originalKey: "photo-1" }),
      ]);

      await db.replaceCache(records, "commit-abc");

      const loaded = await db.loadCache();
      expect(loaded.syncedCommitHash).toBe("commit-abc");
      expect(await db.readCacheFormatVersion()).toBe(0);
      const originals = loaded.recordsByKind.get("media.replycant.com/v1alpha1::Original") ?? [];
      expect(originals).toHaveLength(2);
      const thumbnails = loaded.recordsByKind.get("media.replycant.com/v1alpha1::ThumbnailSet") ?? [];
      expect(thumbnails).toHaveLength(1);
    } finally {
      await db.close();
    }
  });

  it("replaceCache clears previous data", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const first = new Map<string, RegisteredManifestRecord[]>();
      first.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "old-photo", { takenAt: "2025-01-01T00:00:00Z" }),
      ]);
      await db.replaceCache(first, "commit-1");

      const second = new Map<string, RegisteredManifestRecord[]>();
      second.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "new-photo", { takenAt: "2026-01-01T00:00:00Z" }),
      ]);
      await db.replaceCache(second, "commit-2");

      const loaded = await db.loadCache();
      const originals = loaded.recordsByKind.get("media.replycant.com/v1alpha1::Original") ?? [];
      expect(originals).toHaveLength(1);
      expect(originals[0].key).toBe("new-photo");
      expect(loaded.syncedCommitHash).toBe("commit-2");
    } finally {
      await db.close();
    }
  });

  it("applies incremental mutations with CAS", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "keep", { takenAt: "2026-01-01T00:00:00Z" }),
        makeRecord("Original", "remove-me", { takenAt: "2026-01-02T00:00:00Z" }),
      ]);
      await db.replaceCache(initial, "commit-1");

      const result = await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [makeRecord("Original", "added", { takenAt: "2026-01-03T00:00:00Z" })],
          updated: [],
          removed: [makeRecord("Original", "remove-me", { takenAt: "2026-01-02T00:00:00Z" })],
        },
      });
      expect(result.outcome).toBe("applied");

      const loaded = await db.loadCache();
      expect(loaded.syncedCommitHash).toBe("commit-2");
      const originals = loaded.recordsByKind.get("media.replycant.com/v1alpha1::Original") ?? [];
      const keys = originals.map((r) => r.key).sort();
      expect(keys).toEqual(["added", "keep"]);
    } finally {
      await db.close();
    }
  });

  it("rejects incremental mutation when CAS mismatches", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", []);
      await db.replaceCache(initial, "commit-1");

      const result = await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "wrong-commit",
        nextSyncedCommitHash: "commit-2",
        mutation: { added: [], updated: [], removed: [] },
      });
      expect(result.outcome).toBe("stale");

      const loaded = await db.loadCache();
      expect(loaded.syncedCommitHash).toBe("commit-1");
    } finally {
      await db.close();
    }
  });

  it("recovers from interrupted cache update", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      try {
        await db.replaceCache(new Map(), "commit-1", { crashAfterMarkInProgress: true });
      } catch {
        // Expected crash.
      }

      const recovered = await db.recoverInterruptedCacheUpdate();
      expect(recovered).toBe(true);

      const hash = await db.readSyncedCommitHash();
      expect(hash).toBeNull();
    } finally {
      await db.close();
    }
  });

  it("queries by primary key", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
      ]);
      await db.replaceCache(records, "commit-1");

      const found = await db.query(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
        { type: "get", key: "photo-1" },
      );
      expect(found).toHaveLength(1);
      expect((found as RegisteredManifestRecord[])[0].key).toBe("photo-1");

      const notFound = await db.query(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
        { type: "get", key: "nonexistent" },
      );
      expect(notFound).toHaveLength(0);
    } finally {
      await db.close();
    }
  });

  it("queries with count", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "a", {}),
        makeRecord("Original", "b", {}),
        makeRecord("Original", "c", {}),
      ]);
      await db.replaceCache(records, "commit-1");

      const count = await db.query(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
        { type: "count" },
      );
      expect(count).toBe(3);
    } finally {
      await db.close();
    }
  });

  it("queries with count on index range", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "a", { takenAt: "2026-01-01T00:00:00Z" }),
        makeRecord("Original", "b", { takenAt: "2026-01-02T00:00:00Z" }),
        makeRecord("Original", "c", { takenAt: "2026-01-03T00:00:00Z" }),
        makeRecord("Original", "d", { takenAt: "2026-01-04T00:00:00Z" }),
      ]);
      await db.replaceCache(records, "commit-1");

      const count = await db.query(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
        {
          type: "count",
          indexName: "byTakenAt",
          range: {
            lower: "2026-01-02T00:00:00Z",
            upper: "2026-01-04T00:00:00Z",
            lowerOpen: false,
            upperOpen: true,
          },
        },
      );
      expect(count).toBe(2);
    } finally {
      await db.close();
    }
  });

  it("queries by index with equals", async () => {
    const db = new ManifestDatabase([thumbnailRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::ThumbnailSet", [
        makeRecord("ThumbnailSet", "t1", { originalKey: "photo-1" }),
        makeRecord("ThumbnailSet", "t2", { originalKey: "photo-1" }),
        makeRecord("ThumbnailSet", "t3", { originalKey: "photo-2" }),
      ]);
      await db.replaceCache(records, "commit-1");

      const found = await db.query(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "ThumbnailSet" },
        { type: "index", indexName: "byOriginalKey", equals: "photo-1" },
      );
      expect(found).toHaveLength(2);
    } finally {
      await db.close();
    }
  });

  it("queries with cursor and limit", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "a", { takenAt: "2026-01-01" }),
        makeRecord("Original", "b", { takenAt: "2026-01-02" }),
        makeRecord("Original", "c", { takenAt: "2026-01-03" }),
      ]);
      await db.replaceCache(records, "commit-1");

      const results = await db.query(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
        { type: "cursor", indexName: "byTakenAt", direction: "prev", limit: 2 },
      );
      expect(results).toHaveLength(2);
    } finally {
      await db.close();
    }
  });

  it("queries with cursor skip and limit", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "a", { takenAt: "2026-01-01" }),
        makeRecord("Original", "b", { takenAt: "2026-01-02" }),
        makeRecord("Original", "c", { takenAt: "2026-01-03" }),
        makeRecord("Original", "d", { takenAt: "2026-01-04" }),
      ]);
      await db.replaceCache(records, "commit-1");

      const results = await db.query(
        { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
        { type: "cursor", indexName: "byTakenAt", direction: "next", skip: 2, limit: 2 },
      );
      expect((results as RegisteredManifestRecord[]).map((r) => r.key)).toEqual(["c", "d"]);
    } finally {
      await db.close();
    }
  });

  it("applies incremental update to existing record", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
      ]);
      await db.replaceCache(initial, "commit-1");

      const result = await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          updated: [
            {
              previous: makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
              current: makeRecord("Original", "photo-1", { takenAt: "2026-06-15T00:00:00Z" }),
            },
          ],
          removed: [],
        },
      });
      expect(result.outcome).toBe("applied");

      const loaded = await db.loadCache();
      const originals = loaded.recordsByKind.get("media.replycant.com/v1alpha1::Original") ?? [];
      expect(originals).toHaveLength(1);
      expect((originals[0].manifest as { takenAt: string }).takenAt).toBe("2026-06-15T00:00:00Z");
    } finally {
      await db.close();
    }
  });

  it("incremental update persists only the current record from an update pair", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
      ]);
      await db.replaceCache(initial, "commit-1");

      const result = await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          updated: [
            {
              previous: makeRecord("Original", "photo-1", { takenAt: "2026-02-01T00:00:00Z" }),
              current: makeRecord("Original", "photo-1", { takenAt: "2026-03-01T00:00:00Z" }),
            },
          ],
          removed: [],
        },
      });
      expect(result.outcome).toBe("applied");

      const loaded = await db.loadCache();
      const originals = loaded.recordsByKind.get("media.replycant.com/v1alpha1::Original") ?? [];
      expect(originals).toHaveLength(1);
      expect((originals[0].manifest as { takenAt: string }).takenAt).toBe("2026-03-01T00:00:00Z");
    } finally {
      await db.close();
    }
  });

  it("incremental update preserves records not mentioned in the mutation", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
        makeRecord("Original", "photo-2", { takenAt: "2026-01-02T00:00:00Z" }),
      ]);
      await db.replaceCache(initial, "commit-1");

      const result = await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          updated: [
            {
              previous: makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
              current: makeRecord("Original", "photo-1", { takenAt: "2026-06-15T00:00:00Z" }),
            },
          ],
          removed: [],
        },
      });
      expect(result.outcome).toBe("applied");

      const loaded = await db.loadCache();
      const originals = loaded.recordsByKind.get("media.replycant.com/v1alpha1::Original") ?? [];
      expect(originals).toHaveLength(2);
      const byKey = new Map(originals.map((record) => [record.key, record]));
      expect((byKey.get("photo-1")?.manifest as { takenAt: string }).takenAt).toBe("2026-06-15T00:00:00Z");
      expect((byKey.get("photo-2")?.manifest as { takenAt: string }).takenAt).toBe("2026-01-02T00:00:00Z");
    } finally {
      await db.close();
    }
  });

  it("returns false from hasAnyRecords on empty database", async () => {
    const db = new ManifestDatabase([originalRegistration, thumbnailRegistration], TEST_DB);
    try {
      await db.initialize();
      expect(await db.hasAnyRecords()).toBe(false);
    } finally {
      await db.close();
    }
  });

  it("returns true from hasAnyRecords when records exist", async () => {
    const db = new ManifestDatabase([originalRegistration, thumbnailRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
      ]);
      await db.replaceCache(records, "commit-1");
      expect(await db.hasAnyRecords()).toBe(true);
    } finally {
      await db.close();
    }
  });

  it("rebuilds derived stores during replaceCache", async () => {
    const db = new ManifestDatabase([originalRegistration], [monthCountsDerivedStore], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "jan-1", { takenAt: "2026-01-01T00:00:00Z" }),
        makeRecord("Original", "jan-2", { takenAt: "2026-01-04T00:00:00Z" }),
        makeRecord("Original", "feb-1", { takenAt: "2026-02-01T00:00:00Z" }),
      ]);
      await db.replaceCache(records, "commit-1");

      const monthCounts = (await db.queryDerived<MonthCountRow>("timeline_month_counts", {
        type: "getAll",
      })) as MonthCountRow[];
      expect(monthCounts).toEqual([
        { monthKey: "2026-01", count: 2 },
        { monthKey: "2026-02", count: 1 },
      ]);
    } finally {
      await db.close();
    }
  });

  it("updates derived rows from incremental add/remove/update mutations", async () => {
    const db = new ManifestDatabase([originalRegistration], [monthCountsDerivedStore], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
        makeRecord("Original", "photo-2", { takenAt: "2026-01-15T00:00:00Z" }),
        makeRecord("Original", "photo-3", { takenAt: "2026-02-05T00:00:00Z" }),
      ]);
      await db.replaceCache(initial, "commit-1");

      const result = await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [makeRecord("Original", "photo-4", { takenAt: "2026-03-01T00:00:00Z" })],
          removed: [makeRecord("Original", "photo-2", { takenAt: "2026-01-15T00:00:00Z" })],
          updated: [
            {
              previous: makeRecord("Original", "photo-3", { takenAt: "2026-02-05T00:00:00Z" }),
              current: makeRecord("Original", "photo-3", { takenAt: "2026-01-20T00:00:00Z" }),
            },
          ],
        },
      });
      expect(result.outcome).toBe("applied");

      const monthCounts = (await db.queryDerived<MonthCountRow>("timeline_month_counts", {
        type: "cursor",
      })) as MonthCountRow[];
      expect(monthCounts).toEqual([
        { monthKey: "2026-01", count: 2 },
        { monthKey: "2026-03", count: 1 },
      ]);
    } finally {
      await db.close();
    }
  });

  it("rejects reads from unknown derived stores", async () => {
    const db = new ManifestDatabase([originalRegistration], [monthCountsDerivedStore], TEST_DB);
    try {
      await db.initialize();
      await expect(db.queryDerived("missing_store", { type: "count" })).rejects.toThrow(
        "Derived store is not registered: missing_store",
      );
    } finally {
      await db.close();
    }
  });

  it("schema upgrade drops old cache data until the next replaceCache", async () => {
    const originalStoreName = deriveManifestStoreName("media.replycant.com/v1alpha1", "Original");
    const oldDb = await openDB(TEST_DB, 1, {
      upgrade(database) {
        const meta = database.createObjectStore("gitdb_sync_meta", { keyPath: "key" });
        database.createObjectStore(originalStoreName, { keyPath: "key" });
        meta.put({
          key: "state",
          syncState: "idle",
          stagedCommitHash: null,
          syncedCommitHash: "legacy-commit",
          lastSyncAt: "2026-01-01T00:00:00.000Z",
        });
      },
    });
    await oldDb.put(originalStoreName, makeRecord("Original", "legacy-photo", { takenAt: "2026-01-01T00:00:00Z" }));
    await oldDb.close();

    const db = new ManifestDatabase([originalRegistration], [monthCountsDerivedStore], TEST_DB);
    try {
      await db.initialize();

      expect(await db.readSyncedCommitHash()).toBeNull();
      expect(await db.hasAnyRecords()).toBe(false);
      const monthCounts = (await db.queryDerived<MonthCountRow>("timeline_month_counts", {
        type: "getAll",
      })) as MonthCountRow[];
      expect(monthCounts).toEqual([]);
    } finally {
      await db.close();
    }
  });

  it("keeps manifest and derived rows aligned when replaceCache crashes during commit", async () => {
    const db = new ManifestDatabase([originalRegistration], [monthCountsDerivedStore], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "baseline", { takenAt: "2026-01-01T00:00:00Z" }),
      ]);
      await db.replaceCache(initial, "commit-1");

      const next = new Map<string, RegisteredManifestRecord[]>();
      next.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "newer", { takenAt: "2026-03-01T00:00:00Z" }),
      ]);

      await expect(db.replaceCache(next, "commit-2", { crashDuringCommit: true })).rejects.toThrow(
        "Simulated crash while committing cache transaction.",
      );

      await db.recoverInterruptedCacheUpdate();

      const loaded = await db.loadCache();
      const originals = loaded.recordsByKind.get("media.replycant.com/v1alpha1::Original") ?? [];
      expect(originals.map((record) => record.key)).toEqual(["baseline"]);

      const monthCounts = (await db.queryDerived<MonthCountRow>("timeline_month_counts", {
        type: "getAll",
      })) as MonthCountRow[];
      expect(monthCounts).toEqual([{ monthKey: "2026-01", count: 1 }]);
    } finally {
      await db.close();
    }
  });

  it("stores and queries LFS pointers during replaceCache", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", { takenAt: "2026-01-01T00:00:00Z" }),
      ]);
      const pointers = new Map<string, LfsPointerFields>([
        ["binary/device/media.replycant.com/v1alpha1/Original/AB/CD/EFGH", {
          oid: "sha256:abc123",
          size: 1024,
          kekEpoch: 1,
          wrappedDek: "wrapped",
          dekBase64: "decoded-dek",
        }],
      ]);
      await db.replaceCache(records, "commit-1", {}, pointers);

      const result = await db.queryPointers([
        "binary/device/media.replycant.com/v1alpha1/Original/AB/CD/EFGH",
        "binary/nonexistent",
      ]);
      expect(result.size).toBe(1);
      expect(result.get("binary/device/media.replycant.com/v1alpha1/Original/AB/CD/EFGH")?.oid).toBe("sha256:abc123");
      expect(result.get("binary/device/media.replycant.com/v1alpha1/Original/AB/CD/EFGH")?.dekBase64).toBe("decoded-dek");
    } finally {
      await db.close();
    }
  });

  it("replaceCache clears previous pointers", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", {}),
      ]);
      const pointers1 = new Map<string, LfsPointerFields>([
        ["binary/old-path", { oid: "old-oid", size: 100, kekEpoch: null, wrappedDek: null }],
      ]);
      await db.replaceCache(records, "commit-1", {}, pointers1);

      const pointers2 = new Map<string, LfsPointerFields>([
        ["binary/new-path", { oid: "new-oid", size: 200, kekEpoch: null, wrappedDek: null }],
      ]);
      await db.replaceCache(records, "commit-2", {}, pointers2);

      const result = await db.queryPointers(["binary/old-path", "binary/new-path"]);
      expect(result.has("binary/old-path")).toBe(false);
      expect(result.get("binary/new-path")?.oid).toBe("new-oid");
    } finally {
      await db.close();
    }
  });

  it("applies incremental pointer mutations alongside manifest mutations", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("Original", "photo-1", {}),
      ]);
      const pointers = new Map<string, LfsPointerFields>([
        ["binary/keep", { oid: "keep-oid", size: 100, kekEpoch: null, wrappedDek: null }],
        ["binary/remove", { oid: "remove-oid", size: 200, kekEpoch: null, wrappedDek: null }],
      ]);
      await db.replaceCache(records, "commit-1", {}, pointers);

      const result = await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: { added: [], updated: [], removed: [] },
        pointerMutation: {
          added: new Map([["binary/added", { oid: "added-oid", size: 300, kekEpoch: null, wrappedDek: null }]]),
          removed: ["binary/remove"],
        },
      });
      expect(result.outcome).toBe("applied");

      const queried = await db.queryPointers(["binary/keep", "binary/remove", "binary/added"]);
      expect(queried.get("binary/keep")?.oid).toBe("keep-oid");
      expect(queried.has("binary/remove")).toBe(false);
      expect(queried.get("binary/added")?.oid).toBe("added-oid");
    } finally {
      await db.close();
    }
  });

  it("returns empty map for queryPointers on empty database", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const result = await db.queryPointers(["binary/nonexistent"]);
      expect(result.size).toBe(0);
    } finally {
      await db.close();
    }
  });

  it("replaceCacheStreamed writes records from async iterable", async () => {
    const db = new ManifestDatabase([originalRegistration, thumbnailRegistration], TEST_DB);
    try {
      await db.initialize();
      const records = [
        makeRecord("Original", "o1", { id: "o1", takenAt: "2026-01-15" }),
        makeRecord("Original", "o2", { id: "o2", takenAt: "2026-02-10" }),
        makeRecord("ThumbnailSet", "t1", { id: "t1", originalKey: "o1" }),
      ];

      async function* generate() {
        for (const r of records) yield r;
      }

      const { totalRecords } = await db.replaceCacheStreamed(generate(), "commit-streamed");
      expect(totalRecords).toBe(3);

      const originals = await db.query({ apiVersion: "media.replycant.com/v1alpha1", kind: "Original" }, { type: "getAll" });
      expect(originals).toHaveLength(2);

      const thumbnails = await db.query({ apiVersion: "media.replycant.com/v1alpha1", kind: "ThumbnailSet" }, { type: "getAll" });
      expect(thumbnails).toHaveLength(1);

      const meta = await db.readSyncedCommitHash();
      expect(meta).toBe("commit-streamed");
      expect(await db.readCacheFormatVersion()).toBe(0);
    } finally {
      await db.close();
    }
  });

  it("replaceCacheStreamed clears previous data", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map([["media.replycant.com/v1alpha1::Original", [makeRecord("Original", "old", { id: "old", takenAt: "2025-01-01" })]]]);
      await db.replaceCache(initial, "commit-1");

      async function* generate() {
        yield makeRecord("Original", "new", { id: "new", takenAt: "2026-06-01" });
      }

      await db.replaceCacheStreamed(generate(), "commit-2");

      const all = await db.query({ apiVersion: "media.replycant.com/v1alpha1", kind: "Original" }, { type: "getAll" }) as { key: string }[];
      expect(all).toHaveLength(1);
      expect(all[0].key).toBe("new");
    } finally {
      await db.close();
    }
  });

  it("replaceCacheStreamed rebuilds derived stores", async () => {
    const db = new ManifestDatabase([originalRegistration], [monthCountsDerivedStore], TEST_DB);
    try {
      await db.initialize();
      const records = [
        makeRecord("Original", "o1", { id: "o1", takenAt: "2026-01-15" }),
        makeRecord("Original", "o2", { id: "o2", takenAt: "2026-01-20" }),
        makeRecord("Original", "o3", { id: "o3", takenAt: "2026-02-10" }),
      ];

      async function* generate() {
        for (const r of records) yield r;
      }

      await db.replaceCacheStreamed(generate(), "commit-derived");

      const allRows = (await db.queryDerived<MonthCountRow>("timeline_month_counts", { type: "getAll" })) as MonthCountRow[];
      expect(allRows).toEqual([
        { monthKey: "2026-01", count: 2 },
        { monthKey: "2026-02", count: 1 },
      ]);
    } finally {
      await db.close();
    }
  });

  it("writePointers adds pointers to an existing cache snapshot", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      async function* generate() {
        yield makeRecord("Original", "o1", { id: "o1", takenAt: "2026-01-01" });
      }
      await db.replaceCacheStreamed(generate(), "commit-ptr");

      const pointers = new Map<string, LfsPointerFields>([
        ["binary/o1.heic", { oid: "sha256:abc", size: 100 } as LfsPointerFields],
      ]);
      await db.writePointers(pointers, "commit-ptr");

      const queried = await db.queryPointers(["binary/o1.heic"]);
      expect(queried.get("binary/o1.heic")?.oid).toBe("sha256:abc");
    } finally {
      await db.close();
    }
  });

  it("writePointers skips write when commit hash does not match", async () => {
    const db = new ManifestDatabase([originalRegistration], TEST_DB);
    try {
      await db.initialize();
      async function* generate() {
        yield makeRecord("Original", "o1", { id: "o1", takenAt: "2026-01-01" });
      }
      await db.replaceCacheStreamed(generate(), "commit-a");

      const pointers = new Map<string, LfsPointerFields>([
        ["binary/o1.heic", { oid: "sha256:abc", size: 100 } as LfsPointerFields],
      ]);
      await db.writePointers(pointers, "commit-b");

      const queried = await db.queryPointers(["binary/o1.heic"]);
      expect(queried.has("binary/o1.heic")).toBe(false);
    } finally {
      await db.close();
    }
  });

  describe("replaceCacheStreamed Firefox-safe chunking", () => {
    // Captures every readwrite/readonly transaction opened against IDB so structural
    // tests can verify the chunked design rather than a single long-lived transaction.
    const installTransactionSpy = () => {
      const calls: {
        storeNames: string | string[];
        mode: IDBTransactionMode;
      }[] = [];
      const original = IDBDatabase.prototype.transaction;
      IDBDatabase.prototype.transaction = function (
        this: IDBDatabase,
        storeNames: string | Iterable<string>,
        mode?: IDBTransactionMode,
        options?: IDBTransactionOptions,
      ): IDBTransaction {
        const resolvedMode: IDBTransactionMode = mode ?? "readonly";
        const resolvedNames =
          typeof storeNames === "string" ? storeNames : Array.from(storeNames as Iterable<string>);
        calls.push({ storeNames: resolvedNames, mode: resolvedMode });
        return original.call(
          this,
          storeNames as IDBTransaction["objectStoreNames"] extends infer X
            ? X
            : string | Iterable<string>,
          mode,
          options,
        );
      } as typeof IDBDatabase.prototype.transaction;
      return {
        calls,
        restore: () => {
          IDBDatabase.prototype.transaction = original;
        },
      };
    };

    // Streams records to force multiple chunk transactions so the structural shape can
    // be inspected without needing thousands of records.
    it("opens multiple short transactions instead of one long-lived transaction", async () => {
      const CHUNK_SIZE = 2;
      const db = new ManifestDatabase([originalRegistration], [], TEST_DB, CHUNK_SIZE);
      try {
        await db.initialize();
        const records = [
          makeRecord("Original", "o1", { takenAt: "2026-01-01" }),
          makeRecord("Original", "o2", { takenAt: "2026-01-02" }),
          makeRecord("Original", "o3", { takenAt: "2026-01-03" }),
          makeRecord("Original", "o4", { takenAt: "2026-01-04" }),
          makeRecord("Original", "o5", { takenAt: "2026-01-05" }),
        ];
        async function* generate() {
          for (const r of records) yield r;
        }

        const spy = installTransactionSpy();
        try {
          await db.replaceCacheStreamed(generate(), "commit-multi");
        } finally {
          spy.restore();
        }

        const readwriteTxCount = spy.calls.filter((c) => c.mode === "readwrite").length;
        // Expected: 1 begin + ceil(5/2)=3 chunk transactions + 1 commit = 5
        expect(readwriteTxCount).toBe(5);

        // Verify state landed correctly across the chunked writes.
        const all = (await db.query(
          { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
          { type: "getAll" },
        )) as RegisteredManifestRecord[];
        expect(all.map((r) => r.key).sort()).toEqual(["o1", "o2", "o3", "o4", "o5"]);
        expect(await db.readSyncedCommitHash()).toBe("commit-multi");
      } finally {
        await db.close();
      }
    });

    // Reproduces the production failure shape from the streaming pipeline: each next()
    // resolves via a macrotask (setTimeout) rather than synchronously from a buffer,
    // which is what triggered TransactionInactiveError under Firefox's strict IDB lifecycle.
    it("handles async iterables whose next() resolves on the macrotask queue", async () => {
      const CHUNK_SIZE = 2;
      const db = new ManifestDatabase([originalRegistration], [], TEST_DB, CHUNK_SIZE);
      try {
        await db.initialize();
        const records = [
          makeRecord("Original", "a1", { takenAt: "2026-01-01" }),
          makeRecord("Original", "a2", { takenAt: "2026-01-02" }),
          makeRecord("Original", "a3", { takenAt: "2026-01-03" }),
          makeRecord("Original", "a4", { takenAt: "2026-01-04" }),
        ];
        const slowIterable: AsyncIterable<RegisteredManifestRecord> = {
          [Symbol.asyncIterator]() {
            let index = 0;
            return {
              next: async () => {
                await new Promise<void>((resolve) => setTimeout(resolve, 0));
                if (index >= records.length) return { value: undefined, done: true } as IteratorResult<RegisteredManifestRecord>;
                const value = records[index++];
                return { value, done: false };
              },
            };
          },
        };

        const { totalRecords } = await db.replaceCacheStreamed(slowIterable, "commit-slow");
        expect(totalRecords).toBe(4);
        const all = (await db.query(
          { apiVersion: "media.replycant.com/v1alpha1", kind: "Original" },
          { type: "getAll" },
        )) as RegisteredManifestRecord[];
        expect(all.map((r) => r.key).sort()).toEqual(["a1", "a2", "a3", "a4"]);
      } finally {
        await db.close();
      }
    });

    // Verifies the staged-commit recovery model: an error mid-stream must leave
    // syncedCommitHash unchanged so the previous snapshot keeps rendering, and must
    // leave a recoverable in_progress marker that the next bootstrap clears.
    it("preserves previous syncedCommitHash and stays recoverable when interrupted mid-stream", async () => {
      const CHUNK_SIZE = 2;
      const db = new ManifestDatabase([originalRegistration], [], TEST_DB, CHUNK_SIZE);
      try {
        await db.initialize();
        const initial = new Map<string, RegisteredManifestRecord[]>();
        initial.set("media.replycant.com/v1alpha1::Original", [
          makeRecord("Original", "baseline", { takenAt: "2025-01-01" }),
        ]);
        await db.replaceCache(initial, "commit-baseline");

        async function* explodingStream(): AsyncIterable<RegisteredManifestRecord> {
          yield makeRecord("Original", "n1", { takenAt: "2026-01-01" });
          yield makeRecord("Original", "n2", { takenAt: "2026-01-02" });
          throw new Error("upstream pipeline failure");
        }

        await expect(db.replaceCacheStreamed(explodingStream(), "commit-failed")).rejects.toThrow(
          "upstream pipeline failure",
        );

        expect(await db.readSyncedCommitHash()).toBe("commit-baseline");

        const recovered = await db.recoverInterruptedCacheUpdate();
        expect(recovered).toBe(true);

        expect(await db.readSyncedCommitHash()).toBe("commit-baseline");
      } finally {
        await db.close();
      }
    });

    // Derived stores must observe the fully-written snapshot, not a partial mid-stream
    // view. Concretely the rebuild belongs in the final commit transaction so it can
    // walk the complete manifest store.
    it("rebuilds derived stores over the full snapshot after all chunks land", async () => {
      const CHUNK_SIZE = 2;
      const db = new ManifestDatabase(
        [originalRegistration],
        [monthCountsDerivedStore],
        TEST_DB,
        CHUNK_SIZE,
      );
      try {
        await db.initialize();
        const records = [
          makeRecord("Original", "jan-1", { takenAt: "2026-01-05T00:00:00Z" }),
          makeRecord("Original", "jan-2", { takenAt: "2026-01-10T00:00:00Z" }),
          makeRecord("Original", "jan-3", { takenAt: "2026-01-15T00:00:00Z" }),
          makeRecord("Original", "feb-1", { takenAt: "2026-02-01T00:00:00Z" }),
          makeRecord("Original", "feb-2", { takenAt: "2026-02-20T00:00:00Z" }),
        ];
        async function* generate() {
          for (const r of records) yield r;
        }

        await db.replaceCacheStreamed(generate(), "commit-derived-chunked");

        const monthCounts = (await db.queryDerived<MonthCountRow>("timeline_month_counts", {
          type: "getAll",
        })) as MonthCountRow[];
        expect(monthCounts).toEqual([
          { monthKey: "2026-01", count: 3 },
          { monthKey: "2026-02", count: 2 },
        ]);
      } finally {
        await db.close();
      }
    });
  });
});
