import { parseLfsPointer } from "./encryption";
import type { LfsPointerFields } from "./encryption";
import { ManifestDatabase, type ManifestDatabaseMutation, type PointerMutation } from "./manifestDatabase";
import type { ManifestMutation, ManifestRecordUpdate } from "./syncTypes";
import {
  type ChangedPath,
  TreeDiffer,
  buildCommitTransitionCacheKey,
  cacheCommitTransitionValue,
  promoteCommitTransitionCacheEntry,
} from "./treeDiffer";
import { errorMessage, nowMs } from "./syncDiagnostics";
import { ManifestBlobReader } from "./manifestBlobReader";
import type { RegisteredManifestRecord } from "./manifestRegistry";

const textDecoder = new TextDecoder();
const INCREMENTAL_PLAN_MAX_CONCURRENCY = 16;

// Runs async work with bounded parallelism so transition planning can hide git
// IO latency without overwhelming browser/runtime resources.
const mapWithConcurrency = async <T, R>(
  items: T[],
  maxConcurrency: number,
  mapper: (item: T, index: number) => Promise<R>,
): Promise<R[]> => {
  if (items.length === 0) return [];
  const results = new Array<R>(items.length);
  let nextIndex = 0;
  const workerCount = Math.min(maxConcurrency, items.length);
  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      while (nextIndex < items.length) {
        const index = nextIndex++;
        results[index] = await mapper(items[index], index);
      }
    }),
  );
  return results;
};

// Describes how cache transition attempts should proceed for one commit move.
export type CacheApplyOutcome =
  | { outcome: "applied"; mutation?: ManifestMutation }
  | { outcome: "stale" }
  | { outcome: "needs_full_hydration" };

// Describes incremental transition execution outcome for one commit pair.
export type IncrementalApplyResult =
  | { outcome: "applied"; mutation: ManifestMutation }
  | { outcome: "stale" }
  | { outcome: "fallback_to_full_replace" };

// Owns commit-to-commit mutation planning so SyncEngine only orchestrates outcomes.
export class CommitTransitionApplier {
  private readonly manifestDb: ManifestDatabase;
  private readonly treeDiffer: TreeDiffer;
  private readonly manifestBlobReader: ManifestBlobReader;
  private readonly log: (event: string, fields: Record<string, unknown>) => void;
  private readonly incrementalMutationPlanCache = new Map<
    string,
    { mutation: ManifestDatabaseMutation; pointerMutation: PointerMutation }
  >();

  // Captures mutation dependencies once so callers can ask for transition outcomes only.
  constructor(opts: {
    manifestDb: ManifestDatabase;
    treeDiffer: TreeDiffer;
    manifestBlobReader: ManifestBlobReader;
    log: (event: string, fields: Record<string, unknown>) => void;
  }) {
    this.manifestDb = opts.manifestDb;
    this.treeDiffer = opts.treeDiffer;
    this.manifestBlobReader = opts.manifestBlobReader;
    this.log = opts.log;
  }

  // Applies one commit transition with incremental-first behavior and full-hydration fallback signaling.
  async applyCommitTransitionToCache(
    previousSyncedHash: string | null,
    nextSyncedCommitHash: string,
  ): Promise<CacheApplyOutcome> {
    const applyStartedAtMs = nowMs();
    if (previousSyncedHash && nextSyncedCommitHash === previousSyncedHash) {
      this.log("sync-commit-transition-noop", {
        fromCommitHash: previousSyncedHash,
        toCommitHash: nextSyncedCommitHash,
        durationMs: nowMs() - applyStartedAtMs,
      });
      return { outcome: "applied" };
    }
    if (previousSyncedHash && nextSyncedCommitHash !== previousSyncedHash) {
      const incrementalResult = await this.tryApplyIncrementalCommitTransitionToCache(
        previousSyncedHash,
        nextSyncedCommitHash,
      );
      if (incrementalResult.outcome === "stale") {
        return { outcome: "stale" };
      }
      if (incrementalResult.outcome === "applied") {
        this.log("sync-commit-transition-applied-incremental", {
          fromCommitHash: previousSyncedHash,
          toCommitHash: nextSyncedCommitHash,
          durationMs: nowMs() - applyStartedAtMs,
        });
        return { outcome: "applied", mutation: incrementalResult.mutation };
      }
    }
    this.log("sync-commit-transition-needs-full-hydration", {
      fromCommitHash: previousSyncedHash,
      toCommitHash: nextSyncedCommitHash,
      durationMs: nowMs() - applyStartedAtMs,
    });
    return { outcome: "needs_full_hydration" };
  }

