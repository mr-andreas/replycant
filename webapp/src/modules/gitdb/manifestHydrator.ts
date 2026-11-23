import git from "isomorphic-git";
import LightningFS from "@isomorphic-git/lightning-fs";
import { BoundedChannel } from "./boundedChannel";
import { parseLfsPointer } from "./encryption";
import type { LfsPointerFields } from "./encryption";
import { ManifestDatabase } from "./manifestDatabase";
import type { RegisteredManifestRecord } from "./manifestRegistry";
import { TreeDiffer } from "./treeDiffer";
import { nowMs, syncMark, syncMeasure } from "./syncDiagnostics";
import { EncryptionIntegrityError, ManifestBlobReader } from "./manifestBlobReader";
import { ManifestDecodeSpill } from "./manifestDecodeSpill";

const BLOB_READ_BATCH_SIZE = 50;
const textDecoder = new TextDecoder();

// Carries full-hydration read timings so callers can log stable benchmark breakdowns.
export interface ManifestHydrationTimings {
  treeWalkMs: number;
  kekRefreshMs: number;
  blobReadDecodeParseMs: number;
  replaceCacheMs: number;
  totalMs: number;
}

// Carries one full-hydration output so sync orchestration can publish cache state.
export interface ManifestHydrationResult {
  totalRecords: number;
  pointers: Map<string, LfsPointerFields>;
  timings: ManifestHydrationTimings;
}

// Streams manifests from git into staged IDB replacement while reporting progress.
export class ManifestHydrator {
  private readonly fs: LightningFS;
  private readonly gitdir: string;
  private readonly treeDiffer: TreeDiffer;
  private readonly manifestDb: ManifestDatabase;
  private readonly manifestBlobReader: ManifestBlobReader;
  private readonly registeredKindDirectories: () => string[];
  private readonly emitTreeWalkProgress: (loaded: number, total: number) => void;
  private readonly emitKekRefreshProgress: (loaded: number, total: number) => void;
  private readonly emitManifestReadProgress: (loaded: number, total: number) => void;
  private readonly emitPointerProgress: (loaded: number, total: number) => void;
  private readonly log: (event: string, fields: Record<string, unknown>) => void;
  // Shared isomorphic-git pack-index cache so the readBlob fan-out inside
  // streamManifestsToCache reuses the same parsed .idx across every batch and
  // pointer pass, and shares it with TreeDiffer/ManifestBlobReader.
  private readonly cache: object;

  // Captures dependencies so full-hydration logic can stay outside SyncEngine.
  constructor(opts: {
    fs: LightningFS;
    gitdir: string;
    treeDiffer: TreeDiffer;
    manifestDb: ManifestDatabase;
    manifestBlobReader: ManifestBlobReader;
    registeredKindDirectories: () => string[];
    emitTreeWalkProgress: (loaded: number, total: number) => void;
    emitKekRefreshProgress: (loaded: number, total: number) => void;
    emitManifestReadProgress: (loaded: number, total: number) => void;
    emitPointerProgress: (loaded: number, total: number) => void;
    log: (event: string, fields: Record<string, unknown>) => void;
    cache: object;
  }) {
    this.fs = opts.fs;
    this.gitdir = opts.gitdir;
    this.treeDiffer = opts.treeDiffer;
    this.manifestDb = opts.manifestDb;
    this.manifestBlobReader = opts.manifestBlobReader;
    this.registeredKindDirectories = opts.registeredKindDirectories;
    this.emitTreeWalkProgress = opts.emitTreeWalkProgress;
    this.emitKekRefreshProgress = opts.emitKekRefreshProgress;
    this.emitManifestReadProgress = opts.emitManifestReadProgress;
    this.emitPointerProgress = opts.emitPointerProgress;
    this.log = opts.log;
    this.cache = opts.cache;
  }

