import git from "isomorphic-git";
import LightningFS from "@isomorphic-git/lightning-fs";
import { GitTransport, PullRebaseConflictError } from "./gitTransport";
import { TreeDiffer } from "./treeDiffer";
import { ManifestRegistry } from "./manifestRegistry";
import { ManifestDatabase } from "./manifestDatabase";
import type {
  ManifestChangeListener,
  ManifestDatabaseChange,
  SyncCommitSummary,
  SyncEngineConfig,
  SyncListener,
  SyncSnapshot,
  OnboardingAuthorizationProbe,
  MtlsHeadersProvider,
  AgePrivateKeyProvider,
} from "./syncTypes";
import {
  computeBackoffMs,
  describeSyncFailure,
  errorMessage,
  logSyncDebug,
  nowMs,
  syncMark,
  syncMeasure,
  syncTimer,
} from "./syncDiagnostics";
import { ManifestBlobReader } from "./manifestBlobReader";
import { ManifestHydrator } from "./manifestHydrator";
import { CommitTransitionApplier } from "./commitTransitionApplier";
import {
  DatabaseVersionError,
  DatabaseVersionUnreadableError,
  requireAcceptedDatabaseVersion,
  requireNoDatabaseVersionDowngrade,
} from "./databaseVersion";

type SyncCycleStatus = "success" | "noop" | "stale" | "failed";
type StartupTimingRecorder = (phase: string, durationMs: number) => void;
type VisibilityProvider = () => boolean;
type ProgressPhaseId =
  | "recoveringCache"
  | "checkingForUpdates"
  | "downloadingData"
  | "receivingObjects"
  | "resolvingDeltas"
  | "scanningRepository"
  | "preparingDecryption"
  | "readingManifests"
  | "processingMedia";

type ProgressPhaseState = {
  id: ProgressPhaseId;
  label: string;
  weight: number;
  progress: number;
};
export { computeBackoffMs } from "./syncDiagnostics";


// Coordinates clone/fetch, manifest decoding via registry, and database persistence for sync consumers.
export class SyncEngine {
  private readonly config: SyncEngineConfig;
  private readonly fs: LightningFS;
  private readonly gitdir = "/repo";
  private effectiveSyncIntervalMs: number;
  private isSyncing = false;
  private failureCount = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private pendingRewindCommitHash: string | null = null;
  private userPeriodicSyncPaused = false;
  private isRewindPaused = false;
  private listener: SyncListener;
  private manifestChangeListener: ManifestChangeListener | null = null;
  private snapshot: SyncSnapshot;
  private readonly visibilityProvider: VisibilityProvider;
  private readonly manifestDb: ManifestDatabase;
  private readonly logPrefix: string;
  private readonly transport: GitTransport;
  private readonly treeDiffer: TreeDiffer;
  private readonly manifestBlobReader: ManifestBlobReader;
  private readonly manifestHydrator: ManifestHydrator;
  private readonly commitTransitionApplier: CommitTransitionApplier;
  // Single isomorphic-git cache shared across every gitdb collaborator. Holds
  // parsed pack indexes and un-deltified object slices keyed under internal
  // symbols, so repeat git.readBlob/readTree/expandOid calls skip the
  // dominant .idx parse cost. Identity must be preserved across all callers.
  private readonly gitObjectCache: object = {};
  private readonly progressPhaseWeights: Record<ProgressPhaseId, number> = {
    recoveringCache: 1,
    checkingForUpdates: 1,
    downloadingData: 1,
    receivingObjects: 15,
    resolvingDeltas: 5,
    scanningRepository: 9,
    preparingDecryption: 1,
    readingManifests: 17,
    processingMedia: 10,
  };
  private readonly progressPhaseDefaults: Array<{ id: ProgressPhaseId; label: string }> = [
    { id: "recoveringCache", label: "Recovering cache" },
    { id: "checkingForUpdates", label: "Checking for updates" },
    { id: "downloadingData", label: "Downloading data" },
    { id: "receivingObjects", label: "Receiving objects" },
    { id: "resolvingDeltas", label: "Resolving deltas" },
    { id: "scanningRepository", label: "Scanning repository" },
    { id: "preparingDecryption", label: "Preparing decryption" },
    { id: "readingManifests", label: "Reading manifests" },
    { id: "processingMedia", label: "Processing media" },
  ];
  private progressPhases: ProgressPhaseState[] = [];
  private activeProgressPhase: ProgressPhaseId | null = null;
  private lastProgressEmitMs = 0;
  private static readonly PROGRESS_THROTTLE_MS = 300;

