import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it } from "vitest";
import type { RegisteredManifestRecord, ManifestKindRegistration } from "./manifestRegistry";
import { ManifestDatabase } from "./manifestDatabase";
import { mapPointsStore, timelineMonthCountsStore, type MapPointRow, type MonthCountRow } from "./timelineDerivedStores";

const TEST_DB = "gitdb-timeline-derived-test";

const originalRegistration: ManifestKindRegistration = {
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "Original",
  decode: () => null,
  primaryKey: () => "",
  indexes: [{ name: "byTakenAt", fieldPath: "manifest.spec.takenAt" }],
};

const makeRecord = (key: string, takenAt: string): RegisteredManifestRecord => ({
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "Original",
  key,
  manifest: { spec: { takenAt } },
});

const makeLocatedRecord = (
  key: string,
  takenAt: string | undefined,
  location?: { latitude: number; longitude: number } | { latitude: string; longitude: string },
): RegisteredManifestRecord => ({
  apiVersion: "media.replycant.com/v1alpha1",
  kind: "Original",
  key,
  manifest: { spec: { takenAt, location } },
});

const deleteDb = async () =>
  new Promise<void>((resolve, reject) => {
    const req = indexedDB.deleteDatabase(TEST_DB);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
    req.onblocked = () => resolve();
  });

describe("timelineMonthCountsStore", () => {
  beforeEach(deleteDb);

  it("rebuilds month counts with firstTakenAt", async () => {
    const db = new ManifestDatabase([originalRegistration], [timelineMonthCountsStore], TEST_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("jan-1", "2026-01-05T10:00:00Z"),
        makeRecord("jan-2", "2026-01-02T08:00:00Z"),
        makeRecord("feb-1", "2026-02-01T00:00:00Z"),
      ]);
      await db.replaceCache(records, "commit-1");

      const rows = (await db.queryDerived<MonthCountRow>("timeline_month_counts", { type: "getAll" })) as MonthCountRow[];
      expect(rows).toEqual([
        { monthKey: "2026-01", count: 2, firstTakenAt: "2026-01-02T08:00:00Z" },
        { monthKey: "2026-02", count: 1, firstTakenAt: "2026-02-01T00:00:00Z" },
      ]);
    } finally {
      await db.close();
    }
  });

  it("incremental add updates count and firstTakenAt", async () => {
    const db = new ManifestDatabase([originalRegistration], [timelineMonthCountsStore], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("jan-1", "2026-01-10T00:00:00Z"),
      ]);
      await db.replaceCache(initial, "commit-1");

      await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [makeRecord("jan-2", "2026-01-03T00:00:00Z")],
          removed: [],
          updated: [],
        },
      });

      const rows = (await db.queryDerived<MonthCountRow>("timeline_month_counts", { type: "getAll" })) as MonthCountRow[];
      expect(rows).toEqual([
        { monthKey: "2026-01", count: 2, firstTakenAt: "2026-01-03T00:00:00Z" },
      ]);
    } finally {
      await db.close();
    }
  });

  it("incremental remove deletes month bucket when count reaches zero", async () => {
    const db = new ManifestDatabase([originalRegistration], [timelineMonthCountsStore], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("feb-1", "2026-02-01T00:00:00Z"),
      ]);
      await db.replaceCache(initial, "commit-1");

      await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          removed: [makeRecord("feb-1", "2026-02-01T00:00:00Z")],
          updated: [],
        },
      });

      const rows = (await db.queryDerived<MonthCountRow>("timeline_month_counts", { type: "getAll" })) as MonthCountRow[];
      expect(rows).toEqual([]);
    } finally {
      await db.close();
    }
  });

  it("incremental update across months adjusts both buckets", async () => {
    const db = new ManifestDatabase([originalRegistration], [timelineMonthCountsStore], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("photo-1", "2026-01-15T00:00:00Z"),
        makeRecord("photo-2", "2026-02-05T00:00:00Z"),
      ]);
      await db.replaceCache(initial, "commit-1");

      await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          removed: [],
          updated: [
            {
              previous: makeRecord("photo-2", "2026-02-05T00:00:00Z"),
              current: makeRecord("photo-2", "2026-01-20T00:00:00Z"),
            },
          ],
        },
      });

      const rows = (await db.queryDerived<MonthCountRow>("timeline_month_counts", { type: "getAll" })) as MonthCountRow[];
      expect(rows).toEqual([
        { monthKey: "2026-01", count: 2, firstTakenAt: "2026-01-15T00:00:00Z" },
      ]);
    } finally {
      await db.close();
    }
  });

  it("re-scans firstTakenAt when the earliest item in a month is removed", async () => {
    const db = new ManifestDatabase([originalRegistration], [timelineMonthCountsStore], TEST_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeRecord("jan-early", "2026-01-02T00:00:00Z"),
        makeRecord("jan-late", "2026-01-20T00:00:00Z"),
      ]);
      await db.replaceCache(initial, "commit-1");

      await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          removed: [makeRecord("jan-early", "2026-01-02T00:00:00Z")],
          updated: [],
        },
      });

      const rows = (await db.queryDerived<MonthCountRow>("timeline_month_counts", { type: "getAll" })) as MonthCountRow[];
      expect(rows).toEqual([
        { monthKey: "2026-01", count: 1, firstTakenAt: "2026-01-20T00:00:00Z" },
      ]);
    } finally {
      await db.close();
    }
  });
});