  // Rebuilds manifest and pointer cache state for one commit using a streaming pipeline.
  async streamManifestsToCache(
    commitHash: string,
    syncedCommitHash: string,
    cacheFormatVersion = 0,
  ): Promise<ManifestHydrationResult> {
    const startedAtMs = nowMs();
    const kindDirs = this.registeredKindDirectories();
    if (kindDirs.length === 0) {
      await this.manifestDb.replaceCacheStreamed(
        (async function* () {})(),
        syncedCommitHash,
        undefined,
        cacheFormatVersion,
      );
      return {
        totalRecords: 0,
        pointers: new Map(),
        timings: { treeWalkMs: 0, kekRefreshMs: 0, blobReadDecodeParseMs: 0, replaceCacheMs: 0, totalMs: 0 },
      };
    }

    // Discovers manifest and pointer blobs up front so downstream stages can stream by oid.
    syncMark("streamManifests-treeWalk-start");
    const treeWalkStartedAtMs = nowMs();
    const discovery = await this.treeDiffer.discoverDeviceSpaces(commitHash);
    if (discovery.status === "unreadable") {
      const detail = discovery.cause instanceof Error
        ? discovery.cause.message
        : "unknown tree-walk error";
      throw new Error(`could not read manifests tree at ${commitHash}: ${detail}`, {
        cause: discovery.cause,
      });
    }
    const deviceSpaces = discovery.deviceSpaces;
    if (deviceSpaces.length === 0) {
      this.log("stream-manifests-empty", { commitHash, durationMs: nowMs() - startedAtMs });
      await this.manifestDb.replaceCacheStreamed(
        (async function* () {})(),
        syncedCommitHash,
        undefined,
        cacheFormatVersion,
      );
      return {
        totalRecords: 0,
        pointers: new Map(),
        timings: { treeWalkMs: 0, kekRefreshMs: 0, blobReadDecodeParseMs: 0, replaceCacheMs: 0, totalMs: 0 },
      };
    }

    const blobEntries: { oid: string; path: string }[] = [];
    const pointerOidsByPath = new Map<string, string>();
    let discoveredFiles = 0;
    this.emitTreeWalkProgress(0, 0);
    for (const deviceSpace of deviceSpaces) {
      for (const kindDir of kindDirs) {
        const kindTree = await this.treeDiffer.readTreeAtCommitPathOrNull(commitHash, `encryptionspaces/${deviceSpace}/manifests/${kindDir}`);
        if (kindTree) {
          const basePath = `encryptionspaces/${deviceSpace}/manifests/${kindDir}`;
          const prevCount = blobEntries.length;
          await this.treeDiffer.collectBlobEntriesFromTree(kindTree.tree, basePath, blobEntries, ".yaml");
          discoveredFiles += blobEntries.length - prevCount;
          this.emitTreeWalkProgress(discoveredFiles, 0);
        }
        const pointerTree = await this.treeDiffer.readTreeAtCommitPathOrNull(commitHash, `encryptionspaces/${deviceSpace}/binary/${kindDir}`);
        if (pointerTree) {
          const pointerBasePath = `encryptionspaces/${deviceSpace}/binary/${kindDir}`;
          const pointerEntries: { oid: string; path: string }[] = [];
          await this.treeDiffer.collectBlobEntriesFromTree(pointerTree.tree, pointerBasePath, pointerEntries);
          for (const entry of pointerEntries) {
            pointerOidsByPath.set(entry.path, entry.oid);
          }
          discoveredFiles += pointerEntries.length;
          this.emitTreeWalkProgress(discoveredFiles, 0);
        }
      }
    }
    const treeWalkMs = nowMs() - treeWalkStartedAtMs;
    syncMark("streamManifests-treeWalk-end");
    syncMeasure("streamManifests-treeWalk", "streamManifests-treeWalk-start", "streamManifests-treeWalk-end");
    this.log("stream-manifests-tree-walk-complete", {
      commitHash,
      blobCount: blobEntries.length,
      pointerBlobCount: pointerOidsByPath.size,
      durationMs: treeWalkMs,
    });

    // Refreshes KEK cache once before decode work to reduce per-record key churn.
    syncMark("streamManifests-kekRefresh-start");
    const kekRefreshStartedAtMs = nowMs();
    this.emitKekRefreshProgress(0, 1);
    await this.manifestBlobReader.refreshKekCacheState(commitHash);
    this.emitKekRefreshProgress(1, 1);
    const kekRefreshMs = nowMs() - kekRefreshStartedAtMs;
    syncMark("streamManifests-kekRefresh-end");
    syncMeasure("streamManifests-kekRefresh", "streamManifests-kekRefresh-start", "streamManifests-kekRefresh-end");

    // A space is pinned before any cache write. A later flip throws
    // here, while the previous cache is still the one on screen.
    for (const deviceSpace of deviceSpaces) {
      await this.manifestBlobReader.keySetRoot(
        commitHash,
        `encryptionspaces/${deviceSpace}/manifests/pin`,
      );
    }

    this.emitManifestReadProgress(0, blobEntries.length);
    const channelA = new BoundedChannel<{ oid: string; path: string; blob: Uint8Array }>(200);
    // The visible cache stays untouched until this pipeline finishes.
    // Only the decrypted YAML is spilled. The parsed record is much
    // larger, and keeping one per manifest is what made the decode
    // loop slow down. The spill database is not the visible cache.
    const decodedRecords = new ManifestDecodeSpill<{ yaml: string; path: string }>(
      "gitdb-manifest-decode-spill",
    );
    const readFailures = { decodeFailed: 0, parseRejected: 0 };
    let encryptedManifestCount = 0;
    let firstDecodeError: string | null = null;

    // Keeps first decode failure around so callers can show actionable startup errors.
    const captureDecodeError = (error: unknown): void => {
      readFailures.decodeFailed += 1;
      if (!firstDecodeError) {
        if (error instanceof Error) {
          const message = error.message.trim();
          firstDecodeError = message.length > 0 ? message : error.name || "UnknownError";
        } else if (typeof error === "string") {
          firstDecodeError = error.trim().length > 0 ? error : "UnknownError";
        } else {
          firstDecodeError = String(error);
        }
      }
    };

    syncMark("streamManifests-pipeline-start");
    const pipelineStartedAtMs = nowMs();

    // Reads raw blobs in batches and pushes successful reads to channelA.
    const stageA = (async () => {
      try {
        for (let i = 0; i < blobEntries.length; i += BLOB_READ_BATCH_SIZE) {
          const batch = blobEntries.slice(i, i + BLOB_READ_BATCH_SIZE);
          const results = await Promise.all(
            batch.map(async (entry) => {
              try {
                const { blob } = await git.readBlob({
                  fs: this.fs,
                  dir: this.gitdir,
                  gitdir: this.gitdir,
                  oid: entry.oid,
                  cache: this.cache,
                });
                return { oid: entry.oid, path: entry.path, blob: blob as Uint8Array };
              } catch (error) {
                captureDecodeError(error);
                return null;
              }
            }),
          );
          for (const item of results) {
            if (item) await channelA.send(item);
          }
        }
      } finally {
        channelA.close();
      }
    })();

    // Decodes every manifest before the cache is replaced. An object
    // that does not open must not clear the library the user can see.
    const stageB = (async () => {
      let decodedCount = 0;
      const totalBlobs = blobEntries.length;
      for await (const { blob, path } of channelA.receive()) {
        try {
          encryptedManifestCount += 1;
          const rawYaml = await this.manifestBlobReader.decodeManifestBlobToYaml(commitHash, blob, path);
          const record = this.manifestBlobReader.decodeYamlToRecord(
            rawYaml,
            this.manifestBlobReader.inferExpectedKindFromPath(path),
            path,
          );
          if (!record) {
            readFailures.parseRejected += 1;
            continue;
          }
          await decodedRecords.add({ yaml: rawYaml, path });
          decodedCount += 1;
          this.emitManifestReadProgress(decodedCount, totalBlobs);
        } catch (error) {
          if (error instanceof EncryptionIntegrityError) throw error;
          captureDecodeError(error);
        }
      }
    })();

    let blobReadDecodeParseMs = 0;
    let replaceCacheMs = 0;
    let totalRecords = 0;
    let pointers = new Map<string, LfsPointerFields>();
    try {
      await Promise.all([stageA, stageB]);

      blobReadDecodeParseMs = nowMs() - pipelineStartedAtMs;
      syncMark("streamManifests-pipeline-end");
      syncMeasure("streamManifests-pipeline", "streamManifests-pipeline-start", "streamManifests-pipeline-end");

      // Processes binary pointer blobs after manifests to keep pointer writes
      // isolated and cheap. Progress uses a unified scale of 2*N where N is the
      // pointer count: reading blobs [0..N], unwrapping DEKs [N..2N].
      pointers = new Map<string, LfsPointerFields>();
      const N = pointerOidsByPath.size > 0 ? pointerOidsByPath.size : 1;
      const scale = N * 2;
      this.emitPointerProgress(0, scale);
      let processedPointers = 0;
      for (const [path, oid] of pointerOidsByPath) {
        try {
          const { blob: pointerBlob } = await git.readBlob({
            fs: this.fs,
            dir: this.gitdir,
            gitdir: this.gitdir,
            oid,
            cache: this.cache,
          });
          pointers.set(path, parseLfsPointer(textDecoder.decode(pointerBlob as Uint8Array)));
        } catch {
          // Skips unreadable pointer blobs so sync can continue with available records.
        }
        processedPointers += 1;
        this.emitPointerProgress(processedPointers, scale);
      }
      if (pointerOidsByPath.size === 0) {
        this.emitPointerProgress(1, 2);
      }
      await this.manifestBlobReader.unwrapDeksForPointers(commitHash, pointers, (loaded, total) => {
        this.emitPointerProgress(N + Math.round((loaded / total) * N), scale);
      });
      this.emitPointerProgress(scale, scale);

      if (blobEntries.length > 0 && decodedRecords.length === 0) {
        throw new Error(
          `No parseable manifests found in ${blobEntries.length} files. ` +
            `decodeFailed=${readFailures.decodeFailed}, parseRejected=${readFailures.parseRejected}. ` +
            `firstDecodeError=${firstDecodeError ?? "unknown"}.`,
        );
      }

      const replaceCacheStartedAtMs = nowMs();
      await this.manifestDb.replaceCacheStreamed(
        this.recordsFromSpill(decodedRecords),
        syncedCommitHash,
        pointers,
        cacheFormatVersion,
      );
      replaceCacheMs = nowMs() - replaceCacheStartedAtMs;
      totalRecords = decodedRecords.length;
    } finally {
      await decodedRecords.discard();
    }

    const totalMs = nowMs() - startedAtMs;
    this.log("stream-manifests-complete", {
      commitHash,
      totalRecords,
      encryptedManifests: encryptedManifestCount,
      decodeFailed: readFailures.decodeFailed,
      parseRejected: readFailures.parseRejected,
      pointerCount: pointers.size,
      firstDecodeError,
      treeWalkMs,
      kekRefreshMs,
      blobReadDecodeParseMs,
      replaceCacheMs,
      durationMs: totalMs,
    });

    return {
      totalRecords,
      pointers,
      timings: { treeWalkMs, kekRefreshMs, blobReadDecodeParseMs, replaceCacheMs, totalMs },
    };
  }

  // The read loop only kept the YAML so the parsed objects could be
  // collected. The cache write parses them again, which is cheap next
  // to reading the git objects.
  private async *recordsFromSpill(
    spill: ManifestDecodeSpill<{ yaml: string; path: string }>,
  ): AsyncGenerator<RegisteredManifestRecord> {
    for await (const item of spill.records()) {
      const record = this.manifestBlobReader.decodeYamlToRecord(
        item.yaml,
        this.manifestBlobReader.inferExpectedKindFromPath(item.path),
        item.path,
      );
      if (record) yield record;
    }
  }
}