  constructor(
    config: SyncEngineConfig,
    registry: ManifestRegistry,
    manifestDb: ManifestDatabase,
    listener: SyncListener,
    mtlsHeadersProvider: MtlsHeadersProvider = () => null,
    agePrivateKeyProvider: AgePrivateKeyProvider = () => null,
    visibilityProvider: VisibilityProvider = () => false,
  ) {
    this.config = config;
    this.effectiveSyncIntervalMs = config.syncIntervalMs;
    this.fs = new LightningFS(config.fsVolumeName);
    this.manifestDb = manifestDb;
    this.listener = listener;
    this.visibilityProvider = visibilityProvider;
    this.logPrefix = config.logPrefix ?? "sync";
    this.snapshot = {
      syncing: false,
      error: null,
      unrecoverableError: null,
      lastSyncAt: null,
      syncedCommitHash: null,
      periodicSyncPaused: false,
      periodicSyncUserEnabled: true,
      syncIntervalMs: this.effectiveSyncIntervalMs,
      isOffHead: false,
      requiresHardResetPermission: false,
      cloneProgress: null,
    };
    this.transport = new GitTransport({
      config,
      fs: this.fs,
      mtlsHeadersProvider,
      log: (event, fields) => this.log(event, fields),
      onProgress: (event) => this.emitGitTransportProgress(event.phase, event.loaded, event.total),
      cache: this.gitObjectCache,
    });
    this.treeDiffer = new TreeDiffer({
      fs: this.fs,
      gitdir: this.gitdir,
      registeredKindDirectories: () => registry.registeredKindDirectories(),
      log: (event, fields) => this.log(event, fields),
      cache: this.gitObjectCache,
    });
    this.manifestBlobReader = new ManifestBlobReader({
      fs: this.fs,
      gitdir: this.gitdir,
      registry,
      agePrivateKeyProvider,
      cache: this.gitObjectCache,
    });
    this.manifestHydrator = new ManifestHydrator({
      fs: this.fs,
      gitdir: this.gitdir,
      treeDiffer: this.treeDiffer,
      manifestDb,
      manifestBlobReader: this.manifestBlobReader,
      registeredKindDirectories: () => registry.registeredKindDirectories(),
      emitTreeWalkProgress: (loaded, total) => this.emitTreeWalkProgress(loaded, total),
      emitKekRefreshProgress: (loaded, total) => this.emitKekRefreshProgress(loaded, total),
      emitManifestReadProgress: (loaded, total) => this.emitManifestReadProgress(loaded, total),
      emitPointerProgress: (loaded, total) => this.emitPointerProgress(loaded, total),
      log: (event, fields) => this.log(event, fields),
      cache: this.gitObjectCache,
    });
    this.commitTransitionApplier = new CommitTransitionApplier({
      manifestDb,
      treeDiffer: this.treeDiffer,
      manifestBlobReader: this.manifestBlobReader,
      log: (event, fields) => this.log(event, fields),
    });
  }

  private log(event: string, fields: Record<string, unknown>): void {
    logSyncDebug(this.logPrefix, event, fields);
  }

  // Registers a listener for manifest database changes so the app can rebuild its view state.
  onManifestChange(listener: ManifestChangeListener): void {
    this.manifestChangeListener = listener;
  }

  // Keeps one source of truth for whether polling should currently be blocked.
  private periodicSyncPaused(): boolean {
    return this.userPeriodicSyncPaused || this.isRewindPaused;
  }

  // Initializes weighted phase state so sync progress can advance across
  // multiple operations without resetting back to zero between phases.
  private resetProgressPhases(): void {
    this.progressPhases = this.progressPhaseDefaults.map((phase) => ({
      id: phase.id,
      label: phase.label,
      weight: this.progressPhaseWeights[phase.id],
      progress: 0,
    }));
    this.activeProgressPhase = null;
  }

  // Creates one phase entry lazily so non-startup sync paths can still emit
  // coherent progress without requiring bootstrap-specific initialization.
  private ensureProgressPhase(id: ProgressPhaseId, label: string): ProgressPhaseState {
    let phase = this.progressPhases.find((entry) => entry.id === id);
    if (!phase) {
      phase = {
        id,
        label,
        weight: this.progressPhaseWeights[id],
        progress: 0,
      };
      this.progressPhases.push(phase);
    }
    if (phase.label !== label) {
      phase.label = label;
    }
    return phase;
  }

  // Marks the currently active phase complete before switching to the next so
  // the overall percentage remains monotonic across phase transitions.
  private activateProgressPhase(id: ProgressPhaseId, label: string): void {
    const changing = this.activeProgressPhase !== id;
    if (this.activeProgressPhase && changing) {
      const active = this.progressPhases.find((entry) => entry.id === this.activeProgressPhase);
      if (active) active.progress = 1;
    }
    this.activeProgressPhase = id;
    this.ensureProgressPhase(id, label);
    if (changing) {
      this.publishOverallProgress(label, undefined, undefined, true);
    }
  }

  // Updates the active phase fraction while clamping to monotonic values so
  // jittery upstream counters cannot move the visible progress backward.
  // Forces emission when the phase completes (progress reaches 1) so the
  // overall bar always jumps when a phase finishes.
  private updateActivePhaseProgress(id: ProgressPhaseId, label: string, progress: number, loaded?: number, total?: number): void {
    const phase = this.ensureProgressPhase(id, label);
    const clamped = Math.min(1, Math.max(0, progress));
    phase.progress = Math.max(phase.progress, clamped);
    this.activeProgressPhase = id;
    this.publishOverallProgress(label, loaded, total, clamped >= 1);
  }

  // Collapses weighted phase progress into one user-facing percentage so the
  // onboarding and status bars can represent the entire sync lifecycle.
  // Caps at 99% so the bar never appears stuck at 100% while post-sync
  // setup (manifest change handling, timeline rebuild) runs on the main thread.
  // Throttles emissions to avoid saturating the postMessage channel and UI
  // re-renders; phase transitions always emit immediately but do not reset
  // the throttle window so the next detail update can still fire.
  private publishOverallProgress(label: string, loaded?: number, total?: number, force?: boolean): void {
    const now = nowMs();
    if (!force && now - this.lastProgressEmitMs < SyncEngine.PROGRESS_THROTTLE_MS) return;
    const totalWeight = this.progressPhases.reduce((sum, phase) => sum + phase.weight, 0);
    if (totalWeight <= 0) return;
    const completedWeight = this.progressPhases.reduce(
      (sum, phase) => sum + phase.weight * phase.progress,
      0,
    );
    const raw = completedWeight / totalWeight;
    if (!force) this.lastProgressEmitMs = now;
    this.snapshot = {
      ...this.snapshot,
      cloneProgress: {
        phase: label,
        progress: Math.min(0.99, Math.max(0, raw)),
        loaded,
        total,
      },
    };
    this.listener(this.snapshot);
  }

