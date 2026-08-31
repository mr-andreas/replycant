import git from "isomorphic-git";
import type { FsClient } from "./fsClient";

export type DeviceSpaceDiscovery =
  | { status: "ok"; deviceSpaces: string[] }
  | { status: "unreadable"; cause: unknown };

export type ManifestTreeEntry = {
  path: string;
  oid: string;
  type: "blob" | "tree" | "commit";
  mode: string;
};

// Carries blob identity for each changed path so callers can avoid re-walking
// commit trees to rediscover old/new blobs.
export type ChangedPath = {
  path: string;
  oldOid: string | null;
  newOid: string | null;
};

export const COMMIT_TRANSITION_CACHE_MAX_ENTRIES = 128;

const nowMs = (): number => Date.now();

export function buildCommitTransitionCacheKey(
  oldCommitHash: string,
  newCommitHash: string,
): string {
  return `${oldCommitHash}:${newCommitHash}`;
}

export function promoteCommitTransitionCacheEntry<T>(
  cache: Map<string, T>,
  key: string,
  value: T,
): void {
  cache.delete(key);
  cache.set(key, value);
}

export function cacheCommitTransitionValue<T>(
  cache: Map<string, T>,
  key: string,
  value: T,
): void {
  cache.set(key, value);
  if (cache.size <= COMMIT_TRANSITION_CACHE_MAX_ENTRIES) return;
  const oldestKey = cache.keys().next().value;
  if (typeof oldestKey === "string") {
    cache.delete(oldestKey);
  }
}

// Encapsulates tree-walking and path-diffing operations so SyncEngine only
// interacts with high-level "which paths changed" queries.
export class TreeDiffer {
  private readonly fs: FsClient;
  private readonly gitdir: string;
  private readonly registeredKindDirectories: () => string[];
  private readonly log: (event: string, fields: Record<string, unknown>) => void;
  private readonly changedManifestPathsCache = new Map<string, ChangedPath[]>();
  private readonly changedBinaryPathsCache = new Map<string, ChangedPath[]>();
  // Shared isomorphic-git pack-index cache injected by SyncEngine; identity is
  // preserved across all collaborators so a parsed pack index is reused for
  // every readTree call.
  private readonly cache: object;

  // Captures a runtime-provided fs so tree diffing can stay storage-agnostic.
  constructor(opts: {
    fs: FsClient;
    gitdir: string;
    registeredKindDirectories: () => string[];
    log: (event: string, fields: Record<string, unknown>) => void;
    cache: object;
  }) {
    this.fs = opts.fs;
    this.gitdir = opts.gitdir;
    this.registeredKindDirectories = opts.registeredKindDirectories;
    this.log = opts.log;
    this.cache = opts.cache;
  }

  async listChangedManifestPaths(
    oldCommitHash: string,
    newCommitHash: string,
  ): Promise<ChangedPath[]> {
    return this.listChangedPathsBetweenCommits(
      oldCommitHash, newCommitHash, "manifests",
      this.changedManifestPathsCache, ".yaml",
    );
  }

  async listChangedBinaryPaths(
    oldCommitHash: string,
    newCommitHash: string,
  ): Promise<ChangedPath[]> {
    return this.listChangedPathsBetweenCommits(
      oldCommitHash, newCommitHash, "binary",
      this.changedBinaryPathsCache,
    );
  }

  async readTreeAtCommitPathOrNull(
    commitHash: string,
    filepath: string,
  ): Promise<{ oid: string; tree: ManifestTreeEntry[] } | null> {
    try {
      const result = (await git.readTree({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: commitHash,
        filepath,
        cache: this.cache,
      })) as { oid: string; tree: ManifestTreeEntry[] };
      return { oid: result.oid, tree: result.tree ?? [] };
    } catch {
      return null;
    }
  }

  async readTreeEntriesAtOidOrEmpty(
    treeOid: string,
  ): Promise<ManifestTreeEntry[]> {
    try {
      const result = (await git.readTree({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: treeOid,
        cache: this.cache,
      })) as { tree: ManifestTreeEntry[] };
      return result.tree ?? [];
    } catch {
      return [];
    }
  }

  // Distinguishes a repo with no manifests/ from a failed object
  // read so hydration does not wipe a populated cache on a
  // transient tree-walk error.
  async discoverDeviceSpaces(
    commitHash: string,
  ): Promise<DeviceSpaceDiscovery> {
    try {
      const commit = await git.readCommit({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: commitHash,
        cache: this.cache,
      });
      const root = await git.readTree({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: commit.commit.tree,
        cache: this.cache,
      });
      const manifestsEntry = root.tree.find((entry) => entry.path === "manifests" && entry.type === "tree");
      if (!manifestsEntry) {
        return { status: "ok", deviceSpaces: [] };
      }
      const manifestTree = await git.readTree({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        oid: manifestsEntry.oid,
        cache: this.cache,
      });
      return {
        status: "ok",
        deviceSpaces: manifestTree.tree
          .filter((entry) => entry.type === "tree")
          .map((entry) => entry.path),
      };
    } catch (error) {
      return { status: "unreadable", cause: error };
    }
  }

