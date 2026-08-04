import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it } from "vitest";
import {
  applyIncrementalCacheUpdateWithCas,
  loadCache,
  openReplycantDb,
  readSyncedCommitHash,
  recoverInterruptedCacheUpdate,
  replaceCache,
} from "./db";

// Provides one normalized original row so cache replacement tests can assert preserved content.
const makeOriginal = (key: string) => ({
  key,
  deviceSpace: "dev",
  name: key.split("/")[1] ?? key,
  id: key,
  sha256: `sha-${key}`,
  filesize: 1024,
  mediaType: "photo",
  mimeType: "image/jpeg",
  width: 100,
  height: 100,
  duration: undefined,
  takenAt: "2026-02-17T10:00:00Z",
  files: { originalPath: `/originals/${key}.jpg`, lfsHash: `sha-${key}` },
});

// Creates one thumbnail row so tests validate original-to-thumbnail grouping behavior.
const makeThumbnail = (originalKey: string, key = `thumb-${originalKey}`) => ({
  key,
  originalKey,
  width: 100,
  height: 100,
  sha256: `sha-${key}`,
});

describe("db cache replacement", () => {
  // Resets database between tests so each scenario starts from a known metadata baseline.
  beforeEach(async () => {
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.deleteDatabase("replycant");
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
      request.onblocked = () => resolve();
    });
  });

  it("stores the synchronized commit hash in metadata", async () => {
    const db = await openReplycantDb();
    await replaceCache(db, [makeOriginal("dev/a")], [makeThumbnail("dev/a")], "commit-a");
    const cached = await loadCache(db);
    expect(cached.syncedCommitHash).toBe("commit-a");
    expect(cached.originals).toHaveLength(1);
    expect(cached.thumbByOriginalKey.get("dev/a")).toHaveLength(1);
    db.close();
  });

  it("recovers safely when interrupted after in-progress marker", async () => {
    const db = await openReplycantDb();
    await replaceCache(db, [makeOriginal("dev/a")], [makeThumbnail("dev/a")], "commit-a");
    await expect(
      replaceCache(db, [makeOriginal("dev/b")], [makeThumbnail("dev/b")], "commit-b", {
        crashAfterMarkInProgress: true,
      }),
    ).rejects.toThrow("Simulated crash");
    const didRecover = await recoverInterruptedCacheUpdate(db);
    expect(didRecover).toBe(true);
    const cached = await loadCache(db);
    expect(cached.syncedCommitHash).toBe("commit-a");
    expect(cached.originals.map((item) => item.key)).toEqual(["dev/a"]);
    db.close();
  });

  it("recovers safely when interrupted during commit transaction", async () => {
    const db = await openReplycantDb();
    await replaceCache(db, [makeOriginal("dev/a")], [makeThumbnail("dev/a")], "commit-a");
    await expect(
      replaceCache(db, [makeOriginal("dev/c")], [makeThumbnail("dev/c")], "commit-c", {
        crashDuringCommit: true,
      }),
    ).rejects.toThrow("Simulated crash");
    const didRecover = await recoverInterruptedCacheUpdate(db);
    expect(didRecover).toBe(true);
    const cached = await loadCache(db);
    expect(cached.syncedCommitHash).toBe("commit-a");
    expect(cached.originals.map((item) => item.key)).toEqual(["dev/a"]);
    db.close();
  });

  it("applies incremental mutations when expected commit hash matches", async () => {
    const db = await openReplycantDb();
    await replaceCache(db, [makeOriginal("dev/a")], [makeThumbnail("dev/a")], "commit-a");
    const result = await applyIncrementalCacheUpdateWithCas(db, {
      expectedSyncedCommitHash: "commit-a",
      nextSyncedCommitHash: "commit-b",
      mutation: {
        removeOriginalKeys: ["dev/a"],
        removeThumbnailKeys: [],
        upsertOriginals: [makeOriginal("dev/b")],
        upsertThumbnails: [makeThumbnail("dev/b")],
      },
    });
    expect(result.outcome).toBe("applied");
    const cached = await loadCache(db);
    expect(cached.originals.map((item) => item.key)).toEqual(["dev/b"]);
    expect(cached.thumbByOriginalKey.get("dev/b")).toHaveLength(1);
    expect(await readSyncedCommitHash(db)).toBe("commit-b");
    db.close();
  });

  it("returns stale and preserves cache when expected commit hash mismatches", async () => {
    const db = await openReplycantDb();
    await replaceCache(db, [makeOriginal("dev/a")], [makeThumbnail("dev/a")], "commit-a");
    const result = await applyIncrementalCacheUpdateWithCas(db, {
      expectedSyncedCommitHash: "commit-z",
      nextSyncedCommitHash: "commit-b",
      mutation: {
        removeOriginalKeys: ["dev/a"],
        removeThumbnailKeys: [],
        upsertOriginals: [makeOriginal("dev/b")],
        upsertThumbnails: [makeThumbnail("dev/b")],
      },
    });
    expect(result.outcome).toBe("stale");
    const cached = await loadCache(db);
    expect(cached.originals.map((item) => item.key)).toEqual(["dev/a"]);
    expect(await readSyncedCommitHash(db)).toBe("commit-a");
    db.close();
  });
});