  // Converts git transport progress events into weighted sync progress so
  // clone/fetch transfer contributes to the unified onboarding percentage.
  // After "Resolving deltas" finishes (the final git transport phase), switches
  // the label to "Writing pack" so the user knows the disk flush is in progress.
  private emitGitTransportProgress(phaseLabel: string | undefined, loaded: number | undefined, total: number | undefined): void {
    const label = phaseLabel ?? "Downloading data";
    const phaseId: ProgressPhaseId =
      label === "Receiving objects"
        ? "receivingObjects"
        : label === "Resolving deltas" || label === "Writing pack"
          ? "resolvingDeltas"
          : "downloadingData";
    this.activateProgressPhase(phaseId, label);
    const fraction = this.progressFractionFromLoadedTotal(loaded, total);
    if (label === "Resolving deltas" && typeof total === "number" && total > 0 && loaded === total) {
      this.updateActivePhaseProgress("resolvingDeltas", "Writing pack", fraction);
    } else {
      this.updateActivePhaseProgress(phaseId, label, fraction, loaded, total);
    }
  }

  // Maps loaded/total counters into a stable 0-1 fraction, with conservative
  // fallback for streams that do not report total work size.
  private progressFractionFromLoadedTotal(loaded: number | undefined, total: number | undefined): number {
    if (typeof total === "number" && total > 0) {
      const safeLoaded = typeof loaded === "number" ? loaded : 0;
      return safeLoaded / total;
    }
    if (typeof loaded !== "number" || loaded <= 0) return 0;
    return Math.min(0.9, loaded / (loaded + 25));
  }

  // Exposes user-controlled polling state so host UIs can disable auto-sync without rewinding.
  setUserPeriodicSyncPaused(paused: boolean): void {
    this.userPeriodicSyncPaused = paused;
    this.snapshot = {
      ...this.snapshot,
      periodicSyncPaused: this.periodicSyncPaused(),
      periodicSyncUserEnabled: !this.userPeriodicSyncPaused,
      isOffHead: this.isRewindPaused,
    };
    this.listener(this.snapshot);
    this.scheduleNext();
  }

  // Updates polling cadence at runtime so host apps can tune sync pressure without rebuilds.
  setSyncIntervalMs(intervalMs: number): void {
    if (!Number.isFinite(intervalMs) || intervalMs < 1) {
      throw new Error("Sync interval must be a positive number of milliseconds.");
    }
    this.effectiveSyncIntervalMs = Math.floor(intervalMs);
    this.snapshot = {
      ...this.snapshot,
      syncIntervalMs: this.effectiveSyncIntervalMs,
    };
    this.listener(this.snapshot);
    this.scheduleNext();
  }

  // Emits a manifest database change event to the registered listener.
  private emitManifestChange(change: ManifestDatabaseChange): void {
    this.manifestChangeListener?.(change);
  }

  // Prints a consolidated timing breakdown so full rehydration bottlenecks are visible at a glance.
  private logFullHydrationBenchmark(opts: {
    pullMs?: number;
    readTimings: { treeWalkMs: number; kekRefreshMs: number; blobReadDecodeParseMs: number; totalMs: number };
    replaceCacheMs: number;
    totalMs: number;
    records: number;
    pointers: number;
  }): void {
    const pad = (label: string, ms: number): string => {
      const msStr = `${Math.round(ms)}ms`;
      return `  ${label.padEnd(22)}${msStr.padStart(8)}`;
    };
    const lines: string[] = [`[${this.logPrefix}] === Full Rehydration Benchmark ===`];
    if (opts.pullMs !== undefined) lines.push(pad("Pull/fetch:", opts.pullMs));
    lines.push(pad("Tree walk:", opts.readTimings.treeWalkMs));
    lines.push(pad("KEK refresh:", opts.readTimings.kekRefreshMs));
    lines.push(pad("Blob read/decode:", opts.readTimings.blobReadDecodeParseMs));
    lines.push(pad("Replace cache:", opts.replaceCacheMs));
    lines.push(`  ${"─".repeat(30)}`);
    lines.push(pad("Total:", opts.totalMs));
    lines.push(`  Records: ${opts.records}, Pointers: ${opts.pointers}`);
    console.log(lines.join("\n"));
  }

  // Hydrates in-memory snapshot from persisted cache so UI can render timeline without waiting for network sync.
  async bootstrapFromCache(): Promise<{ hasCachedData: boolean }> {
    syncMark("bootstrapFromCache-start");
    this.log("bootstrap-start", { remoteUrl: this.config.gitRemoteUrl, branch: this.config.gitBranch });
    this.resetProgressPhases();
    this.activateProgressPhase("recoveringCache", "Recovering cache");
    syncMark("bootstrapFromCache-recoverInterruptedCacheUpdate-start");
    const recoverTimer = syncTimer("bootstrapFromCache-recoverInterruptedCacheUpdate");
    await this.manifestDb.initialize();
    await this.manifestDb.recoverInterruptedCacheUpdate();
    this.log("bootstrap-cache-recover-complete", {
      durationMs: recoverTimer.stop(),
    });
    const loadTimer = syncTimer("bootstrapFromCache-loadCache");
    const syncedCommitHash = await this.manifestDb.readSyncedCommitHash();
    const hasCachedData = await this.manifestDb.hasAnyRecords();
    this.log("bootstrap-cache-load-complete", {
      hasCachedData,
      syncedCommitHash,
      durationMs: loadTimer.stop(),
    });
    this.updateActivePhaseProgress("recoveringCache", "Recovering cache", 1);
    this.snapshot = {
      ...this.snapshot,
      syncedCommitHash,
    };
    this.emitManifestChange({ type: "fullReplace" });
    this.listener(this.snapshot);
    syncMark("bootstrapFromCache-end");
    const measuredDurationMs = syncMeasure("bootstrapFromCache", "bootstrapFromCache-start", "bootstrapFromCache-end");
    this.log("bootstrap-complete", {
      hasCachedData,
      durationMs: measuredDurationMs ?? 0,
    });
    return { hasCachedData };
  }

