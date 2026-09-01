import { beforeEach, describe, expect, it, vi } from "vitest";
import git from "isomorphic-git";
import { computeBackoffMs, SyncEngine } from "./syncEngine";
import { SyncSnapshot, SyncEngineConfig, ManifestDatabaseChange } from "./syncTypes";
import { ManifestRegistry } from "./manifestRegistry";
import { ManifestDatabase } from "./manifestDatabase";
import { ManifestBlobReader } from "./manifestBlobReader";
import { encryptManifestYaml, importTestKek } from "./testEncryption";

const TEST_CONFIG: SyncEngineConfig = {
  gitBranch: "main",
  syncIntervalMs: 3_600_000,
  gitRemoteUrl: "http://localhost/api/git",
  fsVolumeName: "test-git-v3",
};

const lightningFsState = {
  stat: vi.fn().mockResolvedValue({}),
  mkdir: vi.fn().mockResolvedValue(undefined),
  readFile: vi.fn().mockResolvedValue(""),
};

vi.mock("@isomorphic-git/lightning-fs", () => ({
  default: class {
    promises = lightningFsState;
  },
}));

type GitApi = typeof git & Record<string, any>;
const gitMock = git as unknown as GitApi;

// Mocked ManifestDatabase that stores nothing but tracks calls.
const dbMock = {
  initialize: vi.fn().mockResolvedValue(undefined),
  close: vi.fn().mockResolvedValue(undefined),
  recoverInterruptedCacheUpdate: vi.fn().mockResolvedValue(false),
  readSyncedCommitHash: vi.fn().mockResolvedValue(null),
  readCacheFormatVersion: vi.fn().mockResolvedValue(1),
  replaceCache: vi.fn().mockResolvedValue(undefined),
  replaceCacheStreamed: vi.fn().mockImplementation(async (records: AsyncIterable<unknown>) => {
    let totalRecords = 0;
    for await (const _ of records) totalRecords += 1;
    return { totalRecords };
  }),
  writePointers: vi.fn().mockResolvedValue(undefined),
  applyIncrementalWithCas: vi.fn().mockResolvedValue({ outcome: "applied" }),
  loadCache: vi.fn().mockResolvedValue({ recordsByKind: new Map(), syncedCommitHash: null }),
  hasAnyRecords: vi.fn().mockResolvedValue(false),
  query: vi.fn().mockResolvedValue(0),
};

// Creates a minimal registry that accepts manifests matching the media protocol path pattern.
const createTestRegistry = (): ManifestRegistry => {
  const registry = new ManifestRegistry();
  registry.register({
    apiVersion: "media.replycant.com/v1alpha1",
    kind: "Original",
    decode: (rawYaml: string) => {
      const parsed = rawYaml.match(/kind:\s*Original/);
      if (!parsed) return null;
      const nameMatch = rawYaml.match(/name:\s*(\S+)/);
      const deviceSpaceMatch = rawYaml.match(/deviceSpace:\s*(\S+)/);
      const takenAtMatch = rawYaml.match(/takenAt:\s*(\S+)/);
      return {
        kind: "Original",
        metadata: { name: nameMatch?.[1] ?? "unknown", deviceSpace: deviceSpaceMatch?.[1] ?? "dev" },
        spec: { id: nameMatch?.[1] ?? "unknown", takenAt: takenAtMatch?.[1] ?? "2026-01-01T00:00:00Z" },
      };
    },
    primaryKey: (decoded: any) => `${decoded.metadata.deviceSpace}/${decoded.metadata.name}`,
  });
  registry.register({
    apiVersion: "media.replycant.com/v1alpha1",
    kind: "ThumbnailSet",
    decode: (rawYaml: string) => {
      const parsed = rawYaml.match(/kind:\s*ThumbnailSet/);
      if (!parsed) return null;
      const nameMatch = rawYaml.match(/name:\s*(\S+)/);
      const deviceSpaceMatch = rawYaml.match(/deviceSpace:\s*(\S+)/);
      return {
        kind: "ThumbnailSet",
        metadata: { name: nameMatch?.[1] ?? "unknown", deviceSpace: deviceSpaceMatch?.[1] ?? "dev" },
        spec: { thumbnails: [], originalRef: "dev/original" },
      };
    },
    primaryKey: (decoded: any) => `${decoded.metadata.deviceSpace}/${decoded.metadata.name}`,
  });
  return registry;
};

// Creates an engine wired to snapshot and manifest change collectors so tests can assert transitions.
const createEngine = (snapshots: SyncSnapshot[], manifestChanges?: ManifestDatabaseChange[], initialCloneDepth?: number) => {
  const registry = createTestRegistry();
  const config: SyncEngineConfig = {
    ...TEST_CONFIG,
    ...(initialCloneDepth != null ? { initialCloneDepth } : {}),
  };
  const engine = new SyncEngine(
    config,
    registry,
    dbMock as unknown as ManifestDatabase,
    (snapshot) => {
      snapshots.push(snapshot);
    },
  );
  if (manifestChanges) {
    engine.onManifestChange((change) => manifestChanges.push(change));
  }
  return engine;
};

// Serves the gitdb/version tree walk so tests that replace readTree for
// manifests still let the marker read prove presence instead of failing.
const withVersionTrees = (
  impl: (args: { oid: string; filepath?: string }) => Promise<{ oid: string; tree: unknown[] }>,
) => {
  return async (args: { oid: string; filepath?: string }) => {
    if (!args.filepath && args.oid === "root-tree-oid") {
      const tree: Array<{ path: string; oid: string; type: "tree"; mode: string }> = [
        { path: "gitdb", oid: "gitdb-tree-oid", type: "tree", mode: "040000" },
      ];
      try {
        const manifests = await impl({ ...args, filepath: "manifests" });
        tree.push({ path: "manifests", oid: manifests.oid, type: "tree", mode: "040000" });
      } catch {
        // A readable root without manifests is a genuine empty library.
      }
      return { oid: "root-tree-oid", tree };
    }
    if (!args.filepath && args.oid === "gitdb-tree-oid") {
      return {
        oid: "gitdb-tree-oid",
        tree: [{ path: "version", oid: "version-oid", type: "blob", mode: "100644" }],
      };
    }
    if (!args.filepath) {
      try {
        return await impl({ ...args, filepath: "manifests" });
      } catch {
        return impl(args);
      }
    }
    return impl(args);
  };
};

const notFoundVersionError = (): Error =>
  Object.assign(new Error("Could not find file or directory 'gitdb/version'"), {
    name: "NotFoundError",
    code: "NotFoundError",
  });