  async collectBlobEntriesFromTree(
    entries: ManifestTreeEntry[],
    basePath: string,
    out: { oid: string; path: string }[],
    extension?: string,
  ): Promise<void> {
    for (const entry of entries) {
      const fullPath = `${basePath}/${entry.path}`;
      if (entry.type === "tree") {
        const children = await this.readTreeEntriesAtOidOrEmpty(entry.oid);
        await this.collectBlobEntriesFromTree(children, fullPath, out, extension);
      } else if (entry.type === "blob") {
        if (!extension || fullPath.endsWith(extension)) {
          out.push({ oid: entry.oid, path: fullPath });
        }
      }
    }
  }

  private async listChangedPathsBetweenCommits(
    oldCommitHash: string,
    newCommitHash: string,
    rootDir: string,
    pathCache: Map<string, ChangedPath[]>,
    extensionFilter?: string,
  ): Promise<ChangedPath[]> {
    const transitionCacheKey = buildCommitTransitionCacheKey(oldCommitHash, newCommitHash);
    const cachedChangedPaths = pathCache.get(transitionCacheKey);
    if (cachedChangedPaths) {
      promoteCommitTransitionCacheEntry(pathCache, transitionCacheKey, cachedChangedPaths);
      this.log("sync-changed-paths-cache-hit", {
        rootDir,
        fromCommitHash: oldCommitHash,
        toCommitHash: newCommitHash,
        changedFiles: cachedChangedPaths.length,
      });
      return cachedChangedPaths;
    }
    const rootTreeReadStartMs = nowMs();
    const [beforeTree, afterTree] = await Promise.all([
      this.readTreeAtCommitPathOrNull(oldCommitHash, rootDir),
      this.readTreeAtCommitPathOrNull(newCommitHash, rootDir),
    ]);
    const rootTreeReadDurationMs = nowMs() - rootTreeReadStartMs;
    if (beforeTree?.oid && afterTree?.oid && beforeTree.oid === afterTree.oid) {
      this.log("sync-changed-paths-detail", {
        rootDir,
        fromCommitHash: oldCommitHash,
        toCommitHash: newCommitHash,
        beforeTreeOid: beforeTree.oid,
        afterTreeOid: afterTree.oid,
        rootTreeReadDurationMs,
        shortCircuit: true,
        changedPathCount: 0,
      });
      cacheCommitTransitionValue(pathCache, transitionCacheKey, []);
      return [];
    }

    const kindDirs = this.registeredKindDirectories();
    const beforeDeviceSpaces = new Set(
      (beforeTree?.tree ?? []).filter((e) => e.type === "tree").map((e) => e.path),
    );
    const afterDeviceSpaces = new Set(
      (afterTree?.tree ?? []).filter((e) => e.type === "tree").map((e) => e.path),
    );
    const allDeviceSpaces = new Set([...beforeDeviceSpaces, ...afterDeviceSpaces]);

    const diffStats = { treeReadCount: 0, treeReadTotalMs: 0, expandedSubtreeCount: 0 };
    const recursionStartMs = nowMs();
    const changedPaths = new Map<string, { oldOid: string | null; newOid: string | null }>();

    for (const deviceSpace of allDeviceSpaces) {
      for (const kindDir of kindDirs) {
        const [beforeKindTree, afterKindTree] = await Promise.all([
          this.readTreeAtCommitPathOrNull(oldCommitHash, `${rootDir}/${deviceSpace}/${kindDir}`),
          this.readTreeAtCommitPathOrNull(newCommitHash, `${rootDir}/${deviceSpace}/${kindDir}`),
        ]);
        if (beforeKindTree?.oid && afterKindTree?.oid && beforeKindTree.oid === afterKindTree.oid) {
          continue;
        }
        const basePath = `${rootDir}/${deviceSpace}/${kindDir}`;
        await this.collectChangedPathsBetweenTrees(
          beforeKindTree?.tree ?? [],
          afterKindTree?.tree ?? [],
          basePath,
          changedPaths,
          diffStats,
          extensionFilter,
        );
      }
    }

    const recursionWallMs = nowMs() - recursionStartMs;
    this.log("sync-changed-paths-detail", {
      rootDir,
      fromCommitHash: oldCommitHash,
      toCommitHash: newCommitHash,
      beforeTreeOid: beforeTree?.oid ?? null,
      afterTreeOid: afterTree?.oid ?? null,
      rootTreeReadDurationMs,
      recursionWallMs,
      treeReadCount: diffStats.treeReadCount,
      treeReadTotalMs: diffStats.treeReadTotalMs,
      expandedSubtreeCount: diffStats.expandedSubtreeCount,
      changedPathCount: changedPaths.size,
      deviceSpaces: allDeviceSpaces.size,
      registeredKinds: kindDirs.length,
    });
    const filteredPaths = Array
      .from(changedPaths.entries())
      .sort(([pathA], [pathB]) => pathA.localeCompare(pathB))
      .map(([path, oids]) => ({ path, oldOid: oids.oldOid, newOid: oids.newOid }));
    cacheCommitTransitionValue(pathCache, transitionCacheKey, filteredPaths);
    return filteredPaths;
  }