  // Initializes cache-first rendering so UI paints immediately while sync warms up.
  async bootstrap(): Promise<void> {
    syncMark("bootstrap-start");
    const bootstrapStartedAtMs = nowMs();
    await this.bootstrapFromCache();
    await this.syncNow("startup");
    this.scheduleNext();
    syncMark("bootstrap-end");
    const measuredDurationMs = syncMeasure("bootstrap", "bootstrap-start", "bootstrap-end");
    this.log("bootstrap-full-complete", {
      durationMs: measuredDurationMs ?? nowMs() - bootstrapStartedAtMs,
    });
  }

  // Allows users to force refresh while still preventing overlapping repository operations.
  async syncNow(reason: "startup" | "manual" | "poll"): Promise<void> {
    if (this.snapshot.unrecoverableError) return;
    if (await this.shouldSkipSync(reason)) return;
    this.beginSyncCycle(reason);
    const syncStartedAtMs = nowMs();
    const startupTimings: Record<string, number> = {};
    let startupSyncStatus: SyncCycleStatus = "success";
    const recordStartupTiming = (phase: string, durationMs: number): void => {
      if (reason !== "startup") return;
      startupTimings[phase] = durationMs;
    };

    try {
      startupSyncStatus = await this.executeSyncCycle(reason, syncStartedAtMs, recordStartupTiming);
    } catch (error) {
      startupSyncStatus = "failed";
      this.handleSyncFailure(error, reason, syncStartedAtMs);
    } finally {
      await this.completeSyncCycle(reason, syncStartedAtMs, startupSyncStatus, startupTimings);
    }
  }

  // Keeps sync cycles cheap by skipping poll work when state indicates no safe or useful action is possible.
  private async shouldSkipSync(reason: "startup" | "manual" | "poll"): Promise<boolean> {
    if (this.isSyncing) return true;
    if (reason !== "poll") return false;
    if (this.periodicSyncPaused()) return true;
    if (await this.shouldSkipPollWhenLocalHeadDiffersFromTrackedRemote()) {
      this.scheduleNext();
      return true;
    }
    if (this.visibilityProvider()) {
      this.scheduleNext();
      return true;
    }
    return false;
  }

  // Initializes one sync run so downstream helpers can assume snapshot/log state is consistent.
  private beginSyncCycle(reason: "startup" | "manual" | "poll"): void {
    this.isSyncing = true;
    if (this.progressPhases.length === 0) {
      this.resetProgressPhases();
    }
    this.activateProgressPhase("checkingForUpdates", "Checking for updates");
    this.snapshot = {
      ...this.snapshot,
      syncing: true,
      error: this.snapshot.unrecoverableError ? this.snapshot.error : null,
      requiresHardResetPermission: false,
    };
    this.listener(this.snapshot);
    this.log("sync-start", {
      reason,
      snapshotCommitHash: this.snapshot.syncedCommitHash,
      periodicSyncPaused: this.snapshot.periodicSyncPaused,
    });
  }

  // Coordinates remote short-circuit checks, pull, incremental apply, and full hydration fallback in one linear flow.
  private async executeSyncCycle(
    reason: "startup" | "manual" | "poll",
    syncStartedAtMs: number,
    recordStartupTiming: StartupTimingRecorder,
  ): Promise<SyncCycleStatus> {
    const previousSyncedHash = (await this.manifestDb.readSyncedCommitHash()) ?? this.snapshot.syncedCommitHash;
    const cacheFormat = await this.manifestDb.readCacheFormatVersion();
    this.log("sync-db-base-commit", {
      reason,
      dbCommitHash: previousSyncedHash,
      cacheFormat,
    });
    if (previousSyncedHash) {
      const shortCircuitStatus = await this.tryShortCircuitWithUnchangedRemoteHead(
        previousSyncedHash,
        cacheFormat,
        reason,
        syncStartedAtMs,
      );
      if (shortCircuitStatus) return shortCircuitStatus;
    }

    const pullTimer = syncTimer("syncNow-pull");
    const syncedCommitHash = await this.transport.pullWithRebase(this.snapshot.syncedCommitHash);
    const observed = await this.manifestBlobReader.readDatabaseVersion(syncedCommitHash);
    requireAcceptedDatabaseVersion(observed);
    requireNoDatabaseVersionDowngrade(observed, cacheFormat);
    const needsFormatRehydration = observed !== cacheFormat;
    const pullDurationMs = pullTimer.stop();
    this.log("sync-pull-complete", {
      reason,
      fromCommitHash: previousSyncedHash,
      toCommitHash: syncedCommitHash,
      observedFormat: observed,
      needsFormatRehydration,
      durationMs: pullDurationMs,
    });
    recordStartupTiming("pullMs", pullDurationMs);
    this.activateProgressPhase("scanningRepository", "Scanning repository");

    if (previousSyncedHash && syncedCommitHash === previousSyncedHash && !needsFormatRehydration) {
      return this.handleUnchangedCommitAfterPull(syncedCommitHash, reason, syncStartedAtMs);
    }
    if (previousSyncedHash && syncedCommitHash !== previousSyncedHash && !needsFormatRehydration) {
      const incrementalStatus = await this.tryIncrementalSyncTransition(
        previousSyncedHash,
        syncedCommitHash,
        reason,
        syncStartedAtMs,
      );
      if (incrementalStatus) return incrementalStatus;
    }

    await this.performFullHydrationSync(
      previousSyncedHash,
      syncedCommitHash,
      reason,
      syncStartedAtMs,
      pullDurationMs,
      recordStartupTiming,
      observed,
    );
    return "success";
  }