const MAP_DB = "gitdb-map-points-test";

const deleteMapDb = async () =>
  new Promise<void>((resolve, reject) => {
    const req = indexedDB.deleteDatabase(MAP_DB);
    req.onsuccess = () => resolve();
    req.onerror = () => reject(req.error);
    req.onblocked = () => resolve();
  });

const readMapPoints = async (db: ManifestDatabase): Promise<MapPointRow[]> => {
  const rows = (await db.queryDerived<MapPointRow>("map_points", { type: "getAll" })) as MapPointRow[];
  return rows.slice().sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
};

describe("mapPointsStore", () => {
  beforeEach(deleteMapDb);

  it("keeps only originals that have a location and a capture time", async () => {
    const db = new ManifestDatabase([originalRegistration], [mapPointsStore], MAP_DB);
    try {
      await db.initialize();
      const records = new Map<string, RegisteredManifestRecord[]>();
      records.set("media.replycant.com/v1alpha1::Original", [
        makeLocatedRecord("placed", "2026-01-02T00:00:00Z", { latitude: 59.33, longitude: 18.06 }),
        makeLocatedRecord("no-place", "2026-01-03T00:00:00Z"),
        makeLocatedRecord("no-time", undefined, { latitude: 1, longitude: 2 }),
        makeLocatedRecord("bad-numbers", "2026-01-04T00:00:00Z", { latitude: "59", longitude: "18" }),
      ]);
      await db.replaceCache(records, "commit-1");

      expect(await readMapPoints(db)).toEqual([
        { key: "placed", latitude: 59.33, longitude: 18.06, takenAt: "2026-01-02T00:00:00Z" },
      ]);
    } finally {
      await db.close();
    }
  });

  it("adds a row when a geotagged photo arrives", async () => {
    const db = new ManifestDatabase([originalRegistration], [mapPointsStore], MAP_DB);
    try {
      await db.initialize();
      await db.replaceCache(new Map(), "commit-1");
      await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [makeLocatedRecord("placed", "2026-03-01T00:00:00Z", { latitude: 40.7, longitude: -74 })],
          removed: [],
          updated: [],
        },
      });
      expect(await readMapPoints(db)).toEqual([
        { key: "placed", latitude: 40.7, longitude: -74, takenAt: "2026-03-01T00:00:00Z" },
      ]);
    } finally {
      await db.close();
    }
  });

  it("removes the row when the photo is deleted", async () => {
    const db = new ManifestDatabase([originalRegistration], [mapPointsStore], MAP_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeLocatedRecord("placed", "2026-03-01T00:00:00Z", { latitude: 40.7, longitude: -74 }),
      ]);
      await db.replaceCache(initial, "commit-1");
      await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          removed: [makeLocatedRecord("placed", "2026-03-01T00:00:00Z", { latitude: 40.7, longitude: -74 })],
          updated: [],
        },
      });
      expect(await readMapPoints(db)).toEqual([]);
    } finally {
      await db.close();
    }
  });

  it("moves the row when the photo's location changes", async () => {
    const db = new ManifestDatabase([originalRegistration], [mapPointsStore], MAP_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeLocatedRecord("placed", "2026-03-01T00:00:00Z", { latitude: 40.7, longitude: -74 }),
      ]);
      await db.replaceCache(initial, "commit-1");
      await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          removed: [],
          updated: [{
            previous: makeLocatedRecord("placed", "2026-03-01T00:00:00Z", { latitude: 40.7, longitude: -74 }),
            current: makeLocatedRecord("placed", "2026-03-01T00:00:00Z", { latitude: 48.8, longitude: 2.3 }),
          }],
        },
      });
      expect(await readMapPoints(db)).toEqual([
        { key: "placed", latitude: 48.8, longitude: 2.3, takenAt: "2026-03-01T00:00:00Z" },
      ]);
    } finally {
      await db.close();
    }
  });

  it("drops the row when a location is removed and adds one when a location appears", async () => {
    const db = new ManifestDatabase([originalRegistration], [mapPointsStore], MAP_DB);
    try {
      await db.initialize();
      const initial = new Map<string, RegisteredManifestRecord[]>();
      initial.set("media.replycant.com/v1alpha1::Original", [
        makeLocatedRecord("losing", "2026-03-01T00:00:00Z", { latitude: 40.7, longitude: -74 }),
        makeLocatedRecord("gaining", "2026-04-01T00:00:00Z"),
      ]);
      await db.replaceCache(initial, "commit-1");
      await db.applyIncrementalWithCas({
        expectedSyncedCommitHash: "commit-1",
        nextSyncedCommitHash: "commit-2",
        mutation: {
          added: [],
          removed: [],
          updated: [
            {
              previous: makeLocatedRecord("losing", "2026-03-01T00:00:00Z", { latitude: 40.7, longitude: -74 }),
              current: makeLocatedRecord("losing", "2026-03-01T00:00:00Z"),
            },
            {
              previous: makeLocatedRecord("gaining", "2026-04-01T00:00:00Z"),
              current: makeLocatedRecord("gaining", "2026-04-01T00:00:00Z", { latitude: 1, longitude: 2 }),
            },
          ],
        },
      });
      expect(await readMapPoints(db)).toEqual([
        { key: "gaining", latitude: 1, longitude: 2, takenAt: "2026-04-01T00:00:00Z" },
      ]);
    } finally {
      await db.close();
    }
  });
});