  private async collectChangedPathsBetweenTrees(
    beforeEntries: ManifestTreeEntry[],
    afterEntries: ManifestTreeEntry[],
    basePath: string,
    changedPaths: Map<string, { oldOid: string | null; newOid: string | null }>,
    diffStats: { treeReadCount: number; treeReadTotalMs: number; expandedSubtreeCount: number },
    extensionFilter?: string,
  ): Promise<void> {
    const beforeByPath = new Map(beforeEntries.map((entry) => [entry.path, entry]));
    const afterByPath = new Map(afterEntries.map((entry) => [entry.path, entry]));
    const childPaths = new Set<string>([...beforeByPath.keys(), ...afterByPath.keys()]);
    for (const childName of childPaths) {
      const beforeEntry = beforeByPath.get(childName);
      const afterEntry = afterByPath.get(childName);
      const childPath = `${basePath}/${childName}`;
      if (!beforeEntry && afterEntry) {
        await this.collectPathsFromEntry(
          afterEntry,
          childPath,
          "new",
          changedPaths,
          diffStats,
          extensionFilter,
        );
        continue;
      }
      if (beforeEntry && !afterEntry) {
        await this.collectPathsFromEntry(
          beforeEntry,
          childPath,
          "old",
          changedPaths,
          diffStats,
          extensionFilter,
        );
        continue;
      }
      if (!beforeEntry || !afterEntry) continue;
      if (beforeEntry.type === "tree" && afterEntry.type === "tree") {
        if (beforeEntry.oid === afterEntry.oid) continue;
        const readStartMs = nowMs();
        const [beforeChildren, afterChildren] = await Promise.all([
          this.readTreeEntriesAtOidOrEmpty(beforeEntry.oid),
          this.readTreeEntriesAtOidOrEmpty(afterEntry.oid),
        ]);
        diffStats.treeReadCount += 2;
        diffStats.treeReadTotalMs += nowMs() - readStartMs;
        await this.collectChangedPathsBetweenTrees(
          beforeChildren, afterChildren, childPath,
          changedPaths, diffStats, extensionFilter,
        );
        continue;
      }
      if (beforeEntry.type === "blob" && afterEntry.type === "blob") {
        if (beforeEntry.oid !== afterEntry.oid && (!extensionFilter || childPath.endsWith(extensionFilter))) {
          this.upsertChangedPath(changedPaths, childPath, beforeEntry.oid, afterEntry.oid);
        }
        continue;
      }
      await this.collectPathsFromEntry(
        beforeEntry,
        childPath,
        "old",
        changedPaths,
        diffStats,
        extensionFilter,
      );
      await this.collectPathsFromEntry(
        afterEntry,
        childPath,
        "new",
        changedPaths,
        diffStats,
        extensionFilter,
      );
    }
  }

  private async collectPathsFromEntry(
    entry: ManifestTreeEntry,
    entryPath: string,
    side: "old" | "new",
    changedPaths: Map<string, { oldOid: string | null; newOid: string | null }>,
    diffStats: { treeReadCount: number; treeReadTotalMs: number; expandedSubtreeCount: number },
    extensionFilter?: string,
  ): Promise<void> {
    if (entry.type === "blob") {
      if (!extensionFilter || entryPath.endsWith(extensionFilter)) {
        this.upsertChangedPath(
          changedPaths,
          entryPath,
          side === "old" ? entry.oid : null,
          side === "new" ? entry.oid : null,
        );
      }
      return;
    }
    if (entry.type !== "tree") return;
    diffStats.expandedSubtreeCount++;
    const readStartMs = nowMs();
    const children = await this.readTreeEntriesAtOidOrEmpty(entry.oid);
    diffStats.treeReadCount++;
    diffStats.treeReadTotalMs += nowMs() - readStartMs;
    for (const child of children) {
      await this.collectPathsFromEntry(
        child,
        `${entryPath}/${child.path}`,
        side,
        changedPaths,
        diffStats,
        extensionFilter,
      );
    }
  }

  // Merges both sides of a changed path so callers can skip reading missing
  // sides when building mutations.
  private upsertChangedPath(
    changedPaths: Map<string, { oldOid: string | null; newOid: string | null }>,
    path: string,
    oldOid: string | null,
    newOid: string | null,
  ): void {
    const existing = changedPaths.get(path);
    changedPaths.set(path, {
      oldOid: oldOid ?? existing?.oldOid ?? null,
      newOid: newOid ?? existing?.newOid ?? null,
    });
  }
}