  // Avoids unnecessary fetch/parse work when remote head already matches the commit stored in cache metadata.
  private async tryShortCircuitWithUnchangedRemoteHead(
    previousSyncedHash: string,
    cacheFormat: number,
    reason: "startup" | "manual" | "poll",
    syncStartedAtMs: number,
  ): Promise<SyncCycleStatus | null> {
    const remoteHead = await this.transport.readRemoteBranchHeadCommitHashOrNull();
    if (!remoteHead || remoteHead !== previousSyncedHash) return null;
    // A failed object read is not a format verdict. Fall through to
    // pull so the authoritative check runs against a fetched repo.
    const observed = await this.manifestBlobReader.readDatabaseVersionOrNull(remoteHead);
    if (observed === null || observed !== cacheFormat) return null;
    if (await this.manifestDb.hasAnyRecords()) {
      this.updateActivePhaseProgress("checkingForUpdates", "Checking for updates", 1);
      this.log("sync-noop-remote-head-unchanged", {
        reason,
        commitHash: remoteHead,
        durationMs: nowMs() - syncStartedAtMs,
      });
      this.failureCount = 0;
      this.finishWithSuccess({ syncedCommitHash: remoteHead });
      return "noop";
    }
    await this.recoverEmptyCache(remoteHead, null);
    return "noop";
  }

  // Handles post-pull no-op transitions so sync still updates metadata and recovers from an unexpectedly empty cache.
  private async handleUnchangedCommitAfterPull(
    syncedCommitHash: string,
    reason: "startup" | "manual" | "poll",
    syncStartedAtMs: number,
  ): Promise<SyncCycleStatus> {
    if (await this.manifestDb.hasAnyRecords()) {
      this.updateActivePhaseProgress("scanningRepository", "Scanning repository", 1);
      this.log("sync-noop-local-head-unchanged-after-pull", {
        reason,
        commitHash: syncedCommitHash,
        durationMs: nowMs() - syncStartedAtMs,
      });
      this.failureCount = 0;
      this.finishWithSuccess({ syncedCommitHash });
      return "noop";
    }
    await this.recoverEmptyCache(syncedCommitHash, null);
    return "noop";
  }

  // Prefers incremental cache mutation for commit transitions while preserving stale-CAS and empty-cache recovery semantics.
  private async tryIncrementalSyncTransition(
    previousSyncedHash: string,
    syncedCommitHash: string,
    reason: "startup" | "manual" | "poll",
    syncStartedAtMs: number,
  ): Promise<SyncCycleStatus | null> {
    this.activateProgressPhase("scanningRepository", "Scanning repository");
    const incrementalResult = await this.commitTransitionApplier.tryApplyIncrementalCommitTransitionToCache(
      previousSyncedHash,
      syncedCommitHash,
    );
    if (incrementalResult.outcome === "stale") {
      await this.handleStaleCas();
      return "stale";
    }
    if (incrementalResult.outcome !== "applied") {
      return null;
    }
    this.failureCount = 0;
    let syncCompleteSource: "incremental-cache" | "full-hydration" = "full-hydration";
    let status: SyncCycleStatus;
    if (await this.manifestDb.hasAnyRecords()) {
      this.updateActivePhaseProgress("scanningRepository", "Scanning repository", 1);
      syncCompleteSource = "incremental-cache";
      this.finishWithSuccess({
        syncedCommitHash,
        manifestChange: { type: "incremental", mutation: incrementalResult.mutation },
      });
      status = "success";
    } else {
      this.updateActivePhaseProgress("scanningRepository", "Scanning repository", 1);
      await this.recoverEmptyCache(syncedCommitHash, previousSyncedHash);
      status = "success";
    }
    this.log("sync-complete", {
      reason,
      fromCommitHash: previousSyncedHash,
      toCommitHash: syncedCommitHash,
      durationMs: nowMs() - syncStartedAtMs,
      source: syncCompleteSource,
    });
    return status;
  }

  // Rebuilds cache state from manifests when incremental mutation is unavailable or unsafe for the commit transition.
  private async performFullHydrationSync(
    previousSyncedHash: string | null,
    syncedCommitHash: string,
    reason: "startup" | "manual" | "poll",
    syncStartedAtMs: number,
    pullDurationMs: number,
    recordStartupTiming: StartupTimingRecorder,
    observedFormat: number,
  ): Promise<void> {
    const streamTimer = syncTimer("syncNow-streamManifests");
    const { totalRecords, pointers, timings: streamTimings } = await this.manifestHydrator.streamManifestsToCache(
      syncedCommitHash,
      syncedCommitHash,
      observedFormat,
    );
    streamTimer.stop();
    recordStartupTiming("readManifestsMs", streamTimings.blobReadDecodeParseMs);
    recordStartupTiming("replaceCacheMs", streamTimings.replaceCacheMs);
    this.failureCount = 0;
    this.finishWithSuccess({ syncedCommitHash, manifestChange: { type: "fullReplace" } });
    this.log("sync-complete", {
      reason,
      fromCommitHash: previousSyncedHash,
      toCommitHash: syncedCommitHash,
      records: totalRecords,
      durationMs: nowMs() - syncStartedAtMs,
    });
    this.logFullHydrationBenchmark({
      pullMs: pullDurationMs,
      readTimings: streamTimings,
      replaceCacheMs: streamTimings.replaceCacheMs,
      totalMs: nowMs() - syncStartedAtMs,
      records: totalRecords,
      pointers: pointers.size,
    });
  }

  // Reconciles sync errors into user-facing snapshot state while preserving explicit recovery on rebase conflicts.
  private handleSyncFailure(
    error: unknown,
    reason: "startup" | "manual" | "poll",
    syncStartedAtMs: number,
  ): void {
    this.failureCount += 1;
    const isRebaseConflict = error instanceof PullRebaseConflictError;
    const isDatabaseVersionError = error instanceof DatabaseVersionError;
    const isMarkerUnreadable = error instanceof DatabaseVersionUnreadableError;
    this.log("sync-failed", {
      reason,
      rebaseConflict: isRebaseConflict,
      unrecoverable: isDatabaseVersionError,
      markerUnreadable: isMarkerUnreadable,
      error: errorMessage(error),
      durationMs: nowMs() - syncStartedAtMs,
    });
    const message = isRebaseConflict
      ? "Sync conflict detected while rebasing local state. Approve reset to remote to recover."
      : describeSyncFailure(this.logPrefix, error);
    this.setErrorSnapshot(message, {
      requiresHardResetPermission: isRebaseConflict,
      unrecoverableError: isDatabaseVersionError ? message : this.snapshot.unrecoverableError,
    });
  }