  // Attempts a CAS-guarded incremental apply for one commit transition.
  async tryApplyIncrementalCommitTransitionToCache(
    previousSyncedHash: string,
    nextSyncedCommitHash: string,
  ): Promise<IncrementalApplyResult> {
    try {
      this.log("sync-incremental-transition-start", {
        fromCommitHash: previousSyncedHash,
        toCommitHash: nextSyncedCommitHash,
      });
      const transitionCacheKey = buildCommitTransitionCacheKey(previousSyncedHash, nextSyncedCommitHash);
      const cachedPlan = this.incrementalMutationPlanCache.get(transitionCacheKey);
      let changedManifestPaths: ChangedPath[] = [];
      let changedPathsDurationMs = 0;
      let buildMutationDurationMs = 0;
      let incrementalMutation: ManifestDatabaseMutation;
      let pointerMutation: PointerMutation;
      if (cachedPlan) {
        incrementalMutation = cachedPlan.mutation;
        pointerMutation = cachedPlan.pointerMutation;
        promoteCommitTransitionCacheEntry(this.incrementalMutationPlanCache, transitionCacheKey, cachedPlan);
        this.log("sync-incremental-mutation-plan-cache-hit", {
          fromCommitHash: previousSyncedHash,
          toCommitHash: nextSyncedCommitHash,
          added: cachedPlan.mutation.added.length,
          updated: cachedPlan.mutation.updated.length,
          removed: cachedPlan.mutation.removed.length,
        });
      } else {
        const changedPathsStartedAtMs = nowMs();
        const [manifestPaths, binaryPaths] = await Promise.all([
          this.treeDiffer.listChangedManifestPaths(previousSyncedHash, nextSyncedCommitHash),
          this.treeDiffer.listChangedBinaryPaths(previousSyncedHash, nextSyncedCommitHash),
        ]);
        changedManifestPaths = manifestPaths;
        changedPathsDurationMs = nowMs() - changedPathsStartedAtMs;
        const buildMutationStartedAtMs = nowMs();
        const plan = await this.buildIncrementalMutationPlan(
          previousSyncedHash,
          nextSyncedCommitHash,
          changedManifestPaths,
          binaryPaths,
        );
        incrementalMutation = plan.mutation;
        pointerMutation = plan.pointerMutation;
        buildMutationDurationMs = nowMs() - buildMutationStartedAtMs;
        cacheCommitTransitionValue(this.incrementalMutationPlanCache, transitionCacheKey, plan);
      }
      this.log("sync-incremental-mutation-plan-built", {
        fromCommitHash: previousSyncedHash,
        toCommitHash: nextSyncedCommitHash,
        changedManifestFiles: changedManifestPaths.length,
        added: incrementalMutation.added.length,
        updated: incrementalMutation.updated.length,
        removed: incrementalMutation.removed.length,
        listChangedPathsDurationMs: changedPathsDurationMs,
        buildMutationDurationMs,
        usedCachedMutation: Boolean(cachedPlan),
      });
      const incrementalApplyStartedAtMs = nowMs();
      const applyResult = await this.manifestDb.applyIncrementalWithCas({
        expectedSyncedCommitHash: previousSyncedHash,
        nextSyncedCommitHash,
        mutation: incrementalMutation,
        pointerMutation,
      });
      const incrementalApplyDurationMs = nowMs() - incrementalApplyStartedAtMs;
      if (applyResult.outcome === "stale") {
        this.log("sync-incremental-cas-stale", {
          fromCommitHash: previousSyncedHash,
          toCommitHash: nextSyncedCommitHash,
          incrementalApplyDurationMs,
        });
        return { outcome: "stale" };
      }
      this.log("sync-incremental-cas-applied", {
        fromCommitHash: previousSyncedHash,
        toCommitHash: nextSyncedCommitHash,
        incrementalApplyDurationMs,
      });
      return {
        outcome: "applied",
        mutation: {
          added: incrementalMutation.added,
          updated: incrementalMutation.updated,
          removed: incrementalMutation.removed,
        },
      };
    } catch (error) {
      this.log("sync-incremental-fallback-to-full-replace", {
        fromCommitHash: previousSyncedHash,
        toCommitHash: nextSyncedCommitHash,
        error: errorMessage(error),
      });
      return { outcome: "fallback_to_full_replace" };
    }
  }

