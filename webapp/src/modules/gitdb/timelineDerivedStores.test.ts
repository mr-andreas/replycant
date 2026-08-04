import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it } from "vitest";
import type { RegisteredManifestRecord, ManifestKindRegistration } from "./manifestRegistry";
import { ManifestDatabase } from "./manifestDatabase";
import { timelineMonthCountsStore, type MonthCountRow } from "./timelineDerivedStores";

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