  // Finalizes one sync attempt with startup diagnostics, queued rewind draining, and poll rescheduling.
  private async completeSyncCycle(
    reason: "startup" | "manual" | "poll",
    syncStartedAtMs: number,
    startupSyncStatus: SyncCycleStatus,
    startupTimings: Record<string, number>,
  ): Promise<void> {
    if (reason === "startup") {
      this.log("sync-initial-timing-summary", {
        status: startupSyncStatus,
        ...startupTimings,
        totalSyncMs: nowMs() - syncStartedAtMs,
        measureQueryHint:
          'performance.getEntriesByType("measure").filter((entry) => entry.name.startsWith("sync:"))',
      });
    }
    this.isSyncing = false;
    if (this.pendingRewindCommitHash) {
      const pending = this.pendingRewindCommitHash;
      this.pendingRewindCommitHash = null;
      await this.rewindToCommitAndPausePolling(pending);
      return;
    }
    this.scheduleNext();
  }

  // Centralizes all sync/transition/stale success paths into one snapshot update.
  private finishWithSuccess(opts: {
    syncedCommitHash: string | null;
    manifestChange?: ManifestDatabaseChange;
  }): void {
    this.resetProgressPhases();
    this.snapshot = {
      ...this.snapshot,
      syncing: false,
      error: null,
      unrecoverableError: null,
      lastSyncAt: new Date().toISOString(),
      syncedCommitHash: opts.syncedCommitHash,
      periodicSyncPaused: this.periodicSyncPaused(),
      periodicSyncUserEnabled: !this.userPeriodicSyncPaused,
      syncIntervalMs: this.effectiveSyncIntervalMs,
      isOffHead: this.isRewindPaused,
      requiresHardResetPermission: false,
      cloneProgress: null,
    };
    if (opts.manifestChange) {
      this.emitManifestChange(opts.manifestChange);
    }
    this.listener(this.snapshot);
  }

  // Reduces error catch-block boilerplate across sync, reset, rewind, and forward paths.
  private setErrorSnapshot(message: string, extra?: Partial<SyncSnapshot>): void {
    this.resetProgressPhases();
    this.snapshot = {
      ...this.snapshot,
      syncing: false,
      error: message,
      periodicSyncPaused: this.periodicSyncPaused(),
      periodicSyncUserEnabled: !this.userPeriodicSyncPaused,
      syncIntervalMs: this.effectiveSyncIntervalMs,
      isOffHead: this.isRewindPaused,
      cloneProgress: null,
      ...extra,
    };
    this.listener(this.snapshot);
  }

  // Rebuilds cache from manifests when the database has no records despite a valid commit being available.
  private async recoverEmptyCache(
    syncedCommitHash: string,
    hydrationBaseCommitHash: string | null,
  ): Promise<void> {
    this.log("sync-empty-cache-recovery-start", { syncedCommitHash, hydrationBaseCommitHash });
    await this.hydrateFromCommitAndApplyFullReplace(
      hydrationBaseCommitHash,
      syncedCommitHash,
    );
    this.failureCount = 0;
    this.log("sync-empty-cache-recovery-complete", { syncedCommitHash, hydrationBaseCommitHash });
  }