  // Builds manifest and pointer mutations by comparing changed paths between two commits.
  private async buildIncrementalMutationPlan(
    oldCommitHash: string,
    newCommitHash: string,
    changedManifestPaths: Array<ChangedPath | string>,
    changedBinaryPaths: Array<ChangedPath | string>,
  ): Promise<{ mutation: ManifestDatabaseMutation; pointerMutation: PointerMutation }> {
    const kekOldStartMs = nowMs();
    await this.manifestBlobReader.refreshKekCacheState(oldCommitHash);
    const kekRefreshOldMs = nowMs() - kekOldStartMs;
    let kekRefreshNewMs = 0;
    if (newCommitHash !== oldCommitHash) {
      const kekNewStartMs = nowMs();
      await this.manifestBlobReader.refreshKekCacheState(newCommitHash);
      kekRefreshNewMs = nowMs() - kekNewStartMs;
    }
    const added: RegisteredManifestRecord[] = [];
    const updated: ManifestRecordUpdate[] = [];
    const removed: RegisteredManifestRecord[] = [];

    let readRecordCount = 0;
    let readRecordTotalMs = 0;
    let pathsWithBoth = 0;
    let pathsAddedOnly = 0;
    let pathsRemovedOnly = 0;
    let pathsKeyChanged = 0;

    const manifestPairs = await mapWithConcurrency(
      changedManifestPaths,
      INCREMENTAL_PLAN_MAX_CONCURRENCY,
      async (changedManifestPath) => {
        const path = typeof changedManifestPath === "string" ? changedManifestPath : changedManifestPath.path;
        const oldOid = typeof changedManifestPath === "string" ? null : changedManifestPath.oldOid;
        const newOid = typeof changedManifestPath === "string" ? null : changedManifestPath.newOid;
        const readByPath = typeof changedManifestPath === "string" || (!oldOid && !newOid);
        const previousRecordPromise = oldOid
          ? (async () => {
            const readPrevStartMs = nowMs();
            let record = await this.manifestBlobReader.readManifestRecordAtBlobOid(
              oldCommitHash,
              oldOid,
              path,
            );
            if (!record) {
              record = await this.manifestBlobReader.readManifestRecordAtCommitOrNull(oldCommitHash, path);
            }
            return { record, durationMs: nowMs() - readPrevStartMs };
          })()
          : readByPath
            ? (async () => {
              const readPrevStartMs = nowMs();
              const record = await this.manifestBlobReader.readManifestRecordAtCommitOrNull(oldCommitHash, path);
              return { record, durationMs: nowMs() - readPrevStartMs };
            })()
          : Promise.resolve({ record: null as RegisteredManifestRecord | null, durationMs: 0 });
        const nextRecordPromise = newOid
          ? (async () => {
            const readNextStartMs = nowMs();
            let record = await this.manifestBlobReader.readManifestRecordAtBlobOid(
              newCommitHash,
              newOid,
              path,
            );
            if (!record) {
              record = await this.manifestBlobReader.readManifestRecordAtCommitOrNull(newCommitHash, path);
            }
            return { record, durationMs: nowMs() - readNextStartMs };
          })()
          : readByPath
            ? (async () => {
              const readNextStartMs = nowMs();
              const record = await this.manifestBlobReader.readManifestRecordAtCommitOrNull(newCommitHash, path);
              return { record, durationMs: nowMs() - readNextStartMs };
            })()
          : Promise.resolve({ record: null as RegisteredManifestRecord | null, durationMs: 0 });
        const [previousResult, nextResult] = await Promise.all([previousRecordPromise, nextRecordPromise]);
        return {
          path,
          previousRecord: previousResult.record,
          nextRecord: nextResult.record,
          previousDurationMs: previousResult.durationMs,
          nextDurationMs: nextResult.durationMs,
          previousReadCount: oldOid ? 1 : 0,
          nextReadCount: newOid ? 1 : 0,
        };
      },
    );

    for (const pair of manifestPairs) {
      readRecordTotalMs += pair.previousDurationMs + pair.nextDurationMs;
      readRecordCount += pair.previousReadCount + pair.nextReadCount;

      if (pair.previousRecord && pair.nextRecord) {
        pathsWithBoth++;
        if (pair.previousRecord.key === pair.nextRecord.key) {
          updated.push({ previous: pair.previousRecord, current: pair.nextRecord });
        } else {
          pathsKeyChanged++;
          removed.push(pair.previousRecord);
          added.push(pair.nextRecord);
        }
      } else if (pair.nextRecord) {
        pathsAddedOnly++;
        added.push(pair.nextRecord);
      } else if (pair.previousRecord) {
        pathsRemovedOnly++;
        removed.push(pair.previousRecord);
      }
    }

    const addedPointers = new Map<string, LfsPointerFields>();
    const removedPointerPaths: string[] = [];

    const pointerResults = await mapWithConcurrency(
      changedBinaryPaths,
      INCREMENTAL_PLAN_MAX_CONCURRENCY,
      async (changedBinaryPath) => {
        const path = typeof changedBinaryPath === "string" ? changedBinaryPath : changedBinaryPath.path;
        const oldOid = typeof changedBinaryPath === "string" ? null : changedBinaryPath.oldOid;
        const newOid = typeof changedBinaryPath === "string" ? null : changedBinaryPath.newOid;
        const readByPath = typeof changedBinaryPath === "string" || (!oldOid && !newOid);
        if (readByPath) {
          const pointerEntry = await this.manifestBlobReader.readBlobAtCommitPathOrNull(newCommitHash, path);
          if (!pointerEntry) {
            return { path, pointer: null as LfsPointerFields | null };
          }
          return { path, pointer: parseLfsPointer(textDecoder.decode(pointerEntry.blob)) };
        }
        if (!newOid) {
          return { path, pointer: null as LfsPointerFields | null };
        }
        const pointerBlob = await this.manifestBlobReader.readBlobByOidOrNull(newOid);
        if (pointerBlob) {
          return {
            path,
            pointer: parseLfsPointer(textDecoder.decode(pointerBlob)),
          };
        }
        const pointerEntry = await this.manifestBlobReader.readBlobAtCommitPathOrNull(newCommitHash, path);
        if (!pointerEntry) {
          return { path, pointer: null as LfsPointerFields | null };
        }
        return {
          path,
          pointer: parseLfsPointer(textDecoder.decode(pointerEntry.blob)),
        };
      },
    );
    for (const { path, pointer } of pointerResults) {
      if (pointer) {
        addedPointers.set(path, pointer);
      } else {
        removedPointerPaths.push(path);
      }
    }

    if (addedPointers.size > 0) {
      await this.manifestBlobReader.unwrapDeksForPointers(newCommitHash, addedPointers);
    }

    this.log("sync-build-mutation-detail", {
      fromCommitHash: oldCommitHash,
      toCommitHash: newCommitHash,
      changedManifestPathCount: changedManifestPaths.length,
      changedBinaryPathCount: changedBinaryPaths.length,
      kekRefreshOldMs,
      kekRefreshNewMs,
      readRecordCount,
      readRecordTotalMs,
      pathsWithBoth,
      pathsAddedOnly,
      pathsRemovedOnly,
      pathsKeyChanged,
      addedPointers: addedPointers.size,
      removedPointers: removedPointerPaths.length,
    });

    return {
      mutation: { added, updated, removed },
      pointerMutation: { added: addedPointers, removed: removedPointerPaths },
    };
  }
}