describe("sync backoff", () => {
  it("grows exponentially and caps", () => {
    expect(computeBackoffMs(0, 3_600_000)).toBe(3_600_000);
    expect(computeBackoffMs(1, 3_600_000)).toBe(3_600_000);
    expect(computeBackoffMs(10, 3_600_000)).toBe(3_600_000);
  });

  it("uses provided syncIntervalMs as base", () => {
    expect(computeBackoffMs(0, 10_000)).toBe(10_000);
    expect(computeBackoffMs(1, 10_000)).toBe(20_000);
    expect(computeBackoffMs(2, 10_000)).toBe(40_000);
    expect(computeBackoffMs(10, 10_000)).toBe(300_000);
  });
});

describe("SyncEngine", () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    vi.clearAllMocks();
    // Injects a fixed KEK so encrypted test fixtures decrypt without age envelopes.
    vi.spyOn(ManifestBlobReader.prototype, "loadKekEpoch").mockResolvedValue(await importTestKek());
    dbMock.recoverInterruptedCacheUpdate.mockResolvedValue(false);
    dbMock.applyIncrementalWithCas.mockResolvedValue({ outcome: "applied" });
    dbMock.loadCache.mockResolvedValue({ recordsByKind: new Map(), syncedCommitHash: null });
    dbMock.hasAnyRecords.mockResolvedValue(false);
    dbMock.readSyncedCommitHash.mockResolvedValue(null);
    dbMock.readCacheFormatVersion.mockResolvedValue(1);
    dbMock.query.mockResolvedValue(0);
    gitMock.fetch = vi.fn().mockResolvedValue(undefined);
    gitMock.resolveRef = vi.fn().mockImplementation(async ({ ref }: { ref: string }) => {
      if (ref === "refs/heads/main") return "local123";
      if (ref === "refs/remotes/origin/main") return "abc123";
      if (ref === "HEAD") return "abc123";
      throw new Error(`Unknown ref: ${ref}`);
    });
    gitMock.isDescendent = vi.fn().mockImplementation(async ({ oid, ancestor }: { oid: string; ancestor: string }) =>
      oid === "abc123" && ancestor === "local123",
    );
    gitMock.clone = vi.fn().mockResolvedValue(undefined);
    gitMock.writeRef = vi.fn().mockResolvedValue(undefined);
    gitMock.TREE = vi.fn().mockImplementation(({ ref }: { ref: string }) => ({ ref }));
    gitMock.walk = vi.fn().mockResolvedValue([]);
    gitMock.listFiles = vi.fn().mockResolvedValue([]);
    gitMock.readCommit = vi.fn().mockResolvedValue({
      oid: "abc123",
      commit: { tree: "root-tree-oid" },
      payload: "",
    });
    gitMock.readTree = vi.fn().mockImplementation(async ({ oid, filepath }: { oid: string; filepath?: string }) => {
      if (!filepath && oid === "root-tree-oid") {
        return {
          oid: "root-tree-oid",
          tree: [{ path: "gitdb", oid: "gitdb-tree-oid", type: "tree", mode: "040000" }],
        };
      }
      if (!filepath && oid === "gitdb-tree-oid") {
        return {
          oid: "gitdb-tree-oid",
          tree: [{ path: "version", oid: "version-oid", type: "blob", mode: "100644" }],
        };
      }
      throw new Error("missing manifests tree");
    });
    gitMock.readBlob = vi.fn().mockImplementation(async ({ oid, filepath }: { oid?: string; filepath?: string }) => {
      if (filepath === "gitdb/version" || oid === "version-oid") {
        return { blob: new TextEncoder().encode("1\n"), oid: "version-oid" };
      }
      return { blob: new TextEncoder().encode(""), oid: "blob-oid" };
    });
    gitMock.listServerRefs = vi.fn().mockResolvedValue([{ ref: "refs/heads/main", oid: "abc123" }]);
    gitMock.log = vi.fn().mockResolvedValue([]);
    gitMock.expandOid = vi.fn().mockImplementation(async ({ oid }: { oid: string }) => oid);
  });

  it("clones with bare gitdir and skips checkout when local repo is missing", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    lightningFsState.stat.mockRejectedValueOnce(new Error("ENOENT"));
    await engine.syncNow("manual");
    expect(gitMock.clone).toHaveBeenCalledWith(
      expect.objectContaining({ gitdir: "/repo", noCheckout: true, depth: 1 }),
    );
  });

  it("uses configured initial clone depth when local repo is missing", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots, undefined, 20);
    lightningFsState.stat.mockRejectedValueOnce(new Error("ENOENT"));
    await engine.syncNow("manual");
    expect(gitMock.clone).toHaveBeenCalledWith(
      expect.objectContaining({ gitdir: "/repo", noCheckout: true, depth: 20 }),
    );
  });

  it("fails sync when the pulled commit uses an unsupported database version", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.readBlob = vi.fn().mockImplementation(async ({ oid, filepath }: { oid?: string; filepath?: string }) => {
      if (filepath === "gitdb/version" || oid === "version-oid") {
        return { blob: new TextEncoder().encode("2\n"), oid: "version-oid" };
      }
      return { blob: new TextEncoder().encode(""), oid: "blob-oid" };
    });
    await engine.syncNow("manual");
    expect(snapshots.at(-1)?.error).toMatch(/This library uses database format 2/);
    expect(snapshots.at(-1)?.error).toMatch(/Update the app to continue/);
    expect(snapshots.at(-1)?.unrecoverableError).toMatch(/Update the app to continue/);
    expect(snapshots.at(-1)?.syncedCommitHash).toBeNull();
  });

  it("treats a database version mismatch as unrecoverable and stops polling", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.readBlob = vi.fn().mockImplementation(async ({ oid, filepath }: { oid?: string; filepath?: string }) => {
      if (filepath === "gitdb/version" || oid === "version-oid") {
        return { blob: new TextEncoder().encode("2\n"), oid: "version-oid" };
      }
      return { blob: new TextEncoder().encode(""), oid: "blob-oid" };
    });
    const setTimeoutSpy = vi.spyOn(globalThis, "setTimeout");
    await engine.syncNow("manual");
    const afterFirst = snapshots.at(-1);
    expect(afterFirst?.unrecoverableError).toMatch(/Update the app to continue/);
    expect(setTimeoutSpy).not.toHaveBeenCalled();

    vi.mocked(git.fetch).mockClear();
    await engine.syncNow("manual");
    expect(snapshots.at(-1)?.unrecoverableError).toBe(afterFirst?.unrecoverableError);
    expect(git.fetch).not.toHaveBeenCalled();

    await engine.syncNow("poll");
    expect(git.fetch).not.toHaveBeenCalled();
    engine.stop();
    setTimeoutSpy.mockRestore();
  });

  it("treats a missing gitdb/version as format 0 and syncs", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readCacheFormatVersion.mockResolvedValue(0);
    gitMock.readTree = vi.fn().mockImplementation(async ({ oid, filepath }: { oid: string; filepath?: string }) => {
      if (!filepath && oid === "root-tree-oid") {
        return { oid: "root-tree-oid", tree: [] };
      }
      throw new Error("missing manifests tree");
    });
    gitMock.readBlob = vi.fn().mockImplementation(async ({ filepath }: { filepath?: string }) => {
      if (filepath === "gitdb/version") throw notFoundVersionError();
      return { blob: new TextEncoder().encode(""), oid: "blob-oid" };
    });
    await engine.syncNow("manual");
    expect(snapshots.at(-1)?.unrecoverableError).toBeNull();
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
    engine.stop();
  });

  it("stores synchronized commit hash when sync succeeds", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    await engine.syncNow("manual");
    expect(gitMock.fetch).toHaveBeenCalled();
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
    expect(snapshots.at(-1)?.periodicSyncPaused).toBe(false);
  });

  it("bails to cached snapshot when incremental CAS apply reports stale", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash
      .mockResolvedValueOnce("old123")
      .mockResolvedValueOnce("abc123");
    dbMock.applyIncrementalWithCas.mockResolvedValue({ outcome: "stale" });
    await engine.syncNow("manual");
    expect(dbMock.applyIncrementalWithCas).toHaveBeenCalledWith(
      expect.objectContaining({ expectedSyncedCommitHash: "old123", nextSyncedCommitHash: "abc123" }),
    );
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
  });

  it("fully rehydrates when stored cache format 0 sees a version-1 marker", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    dbMock.readSyncedCommitHash.mockResolvedValue("old123");
    dbMock.readCacheFormatVersion.mockResolvedValue(0);
    dbMock.hasAnyRecords.mockResolvedValue(true);
    await engine.syncNow("manual");
    expect(dbMock.applyIncrementalWithCas).not.toHaveBeenCalled();
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
    expect(manifestChanges.some((change) => change.type === "fullReplace")).toBe(true);
  });

  it("does not short-circuit when the remote head is unchanged but cache format differs", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    dbMock.readSyncedCommitHash.mockResolvedValue("abc123");
    dbMock.readCacheFormatVersion.mockResolvedValue(0);
    dbMock.hasAnyRecords.mockResolvedValue(true);
    gitMock.listServerRefs = vi.fn().mockResolvedValue([{ ref: "refs/heads/main", oid: "abc123" }]);
    gitMock.resolveRef = vi.fn().mockImplementation(async ({ ref }: { ref: string }) => {
      if (ref === "refs/heads/main") return "abc123";
      if (ref === "refs/remotes/origin/main") return "abc123";
      if (ref === "HEAD") return "abc123";
      throw new Error(`Unknown ref: ${ref}`);
    });
    await engine.syncNow("manual");
    expect(dbMock.applyIncrementalWithCas).not.toHaveBeenCalled();
    expect(vi.mocked(git.fetch)).toHaveBeenCalled();
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
    expect(manifestChanges.some((change) => change.type === "fullReplace")).toBe(true);
  });

  it("stays incremental when cache and observed format are both 0", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    dbMock.readSyncedCommitHash.mockResolvedValue("old123");
    dbMock.readCacheFormatVersion.mockResolvedValue(0);
    dbMock.hasAnyRecords.mockResolvedValue(true);
    gitMock.readTree = vi.fn().mockImplementation(async ({ oid, filepath }: { oid: string; filepath?: string }) => {
      if (!filepath && oid === "root-tree-oid") {
        return { oid: "root-tree-oid", tree: [] };
      }
      throw new Error("missing manifests tree");
    });
    gitMock.readBlob = vi.fn().mockImplementation(async ({ filepath }: { filepath?: string }) => {
      if (filepath === "gitdb/version") throw notFoundVersionError();
      return { blob: new TextEncoder().encode(""), oid: "blob-oid" };
    });
    await engine.syncNow("manual");
    expect(dbMock.applyIncrementalWithCas).toHaveBeenCalledWith(
      expect.objectContaining({ expectedSyncedCommitHash: "old123", nextSyncedCommitHash: "abc123" }),
    );
    expect(manifestChanges.some((change) => change.type === "fullReplace")).toBe(false);
  });

  it("refuses when the observed marker is below the stored cache format", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash.mockResolvedValue("old123");
    dbMock.readCacheFormatVersion.mockResolvedValue(1);
    dbMock.hasAnyRecords.mockResolvedValue(true);
    vi.spyOn(ManifestBlobReader.prototype, "inspectDatabaseVersion").mockImplementation(async (hash) => {
      if (hash === "old123") return { version: 1, rootPaths: ["gitdb"] };
      return { version: 0, rootPaths: ["manifests"] };
    });
    await engine.syncNow("manual");
    expect(dbMock.applyIncrementalWithCas).not.toHaveBeenCalled();
    expect(snapshots.at(-1)?.unrecoverableError).toMatch(/marker was removed after this app last synced format 1/);
  });

  it("rehydrates when a pin-written cache format 1 sees a real version-1 marker", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    dbMock.readSyncedCommitHash.mockResolvedValue("old123");
    dbMock.readCacheFormatVersion.mockResolvedValue(1);
    dbMock.hasAnyRecords.mockResolvedValue(true);
    vi.spyOn(ManifestBlobReader.prototype, "inspectDatabaseVersion").mockImplementation(async (hash) => {
      if (hash === "old123") return { version: 0, rootPaths: ["manifests"] };
      return { version: 1, rootPaths: ["gitdb"] };
    });
    await engine.syncNow("manual");
    expect(snapshots.at(-1)?.unrecoverableError).toBeNull();
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
    expect(dbMock.applyIncrementalWithCas).not.toHaveBeenCalled();
    expect(manifestChanges.some((change) => change.type === "fullReplace")).toBe(true);
    engine.stop();
  });

  it("does not latch when the pre-pull marker read fails and later pull succeeds", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash.mockResolvedValue("abc123");
    dbMock.readCacheFormatVersion.mockResolvedValue(1);
    dbMock.hasAnyRecords.mockResolvedValue(true);
    gitMock.listServerRefs = vi.fn().mockResolvedValue([{ ref: "refs/heads/main", oid: "abc123" }]);
    gitMock.readCommit = vi.fn()
      .mockRejectedValueOnce(new Error("repo not fetch-ready"))
      .mockResolvedValue({
        oid: "abc123",
        commit: { tree: "root-tree-oid" },
        payload: "",
      });
    await engine.syncNow("startup");
    expect(gitMock.fetch).toHaveBeenCalled();
    expect(snapshots.at(-1)?.unrecoverableError).toBeNull();
    expect(snapshots.at(-1)?.error).toBeNull();
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
    engine.stop();
  });

  it("treats an unreadable gitdb/version as a retryable sync failure", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.readCommit = vi.fn().mockRejectedValue(new Error("pack index missing"));
    await engine.syncNow("manual");
    expect(snapshots.at(-1)?.unrecoverableError).toBeNull();
    expect(snapshots.at(-1)?.error).toMatch(/could not read gitdb\/version|pack index missing|Sync failed/);
    expect(snapshots.at(-1)?.error).not.toMatch(/marker was removed/);
    expect(snapshots.at(-1)?.error).not.toMatch(/Create a new library/);
    engine.stop();
  });

  it("emits incremental event after successful incremental apply without full manifest re-read", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    dbMock.readSyncedCommitHash.mockResolvedValue("old123");
    dbMock.hasAnyRecords.mockResolvedValue(true);
    await engine.syncNow("manual");
    expect(dbMock.applyIncrementalWithCas).toHaveBeenCalledWith(
      expect.objectContaining({ expectedSyncedCommitHash: "old123", nextSyncedCommitHash: "abc123" }),
    );
    expect(dbMock.replaceCache).not.toHaveBeenCalled();
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
    const incrementalChanges = manifestChanges.filter((c) => c.type === "incremental");
    expect(incrementalChanges.length).toBeGreaterThanOrEqual(1);
  });

  it("logs incremental transition source as full-hydration when empty cache recovery runs", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash.mockResolvedValue("old123");
    dbMock.hasAnyRecords.mockResolvedValue(false);
    const debugSpy = vi.spyOn(console, "debug").mockImplementation(() => {});

    await engine.syncNow("manual");

    const syncCompleteCall = debugSpy.mock.calls.find(
      (args) => typeof args[0] === "string" && args[0].includes("sync-complete"),
    );
    expect(syncCompleteCall).toBeDefined();
    expect(syncCompleteCall?.[1]).toEqual(expect.objectContaining({ source: "full-hydration" }));
    debugSpy.mockRestore();
  });

  it("incremental sync across multiple commits carries previous from synced commit and current from target", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    const commit1 = "commit1";
    const commit2 = "commit2";
    const commit3 = "commit3";
    const manifestPath = "manifests/dev/media.replycant.com/v1alpha1/Original/photo-1.yaml";

    dbMock.readSyncedCommitHash.mockResolvedValue(commit1);
    dbMock.hasAnyRecords.mockResolvedValue(true);
    gitMock.resolveRef = vi.fn().mockImplementation(async ({ ref }: { ref: string }) => {
      if (ref === "refs/heads/main") return commit1;
      if (ref === "refs/remotes/origin/main") return commit3;
      if (ref === "HEAD") return commit3;
      throw new Error(`Unknown ref: ${ref}`);
    });
    gitMock.isDescendent = vi.fn().mockResolvedValue(true);
    gitMock.readTree = vi.fn().mockImplementation(withVersionTrees(async ({ oid, filepath }: { oid: string; filepath?: string }) => {
      if (filepath === "manifests" && oid === commit1) {
        return {
          oid: "manifest-tree-1",
          tree: [{ path: "dev", oid: "tree-dev-1", type: "tree", mode: "040000" }],
        };
      }
      if (filepath === "manifests" && oid === commit3) {
        return {
          oid: "manifest-tree-3",
          tree: [{ path: "dev", oid: "tree-dev-3", type: "tree", mode: "040000" }],
        };
      }
      if (filepath === "manifests/dev/media.replycant.com/v1alpha1/Original" && oid === commit1) {
        return {
          oid: "kind-tree-1",
          tree: [{ path: "photo-1.yaml", oid: "blob-1", type: "blob", mode: "100644" }],
        };
      }
      if (filepath === "manifests/dev/media.replycant.com/v1alpha1/Original" && oid === commit3) {
        return {
          oid: "kind-tree-3",
          tree: [{ path: "photo-1.yaml", oid: "blob-3", type: "blob", mode: "100644" }],
        };
      }
      throw new Error("missing tree");
    }));
    const blob1 = await encryptManifestYaml(
      "apiVersion: media.replycant.com/v1alpha1\nkind: Original\nname: photo-1\ndeviceSpace: dev\ntakenAt: 2026-01-01T00:00:00Z\n",
    );
    const blob3 = await encryptManifestYaml(
      "apiVersion: media.replycant.com/v1alpha1\nkind: Original\nname: photo-1\ndeviceSpace: dev\ntakenAt: 2026-01-03T00:00:00Z\n",
    );
    gitMock.readBlob = vi.fn().mockImplementation(async ({ oid, filepath }: { oid: string; filepath: string }) => {
      if (filepath === "gitdb/version" || oid === "version-oid") {
        return { blob: new TextEncoder().encode("1\n"), oid: "version-oid" };
      }
      if (filepath === manifestPath && oid === commit1) {
        return { blob: blob1, oid: "blob-1" };
      }
      if (filepath === manifestPath && oid === commit3) {
        return { blob: blob3, oid: "blob-3" };
      }
      throw new Error("missing blob");
    });

    await engine.syncNow("manual");

    const incremental = manifestChanges.find((change) => change.type === "incremental");
    expect(incremental?.type).toBe("incremental");
    if (!incremental || incremental.type !== "incremental") {
      throw new Error("Expected incremental manifest change.");
    }
    expect(incremental.mutation.updated).toHaveLength(1);
    expect((incremental.mutation.updated[0].previous.manifest as { spec: { takenAt: string } }).spec.takenAt).toBe(
      "2026-01-01T00:00:00Z",
    );
    expect((incremental.mutation.updated[0].current.manifest as { spec: { takenAt: string } }).spec.takenAt).toBe(
      "2026-01-03T00:00:00Z",
    );
    expect(gitMock.readBlob).not.toHaveBeenCalledWith(expect.objectContaining({ oid: commit2, filepath: manifestPath }));
  });

  it("skips periodic poll sync when local head differs from tracked origin head", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.resolveRef = vi.fn().mockImplementation(async ({ ref }: { ref: string }) => {
      if (ref === "refs/heads/main") return "local-rewound";
      if (ref === "refs/remotes/origin/main") return "origin-latest";
      if (ref === "HEAD") return "local-rewound";
      throw new Error(`Unknown ref: ${ref}`);
    });
    await engine.syncNow("poll");
    expect(gitMock.fetch).not.toHaveBeenCalled();
    expect(dbMock.replaceCache).not.toHaveBeenCalled();
  });

  it("marks pull divergence as recoverable conflict state", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.isDescendent = vi.fn().mockResolvedValue(false);
    await engine.syncNow("manual");
    const latest = snapshots.at(-1);
    expect(latest?.requiresHardResetPermission).toBe(true);
    expect(latest?.error).toContain("Sync conflict detected");
  });

  it("returns cached-data true when bootstrapFromCache finds records", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    dbMock.readSyncedCommitHash.mockResolvedValue("abc123");
    dbMock.hasAnyRecords.mockResolvedValue(true);

    const result = await engine.bootstrapFromCache();

    expect(result).toEqual({ hasCachedData: true });
    expect(gitMock.fetch).not.toHaveBeenCalled();
    expect(manifestChanges[0]?.type).toBe("fullReplace");
  });

  it("returns cached-data false when bootstrapFromCache loads no records", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);

    const result = await engine.bootstrapFromCache();

    expect(result).toEqual({ hasCachedData: false });
    expect(gitMock.fetch).not.toHaveBeenCalled();
  });

  it("emits fullReplace event on bootstrap", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    await engine.bootstrapFromCache();
    expect(manifestChanges).toHaveLength(1);
    expect(manifestChanges[0].type).toBe("fullReplace");
  });

  it("reports transport failures as sync errors instead of conflict state", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.fetch = vi.fn().mockRejectedValue(new Error("socket hang up"));
    await engine.syncNow("manual");
    const latest = snapshots.at(-1);
    expect(latest?.requiresHardResetPermission).toBe(false);
    expect(latest?.error).toContain("Sync failed: socket hang up");
  });

  it("normalizes malformed git payload parser failures into actionable sync errors", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.fetch = vi
      .fn()
      .mockRejectedValue(new Error("Cannot read properties of undefined (reading 'size')"));
    await engine.syncNow("manual");
    const latest = snapshots.at(-1);
    expect(latest?.requiresHardResetPermission).toBe(false);
    expect(latest?.error).toContain("Git response payload was invalid");
  });

  it("normalizes remoteRefs parser failures into actionable sync errors", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.fetch = vi.fn().mockRejectedValue(new Error("remoteRefs is undefined"));
    await engine.syncNow("manual");
    const latest = snapshots.at(-1);
    expect(latest?.requiresHardResetPermission).toBe(false);
    expect(latest?.error).toContain("Git server did not return branch refs");
  });

  it("fails first clone preflight with explicit missing-branch guidance", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    lightningFsState.stat.mockRejectedValueOnce(new Error("ENOENT"));
    gitMock.listServerRefs = vi.fn().mockResolvedValue([]);
    await engine.syncNow("manual");
    const latest = snapshots.at(-1);
    expect(gitMock.clone).not.toHaveBeenCalled();
    expect(latest?.error).toContain("Remote branch refs/heads/main is missing");
  });

  it("translates clone preflight remoteRefs failures into proxy guidance", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    lightningFsState.stat.mockRejectedValueOnce(new Error("ENOENT"));
    gitMock.listServerRefs = vi.fn().mockRejectedValue(new Error("remoteRefs is undefined"));
    await engine.syncNow("manual");
    const latest = snapshots.at(-1);
    expect(gitMock.clone).not.toHaveBeenCalled();
    expect(latest?.error).toContain("Git proxy received a non-git response");
  });

  it("does nothing on hard reset path unless conflict permission is present", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    await engine.hardResetToRemoteAfterPermission();
    expect(gitMock.writeRef).not.toHaveBeenCalled();
    expect(snapshots).toHaveLength(0);
  });

  it("lists recent local commits for rewind options", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.log = vi.fn().mockResolvedValue([
      {
        oid: "abc123",
        commit: {
          message: "new photo commit\n\nbody",
          author: { timestamp: 1_700_000_000 },
        },
      },
    ]);
    const commits = await engine.listRecentLocalCommits(10);
    expect(gitMock.log).toHaveBeenCalledWith(expect.objectContaining({ ref: "refs/remotes/origin/main" }));
    expect(commits).toEqual([
      {
        hash: "abc123",
        message: "new photo commit",
        authoredAt: new Date(1_700_000_000 * 1000).toISOString(),
      },
    ]);
  });

  it("falls back to local branch history when tracked remote ref is missing", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.resolveRef = vi.fn().mockImplementation(async ({ ref }: { ref: string }) => {
      if (ref === "refs/remotes/origin/main") throw new Error("missing remote ref");
      if (ref === "refs/heads/main") return "local123";
      if (ref === "HEAD") return "local123";
      throw new Error(`Unknown ref: ${ref}`);
    });
    gitMock.log = vi.fn().mockResolvedValue([
      { oid: "local123", commit: { message: "local fallback", author: { timestamp: 1_700_000_050 } } },
    ]);
    const commits = await engine.listRecentLocalCommits(10);
    expect(gitMock.log).toHaveBeenCalledWith(expect.objectContaining({ ref: "refs/heads/main" }));
    expect(commits.map((item) => item.hash)).toEqual(["local123"]);
  });

  it("reads tracked remote head hash for forward detection", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    const tracked = await engine.readTrackedRemoteHeadCommitHashOrNull();
    expect(tracked).toBe("abc123");
  });

  it("reports authorized onboarding probe when remote branch head is visible", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    const probe = await engine.probeOnboardingAuthorization();
    expect(probe.status).toBe("authorized");
    if (probe.status === "authorized") {
      expect(probe.remoteHead).toBe("abc123");
    }
  });

  it("reports pending authorization onboarding probe for unauthorized responses", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.listServerRefs = vi.fn().mockRejectedValue(new Error("HTTP Error: 401 Unauthorized"));
    const probe = await engine.probeOnboardingAuthorization();
    expect(probe).toEqual({ status: "pending_authorization" });
  });

  it("reports transient onboarding probe for temporary network failures", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.listServerRefs = vi.fn().mockRejectedValue(new Error("socket hang up"));
    const probe = await engine.probeOnboardingAuthorization();
    expect(probe.status).toBe("transient_error");
  });

  it("reports fatal onboarding probe when remote branch is missing", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.listServerRefs = vi.fn().mockResolvedValue([]);
    const probe = await engine.probeOnboardingAuthorization();
    expect(probe.status).toBe("fatal_error");
    if (probe.status === "fatal_error") {
      expect(probe.message).toContain("Remote branch refs/heads/main is missing");
    }
  });

  it("surfaces actionable startup error when manifest decode fails", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.readTree = vi.fn().mockImplementation(withVersionTrees(async ({ filepath }: { filepath?: string }) => {
      if (filepath === "manifests") {
        return {
          oid: "tree-manifests-oid",
          tree: [
            { path: "devA", oid: "tree-devA-oid", type: "tree", mode: "040000" },
          ],
        };
      }
      if (filepath === "manifests/devA/media.replycant.com/v1alpha1/Original") {
        return {
          oid: "tree-kind-oid",
          tree: [
            { path: "o1.yaml", oid: "blob-oid-1", type: "blob", mode: "100644" },
          ],
        };
      }
      throw new Error("missing tree");
    }));
    gitMock.readBlob = vi.fn().mockImplementation(async ({ oid, filepath }: { oid?: string; filepath?: string }) => {
      if (filepath === "gitdb/version" || oid === "version-oid") {
        return { blob: new TextEncoder().encode("1\n"), oid: "version-oid" };
      }
      throw new Error("decode failure");
    });

    await engine.syncNow("manual");

    const latest = snapshots.at(-1);
    expect(latest?.error).toContain("No parseable manifests found");
    expect(latest?.error).toContain("decodeFailed=1");
    expect(latest?.error).toContain("firstDecodeError=decode failure");
  });

  it("clears clone progress after pull completes before reading manifests", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    lightningFsState.stat.mockRejectedValueOnce(new Error("ENOENT"));
    await engine.syncNow("manual");
    const latest = snapshots.at(-1);
    expect(latest?.cloneProgress).toBeNull();
  });

  it("reports monotonic unified progress across scan, decrypt, read, and media phases", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    const manifestYaml = [
      "apiVersion: media.replycant.com/v1alpha1",
      "kind: Original",
      "metadata:",
      "  name: photo-1",
      "  deviceSpace: devA",
      "spec:",
      "  takenAt: 2026-01-01T00:00:00Z",
    ].join("\n");
    const encryptedManifest = await encryptManifestYaml(manifestYaml);
    const pointerText = [
      "version https://git-lfs.github.com/spec/v1",
      "oid sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "size 42",
      "x-replycant-kek-epoch 1",
      "x-replycant-wrapped-dek d3JhcHBlZA==",
    ].join("\n");
    gitMock.readTree = vi.fn().mockImplementation(withVersionTrees(async ({ filepath }: { filepath?: string }) => {
      if (filepath === "manifests") {
        return {
          oid: "tree-manifests-oid",
          tree: [{ path: "devA", oid: "tree-devA-oid", type: "tree", mode: "040000" }],
        };
      }
      if (filepath === "manifests/devA/media.replycant.com/v1alpha1/Original") {
        return {
          oid: "tree-original-oid",
          tree: [{ path: "photo-1.yaml", oid: "blob-manifest-oid", type: "blob", mode: "100644" }],
        };
      }
      if (filepath === "manifests/devA/media.replycant.com/v1alpha1/ThumbnailSet") {
        return { oid: "tree-thumbnailset-oid", tree: [] };
      }
      if (filepath === "binary/devA/media.replycant.com/v1alpha1/Original") {
        return {
          oid: "tree-pointer-oid",
          tree: [{ path: "photo-1.jpg", oid: "blob-pointer-oid", type: "blob", mode: "100644" }],
        };
      }
      if (filepath === "binary/devA/media.replycant.com/v1alpha1/ThumbnailSet") {
        return { oid: "tree-pointer-thumbs-oid", tree: [] };
      }
      throw new Error("missing tree");
    }));
    // Skips DEK unwrap so progress coverage does not need a real wrapped DEK.
    vi.spyOn(ManifestBlobReader.prototype, "unwrapDeksForPointers").mockResolvedValue(undefined);
    gitMock.readBlob = vi.fn().mockImplementation(async ({ oid, filepath }: { oid: string; filepath?: string }) => {
      if (filepath === "gitdb/version" || oid === "version-oid") {
        return { blob: new TextEncoder().encode("1\n"), oid: "version-oid" };
      }
      if (oid === "blob-manifest-oid") {
        return { blob: encryptedManifest, oid };
      }
      if (oid === "blob-pointer-oid") {
        return { blob: new TextEncoder().encode(pointerText), oid };
      }
      return { blob: new TextEncoder().encode(""), oid };
    });

    await engine.syncNow("manual");

    const progressEvents = snapshots
      .map((snapshot) => snapshot.cloneProgress)
      .filter((progress): progress is NonNullable<SyncSnapshot["cloneProgress"]> => progress !== null);
    expect(progressEvents.length).toBeGreaterThan(0);
    const phaseSet = new Set(progressEvents.map((progress) => progress.phase));
    expect(phaseSet.has("Scanning repository")).toBe(true);
    expect(phaseSet.has("Preparing decryption")).toBe(true);
    expect(phaseSet.has("Reading manifests")).toBe(true);
    expect(phaseSet.has("Processing media")).toBe(true);
    for (let index = 1; index < progressEvents.length; index += 1) {
      expect(progressEvents[index].progress).toBeGreaterThanOrEqual(progressEvents[index - 1].progress);
    }
    expect(progressEvents.at(-1)?.progress).toBeGreaterThan(0.6);
    expect(snapshots.at(-1)?.cloneProgress).toBeNull();
  });

  it("allocates separate progress weight to receiving and resolving phases", () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    const resetProgressPhases = (engine as any).resetProgressPhases.bind(engine) as () => void;
    const emitGitTransportProgress = (engine as any).emitGitTransportProgress.bind(engine) as (
      phaseLabel: string | undefined,
      loaded: number | undefined,
      total: number | undefined,
    ) => void;

    resetProgressPhases();
    emitGitTransportProgress("Connecting to server", 0, 1);
    emitGitTransportProgress("Receiving objects", 2, 4);
    const afterReceivingProgress = snapshots.at(-1)?.cloneProgress?.progress ?? 0;
    emitGitTransportProgress("Resolving deltas", 1, 4);
    const afterResolvingProgress = snapshots.at(-1)?.cloneProgress?.progress ?? 0;

    expect(afterResolvingProgress).toBeGreaterThan(afterReceivingProgress);
  });

  it("blocks rewind when the target commit uses an unsupported database version", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash.mockResolvedValue("abc123");
    gitMock.readBlob = vi.fn().mockImplementation(async ({ oid, filepath }: { oid?: string; filepath?: string }) => {
      if (filepath === "gitdb/version" || oid === "version-oid") {
        return { blob: new TextEncoder().encode("2\n"), oid: "version-oid" };
      }
      return { blob: new TextEncoder().encode(""), oid: "blob-oid" };
    });
    await engine.rewindToCommitAndPausePolling("rewind123");
    expect(gitMock.writeRef).not.toHaveBeenCalled();
    const latest = snapshots.at(-1);
    expect(latest?.error).toContain("cannot rewind past a database format change");
    expect(latest?.syncedCommitHash).toBeNull();
  });

  it("rewinds to a selected commit and pauses periodic sync", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    await engine.rewindToCommitAndPausePolling("rewind123");
    const latest = snapshots.at(-1);
    expect(gitMock.expandOid).toHaveBeenCalledWith(expect.objectContaining({ oid: "rewind123" }));
    expect(gitMock.writeRef).toHaveBeenCalledWith(
      expect.objectContaining({ ref: "refs/heads/main", value: "rewind123", force: true }),
    );
    expect(latest?.periodicSyncPaused).toBe(true);
    expect(latest?.syncedCommitHash).toBe("rewind123");
  });

  // Pins the "single shared isomorphic-git cache" invariant: every git.*
  // helper that accepts a cache must receive the SAME object reference for
  // the engine's lifetime. Otherwise pack-index parses are duplicated and the
  // Firefox+LightningFS rewind/blob-read performance regression returns.
  it("threads the same cache reference across expandOid, readTree, and readBlob calls", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.readTree = vi.fn().mockImplementation(withVersionTrees(async () => ({ oid: "tree-oid", tree: [] })));
    await engine.syncNow("manual");
    await engine.rewindToCommitAndPausePolling("rewind123");

    const collectCaches = (mockFn: unknown): unknown[] => {
      const calls = (
        mockFn as { mock?: { calls: Array<Array<{ cache?: unknown }>> } }
      )?.mock?.calls ?? [];
      return calls.map((args) => args[0]?.cache);
    };

    const allCaches = [
      ...collectCaches(gitMock.expandOid),
      ...collectCaches(gitMock.readTree),
      ...collectCaches(gitMock.readBlob),
      ...collectCaches(gitMock.fetch),
      ...collectCaches(gitMock.isDescendent),
      ...collectCaches(gitMock.log),
    ].filter((entry) => entry !== undefined);

    expect(allCaches.length).toBeGreaterThan(0);
    const first = allCaches[0];
    expect(typeof first).toBe("object");
    for (const entry of allCaches) {
      expect(entry).toBe(first);
    }
  });

  // Guards the safety property that motivated the validation: if the target
  // OID is missing from the local object store, the branch ref must NOT be
  // overwritten. Otherwise a typo'd rewind hash would corrupt refs/heads/main
  // and force the user through the hard-reset recovery flow.
  it("does not write any refs when rewind target commit is missing locally", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    gitMock.expandOid = vi.fn().mockRejectedValue(new Error("Could not find object"));
    await engine.rewindToCommitAndPausePolling("missing456");
    expect(gitMock.writeRef).not.toHaveBeenCalled();
    const latest = snapshots.at(-1);
    expect(latest?.error).toContain("Rewind failed");
    expect(latest?.error).toContain("missing456");
  });

  it("uses incremental CAS apply when rewinding between known synced commits", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash.mockResolvedValue("old123");
    await engine.rewindToCommitAndPausePolling("rewind123");
    expect(dbMock.applyIncrementalWithCas).toHaveBeenCalledWith(
      expect.objectContaining({ expectedSyncedCommitHash: "old123", nextSyncedCommitHash: "rewind123" }),
    );
    expect(dbMock.replaceCache).not.toHaveBeenCalled();
    expect(snapshots.at(-1)?.periodicSyncPaused).toBe(true);
  });

  it("lets callers pause and resume periodic sync without rewinding", () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);

    engine.setUserPeriodicSyncPaused(true);
    expect(snapshots.at(-1)?.periodicSyncPaused).toBe(true);
    expect(snapshots.at(-1)?.periodicSyncUserEnabled).toBe(false);

    engine.setUserPeriodicSyncPaused(false);
    expect(snapshots.at(-1)?.periodicSyncPaused).toBe(false);
    expect(snapshots.at(-1)?.periodicSyncUserEnabled).toBe(true);
  });

  it("keeps periodic polling paused after forward when user disabled auto sync", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);

    engine.setUserPeriodicSyncPaused(true);
    await engine.rewindToCommitAndPausePolling("rewind123");
    await engine.forwardToRemoteHeadAndResumePolling();

    const latest = snapshots.at(-1);
    expect(latest?.periodicSyncUserEnabled).toBe(false);
    expect(latest?.periodicSyncPaused).toBe(true);
  });

  it("publishes sync interval updates in snapshots", () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);

    engine.setSyncIntervalMs(5_000);
    expect(snapshots.at(-1)?.syncIntervalMs).toBe(5_000);
  });

  it("resumes polling and reports forward failure if ref update fails", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    await engine.rewindToCommitAndPausePolling("rewind123");
    gitMock.writeRef = vi.fn().mockRejectedValue(new Error("ref update broken"));
    await engine.forwardToRemoteHeadAndResumePolling();
    const latest = snapshots.at(-1);
    expect(latest?.periodicSyncPaused).toBe(false);
    expect(latest?.error).toContain("Forward failed: ref update broken");
  });

  it("forwards to remote head and resumes periodic sync", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    await engine.rewindToCommitAndPausePolling("rewind123");
    await engine.forwardToRemoteHeadAndResumePolling();
    const latest = snapshots.at(-1);
    expect(latest?.periodicSyncPaused).toBe(false);
    expect(latest?.syncedCommitHash).toBe("abc123");
  });

  it("treats forward as no-op when tracked head already matches synced cache commit", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash.mockResolvedValue("abc123");
    await engine.forwardToRemoteHeadAndResumePolling();
    expect(dbMock.applyIncrementalWithCas).not.toHaveBeenCalled();
    expect(gitMock.readBlob).not.toHaveBeenCalled();
    expect(snapshots.at(-1)?.periodicSyncPaused).toBe(false);
    expect(snapshots.at(-1)?.syncedCommitHash).toBe("abc123");
  });

  it("prints full rehydration benchmark summary on full hydration via syncNow", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    const logSpy = vi.spyOn(console, "log");
    await engine.syncNow("manual");
    const benchmarkCall = logSpy.mock.calls.find(
      (args) => typeof args[0] === "string" && args[0].includes("Full Rehydration Benchmark"),
    );
    expect(benchmarkCall).toBeDefined();
    const output = benchmarkCall![0] as string;
    expect(output).toContain("Tree walk:");
    expect(output).toContain("KEK refresh:");
    expect(output).toContain("Blob read/decode:");
    expect(output).toContain("Replace cache:");
    expect(output).toContain("Total:");
    expect(output).toContain("Pull/fetch:");
    logSpy.mockRestore();
  });

  it("prints full rehydration benchmark from hydrateFromCommitAndApplyFullReplace recovery path", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash.mockResolvedValue("abc123");
    dbMock.hasAnyRecords.mockResolvedValue(false);
    gitMock.listServerRefs = vi.fn().mockResolvedValue([{ ref: "refs/heads/main", oid: "abc123" }]);
    const logSpy = vi.spyOn(console, "log");
    await engine.syncNow("manual");
    const benchmarkCall = logSpy.mock.calls.find(
      (args) => typeof args[0] === "string" && args[0].includes("Full Rehydration Benchmark"),
    );
    expect(benchmarkCall).toBeDefined();
    const output = benchmarkCall![0] as string;
    expect(output).toContain("Tree walk:");
    expect(output).not.toContain("Pull/fetch:");
    logSpy.mockRestore();
  });

  it("clears clone progress and reset permission after empty-cache hydration recovery", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash.mockResolvedValue("abc123");
    dbMock.hasAnyRecords.mockResolvedValue(false);
    gitMock.listServerRefs = vi.fn().mockResolvedValue([{ ref: "refs/heads/main", oid: "abc123" }]);

    await engine.syncNow("manual");

    const latest = snapshots.at(-1);
    expect(latest?.cloneProgress).toBeNull();
    expect(latest?.requiresHardResetPermission).toBe(false);
  });

  it("pauses polling immediately when rewind is requested during active sync", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    let fetchStarted = false;
    let releaseFetch = (): void => {};
    gitMock.fetch = vi.fn().mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          fetchStarted = true;
          releaseFetch = () => resolve();
        }),
    );
    const syncPromise = engine.syncNow("manual");
    for (let attempt = 0; attempt < 50 && !fetchStarted; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 2));
    }
    await engine.rewindToCommitAndPausePolling("rewind123");
    const latest = snapshots.at(-1);
    expect(latest?.periodicSyncPaused).toBe(true);
    expect(latest?.error).toContain("Rewind will run as soon as the current sync finishes");
    releaseFetch();
    await syncPromise;
    expect(gitMock.writeRef).toHaveBeenCalledWith(
      expect.objectContaining({ ref: "refs/heads/main", value: "rewind123", force: true }),
    );
  });

  it("incremental sync falls back to full hydration when a manifest blob fails to decrypt", async () => {
    const snapshots: SyncSnapshot[] = [];
    const manifestChanges: ManifestDatabaseChange[] = [];
    const engine = createEngine(snapshots, manifestChanges);
    const previousCommit = "prev-commit";
    const nextCommit = "next-commit";
    const manifestPath = "manifests/dev/media.replycant.com/v1alpha1/Original/photo-1.yaml";

    dbMock.readSyncedCommitHash.mockResolvedValue(previousCommit);
    dbMock.hasAnyRecords.mockResolvedValue(true);
    gitMock.resolveRef = vi.fn().mockImplementation(async ({ ref }: { ref: string }) => {
      if (ref === "refs/heads/main") return previousCommit;
      if (ref === "refs/remotes/origin/main") return nextCommit;
      if (ref === "HEAD") return nextCommit;
      throw new Error(`Unknown ref: ${ref}`);
    });
    gitMock.isDescendent = vi.fn().mockResolvedValue(true);
    gitMock.readTree = vi.fn().mockImplementation(withVersionTrees(async ({ oid, filepath }: { oid: string; filepath?: string }) => {
      if (filepath === "manifests" && oid === previousCommit) {
        return { oid: "tree-old", tree: [{ path: "dev", oid: "tree-dev-old", type: "tree", mode: "040000" }] };
      }
      if (filepath === "manifests" && oid === nextCommit) {
        return { oid: "tree-new", tree: [{ path: "dev", oid: "tree-dev-new", type: "tree", mode: "040000" }] };
      }
      if (filepath === "manifests/dev/media.replycant.com/v1alpha1/Original" && oid === previousCommit) {
        return { oid: "kind-tree-old", tree: [{ path: "photo-1.yaml", oid: "blob-old", type: "blob", mode: "100644" }] };
      }
      if (filepath === "manifests/dev/media.replycant.com/v1alpha1/Original" && oid === nextCommit) {
        return { oid: "kind-tree-new", tree: [{ path: "photo-1.yaml", oid: "blob-new", type: "blob", mode: "100644" }] };
      }
      throw new Error("missing tree");
    }));
    // Old commit is a valid envelope; new commit is corrupt so incremental decrypt fails.
    const oldBlob = await encryptManifestYaml(
      "apiVersion: media.replycant.com/v1alpha1\nkind: Original\nname: photo-1\ndeviceSpace: dev\ntakenAt: 2026-01-01T00:00:00Z\n",
    );
    const corruptEncryptedBlob = new TextEncoder().encode("REPLYCANT-ENC-V1\nkek-epoch:999\n---\ncorrupt-ciphertext");
    gitMock.readBlob = vi.fn().mockImplementation(async ({ oid, filepath }: { oid: string; filepath: string }) => {
      if (filepath === "gitdb/version" || oid === "version-oid") {
        return { blob: new TextEncoder().encode("1\n"), oid: "version-oid" };
      }
      if (filepath === manifestPath && oid === previousCommit) {
        return { blob: oldBlob, oid: "blob-old" };
      }
      if (filepath === manifestPath && oid === nextCommit) {
        return { blob: corruptEncryptedBlob, oid: "blob-new" };
      }
      throw new Error("missing blob");
    });

    await engine.syncNow("manual");

    // Decrypt failure in incremental path should prevent CAS apply and trigger full hydration fallback.
    // applyIncrementalWithCas should NOT be called because the mutation plan build failed.
    expect(dbMock.applyIncrementalWithCas).not.toHaveBeenCalled();
  });

  it("rewind stale CAS refreshes snapshot from database without crashing", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash
      .mockResolvedValueOnce("some-other-commit")
      .mockResolvedValueOnce("winner-commit");
    dbMock.applyIncrementalWithCas.mockResolvedValue({ outcome: "stale" });
    await engine.rewindToCommitAndPausePolling("rewind123");
    const latest = snapshots.at(-1);
    expect(latest?.syncedCommitHash).toBe("winner-commit");
    expect(latest?.syncing).toBe(false);
  });

  it("forward stale CAS refreshes snapshot from database without crashing", async () => {
    const snapshots: SyncSnapshot[] = [];
    const engine = createEngine(snapshots);
    dbMock.readSyncedCommitHash
      .mockResolvedValueOnce("some-other-commit")
      .mockResolvedValueOnce("some-other-commit")
      .mockResolvedValueOnce("winner-commit");
    dbMock.applyIncrementalWithCas.mockResolvedValue({ outcome: "stale" });
    await engine.forwardToRemoteHeadAndResumePolling();
    const latest = snapshots.at(-1);
    expect(latest?.syncedCommitHash).toBe("winner-commit");
    expect(latest?.syncing).toBe(false);
  });
});