  // Stops polling so app teardown does not leave timers running.
  stop(): void {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  // Triggers a quick refresh when the page becomes visible after being backgrounded.
  async onVisibilityRegained(): Promise<void> {
    if (this.visibilityProvider()) return;
    await this.syncNow("manual");
  }

  // Executes destructive recovery only after UI captures explicit user approval.
  async hardResetToRemoteAfterPermission(): Promise<void> {
    if (this.isSyncing || !this.snapshot.requiresHardResetPermission) return;
    this.isSyncing = true;
    this.snapshot = { ...this.snapshot, syncing: true, error: null };
    this.listener(this.snapshot);
    try {
      await this.transport.hardResetToRemote();
      this.resetProgressPhases();
      this.snapshot = {
        ...this.snapshot,
        syncing: false,
        requiresHardResetPermission: false,
        cloneProgress: null,
      };
      this.listener(this.snapshot);
      this.isSyncing = false;
      await this.syncNow("manual");
    } catch (error) {
      this.setErrorSnapshot(`Reset failed: ${errorMessage(error)}`);
    } finally {
      if (this.isSyncing) {
        this.isSyncing = false;
        this.scheduleNext();
      }
    }
  }

  // Exposes available local commit history so debug rewind options stay within shallow clone bounds.
  async listRecentLocalCommits(limit: number = 20): Promise<SyncCommitSummary[]> {
    const pfs = this.fs.promises;
    try {
      await pfs.stat(`${this.gitdir}/HEAD`);
    } catch {
      return [];
    }
    // Prefers remote-tracking history so rewind options can always include forward targets.
    const resolveCommitListRef = async (): Promise<string | null> => {
      if (await this.transport.resolveRefOrNull(this.transport.trackedRemoteRef)) {
        return this.transport.trackedRemoteRef;
      }
      if (await this.transport.resolveRefOrNull(this.transport.localBranchRef)) {
        return this.transport.localBranchRef;
      }
      return null;
    };
    // Maps git log entries into stable UI rows for commit rewind/forward controls.
    const summarizeCommits = async (ref: string | null): Promise<SyncCommitSummary[]> => {
      if (!ref) return [];
      const commits = await git.log({
        fs: this.fs,
        dir: this.gitdir,
        gitdir: this.gitdir,
        ref,
        depth: limit,
        cache: this.gitObjectCache,
      });
      return commits.map((entry) => ({
        hash: entry.oid,
        message: entry.commit.message.split("\n")[0] ?? "(no commit message)",
        authoredAt: new Date(entry.commit.author.timestamp * 1000).toISOString(),
      }));
    };
    const logRef = await resolveCommitListRef();
    return summarizeCommits(logRef);
  }

  // Exposes tracked origin head so commit selection can distinguish forward targets from rewind points.
  async readTrackedRemoteHeadCommitHashOrNull(): Promise<string | null> {
    return this.transport.resolveRefOrNull(this.transport.trackedRemoteRef);
  }

  // Rewinds local branch state for debugging while intentionally freezing background polling.
  async rewindToCommitAndPausePolling(commitHash: string): Promise<void> {
    const rewindStartedAtMs = nowMs();
    this.log("rewind-start", {
      targetCommitHash: commitHash,
      isSyncing: this.isSyncing,
      snapshotCommitHash: this.snapshot.syncedCommitHash,
    });
    this.pausePollingForRewind();
    if (this.isSyncing) {
      this.pendingRewindCommitHash = commitHash;
      this.log("rewind-queued", {
        targetCommitHash: commitHash,
        reason: "sync-in-progress",
      });
      this.snapshot = {
        ...this.snapshot,
        error: "Pause requested while sync is in progress. Rewind will run as soon as the current sync finishes.",
      };
      this.listener(this.snapshot);
      return;
    }
    this.isSyncing = true;
    this.snapshot = {
      ...this.snapshot,
      syncing: true,
      error: null,
      requiresHardResetPermission: false,
      cloneProgress: null,
    };
    this.listener(this.snapshot);
    try {
      await this.moveToCommitAndApplyCacheTransition({
        targetCommitHash: commitHash,
        logPrefix: "rewind",
        startedAtMs: rewindStartedAtMs,
      });
    } catch (error) {
      this.log("rewind-failed", {
        targetCommitHash: commitHash,
        error: errorMessage(error),
        durationMs: nowMs() - rewindStartedAtMs,
      });
      this.setErrorSnapshot(`Rewind failed: ${errorMessage(error)}`);
    } finally {
      this.isSyncing = false;
    }
  }

  // Shared core for rewind/forward: checks out target commit, applies cache transition,
  // handles stale/hydration/incremental outcomes, and emits the appropriate log events.
  private async moveToCommitAndApplyCacheTransition(opts: {
    targetCommitHash: string;
    logPrefix: string;
    startedAtMs: number;
  }): Promise<void> {
    const { targetCommitHash, logPrefix, startedAtMs } = opts;
    const checkoutStartedAtMs = nowMs();
    await this.transport.assertCommitExists(targetCommitHash);
    try {
      await this.manifestBlobReader.assertSupportedDatabaseVersion(targetCommitHash);
    } catch (error) {
      if (error instanceof DatabaseVersionError) {
        throw new Error("cannot rewind past a database format change");
      }
      throw error;
    }
    await this.transport.forceCheckoutCommit(this.transport.localBranchRef, targetCommitHash);
    const previousSyncedHash = (await this.manifestDb.readSyncedCommitHash()) ?? this.snapshot.syncedCommitHash;
    const checkoutDurationMs = nowMs() - checkoutStartedAtMs;
    const applyStartedAtMs = nowMs();
    const applyResult = await this.commitTransitionApplier.applyCommitTransitionToCache(
      previousSyncedHash,
      targetCommitHash,
    );
    const applyDurationMs = nowMs() - applyStartedAtMs;
    if (applyResult.outcome === "stale") {
      await this.handleStaleCas();
      return;
    }
    let source: "incremental-cache" | "full-hydration" = "incremental-cache";
    if (applyResult.outcome === "needs_full_hydration") {
      source = "full-hydration";
      const fullHydrationStartedAtMs = nowMs();
      await this.hydrateFromCommitAndApplyFullReplace(
        previousSyncedHash,
        targetCommitHash,
      );
      this.log(`${logPrefix}-full-hydration-complete`, {
        fromCommitHash: previousSyncedHash,
        toCommitHash: targetCommitHash,
        durationMs: nowMs() - fullHydrationStartedAtMs,
      });
    } else {
      this.finishWithSuccess({
        syncedCommitHash: targetCommitHash,
        manifestChange: applyResult.mutation
          ? { type: "incremental", mutation: applyResult.mutation }
          : { type: "fullReplace" },
      });
    }
    this.failureCount = 0;
    this.log(`${logPrefix}-complete`, {
      fromCommitHash: previousSyncedHash,
      toCommitHash: targetCommitHash,
      source,
      checkoutDurationMs,
      cacheApplyDurationMs: applyDurationMs,
      durationMs: nowMs() - startedAtMs,
    });
  }

  // Returns to current remote head and resumes periodic sync after rewind debugging is complete.
  // Uses a local-only checkout (like rewind) so forward works even when the remote server is unreachable.
  async forwardToRemoteHeadAndResumePolling(): Promise<void> {
    const forwardStartedAtMs = nowMs();
    const trackedHead = await this.transport.resolveRefOrNull(this.transport.trackedRemoteRef);
    this.log("forward-start", {
      trackedHead,
      isSyncing: this.isSyncing,
      snapshotCommitHash: this.snapshot.syncedCommitHash,
    });
    if (!trackedHead) {
      throw new Error("No tracked remote head available locally. Try syncing first.");
    }
    if (this.isSyncing) return;
    const previousSyncedHash = (await this.manifestDb.readSyncedCommitHash()) ?? this.snapshot.syncedCommitHash;
    if (trackedHead === previousSyncedHash) {
      this.isRewindPaused = false;
      this.finishWithSuccess({ syncedCommitHash: trackedHead });
      return;
    }
    this.isRewindPaused = false;
    this.isSyncing = true;
    this.snapshot = {
      ...this.snapshot,
      syncing: true,
      error: null,
      periodicSyncPaused: this.periodicSyncPaused(),
      periodicSyncUserEnabled: !this.userPeriodicSyncPaused,
      isOffHead: this.isRewindPaused,
      requiresHardResetPermission: false,
      cloneProgress: null,
    };
    this.listener(this.snapshot);
    try {
      await this.moveToCommitAndApplyCacheTransition({
        targetCommitHash: trackedHead,
        logPrefix: "forward",
        startedAtMs: forwardStartedAtMs,
      });
    } catch (error) {
      this.log("forward-failed", {
        trackedHead,
        error: errorMessage(error),
        durationMs: nowMs() - forwardStartedAtMs,
      });
      this.setErrorSnapshot(
        `Forward failed: ${errorMessage(error)}`,
      );
    } finally {
      this.isSyncing = false;
      this.scheduleNext();
    }
  }

  // Handles the common stale-CAS outcome across sync, rewind, and forward paths.
  private async handleStaleCas(): Promise<void> {
    this.failureCount = 0;
    const staleSyncedHash = await this.manifestDb.readSyncedCommitHash();
    this.finishWithSuccess({
      syncedCommitHash: staleSyncedHash,
      manifestChange: { type: "fullReplace" },
    });
  }

  // Rebuilds one commit snapshot from manifests only when incremental transition cannot safely apply.
  private async hydrateFromCommitAndApplyFullReplace(
    previousSyncedHash: string | null,
    targetCommitHash: string,
  ): Promise<void> {
    const hydrationStartedAtMs = nowMs();
    const observedFormat = await this.manifestBlobReader.readDatabaseVersion(targetCommitHash);
    const { totalRecords, pointers, timings: streamTimings } = await this.manifestHydrator.streamManifestsToCache(
      targetCommitHash,
      targetCommitHash,
      observedFormat,
    );
    this.finishWithSuccess({
      syncedCommitHash: targetCommitHash,
      manifestChange: { type: "fullReplace" },
    });
    const totalMs = nowMs() - hydrationStartedAtMs;
    this.log("sync-full-hydration-commit-applied", {
      fromCommitHash: previousSyncedHash,
      toCommitHash: targetCommitHash,
      records: totalRecords,
      pointers: pointers.size,
      readManifestsDurationMs: streamTimings.totalMs,
    });
    this.logFullHydrationBenchmark({
      readTimings: streamTimings,
      replaceCacheMs: streamTimings.replaceCacheMs,
      totalMs,
      records: totalRecords,
      pointers: pointers.size,
    });
  }


  // Keeps the polling loop adaptive to last sync outcome.
  private scheduleNext(): void {
    if (this.timer !== null) {
      clearTimeout(this.timer);
    }
    if (this.periodicSyncPaused() || this.snapshot.unrecoverableError) {
      this.timer = null;
      return;
    }
    this.timer = setTimeout(() => {
      void this.syncNow("poll");
    }, computeBackoffMs(this.failureCount, this.effectiveSyncIntervalMs));
  }

  // Prevents periodic polling from auto-forwarding when local debug rewind intentionally diverges from tracked origin/main.
  private async shouldSkipPollWhenLocalHeadDiffersFromTrackedRemote(): Promise<boolean> {
    const localHead = await this.transport.resolveRefOrNull(this.transport.localBranchRef);
    const trackedRemoteHead = await this.transport.resolveRefOrNull(this.transport.trackedRemoteRef);
    return Boolean(localHead && trackedRemoteHead && localHead !== trackedRemoteHead);
  }

  // Turns off poll scheduling so rewind snapshots stay stable for debugging.
  private pausePollingForRewind(): void {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.isRewindPaused = true;
    this.snapshot = {
      ...this.snapshot,
      periodicSyncPaused: this.periodicSyncPaused(),
      periodicSyncUserEnabled: !this.userPeriodicSyncPaused,
      isOffHead: this.isRewindPaused,
    };
    this.listener(this.snapshot);
  }

  async probeOnboardingAuthorization(): Promise<OnboardingAuthorizationProbe> {
    return this.transport.probeOnboardingAuthorization();
  }

  // Reports tree traversal progress so repository scanning contributes to the
  // unified sync bar instead of looking like a frozen "100%" state.
  // Total may be 0 when the final count is unknown; the UI then shows a
  // running counter without denominator.
  private emitTreeWalkProgress(loaded: number, total: number): void {
    this.activateProgressPhase("scanningRepository", "Scanning repository");
    const fraction = total > 0 ? this.progressFractionFromLoadedTotal(loaded, total) : Math.min(0.9, loaded / (loaded + 100));
    this.updateActivePhaseProgress(
      "scanningRepository",
      "Scanning repository",
      fraction,
      loaded > 0 ? loaded : undefined,
      total > 0 ? total : undefined,
    );
  }

  // Reports KEK refresh progress so the decryption prep phase is visible.
  private emitKekRefreshProgress(loaded: number, total: number): void {
    this.activateProgressPhase("preparingDecryption", "Preparing decryption");
    this.updateActivePhaseProgress(
      "preparingDecryption",
      "Preparing decryption",
      this.progressFractionFromLoadedTotal(loaded, total),
    );
  }

  // Reports manifest decode progress so manifest ingestion advances the
  // weighted overall percentage rather than resetting a per-phase bar.
  private emitManifestReadProgress(loaded: number, total: number): void {
    this.activateProgressPhase("readingManifests", "Reading manifests");
    this.updateActivePhaseProgress(
      "readingManifests",
      "Reading manifests",
      this.progressFractionFromLoadedTotal(loaded, total),
      loaded,
      total,
    );
  }

  // Reports pointer processing so media metadata work after manifests appears
  // as visible progress instead of a long pause at the end of sync.
  private emitPointerProgress(loaded: number, total: number): void {
    this.activateProgressPhase("processingMedia", "Processing media");
    this.updateActivePhaseProgress(
      "processingMedia",
      "Processing media",
      this.progressFractionFromLoadedTotal(loaded, total),
      loaded,
      total,
    );
  }
}
